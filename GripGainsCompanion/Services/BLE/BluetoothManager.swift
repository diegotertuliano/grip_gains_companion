import CoreBluetooth
import Combine
import SwiftUI
import os

// MARK: - Central Manager Protocol (for testability)

/// Protocol for CBCentralManager to enable dependency injection in tests
protocol CentralManagerProtocol: AnyObject {
    var state: CBManagerState { get }
    func scanForPeripherals(withServices serviceUUIDs: [CBUUID]?, options: [String: Any]?)
    func stopScan()
    func connect(_ peripheral: CBPeripheral, options: [String: Any]?)
    func cancelPeripheralConnection(_ peripheral: CBPeripheral)
}

extension CBCentralManager: CentralManagerProtocol {}

/// Connection state for the Tindeq Progressor
enum ConnectionState: Equatable {
    case initializing
    case disconnected
    case scanning
    case connecting
    case connected
    case error(String)

    var displayText: String {
        switch self {
        case .initializing: return "Initializing..."
        case .disconnected: return "Disconnected"
        case .scanning: return "Scanning..."
        case .connecting: return "Connecting..."
        case .connected: return "Connected"
        case .error(let msg): return "Error: \(msg)"
        }
    }
}

/// Manages CoreBluetooth central operations for discovering and connecting to Tindeq Progressor
class BluetoothManager: NSObject, ObservableObject {
    @Published var connectionState: ConnectionState = .initializing
    @Published var discoveredDevices: [ProgressorDevice] = []
    @Published var connectedDeviceName: String?

    /// Persisted ID of last connected device for auto-reconnect
    @AppStorage("lastConnectedDeviceId") private(set) var lastConnectedDeviceId: String = ""

    private var centralManager: CentralManagerProtocol!
    private var connectedPeripheral: CBPeripheral?
    private var progressorService: ProgressorService?
    private var peripheralCache: [UUID: CBPeripheral] = [:]

    /// Retry state for indefinite reconnection
    private var retryCount: Int = 0
    private var retryTimer: Timer?
    private var pendingDevice: ProgressorDevice?
    private var shouldAutoReconnect: Bool = true

    /// Background inactivity disconnect timer (internal for testability)
    var backgroundDisconnectTimer: Timer?

    /// Callback when force samples are received
    var onForceSample: ((Float) -> Void)?

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    /// Test initializer for dependency injection
    init(centralManager: CentralManagerProtocol) {
        super.init()
        self.centralManager = centralManager
    }

    // MARK: - Public Methods

    func startScanning() {
        guard centralManager.state == .poweredOn else {
            Log.ble.error("Bluetooth not available")
            connectionState = .error("Bluetooth not available")
            return
        }

        Log.ble.info("Starting scan...")
        discoveredDevices.removeAll()
        peripheralCache.removeAll()
        connectionState = .scanning

        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func stopScanning() {
        centralManager.stopScan()
        if connectionState == .scanning {
            connectionState = .disconnected
        }
    }

    func connect(to device: ProgressorDevice) {
        guard let peripheral = peripheralCache[device.peripheralIdentifier] else {
            Log.ble.error("Device not found in cache")
            connectionState = .error("Device not found")
            return
        }

        Log.ble.info("Connecting to \(device.name)...")
        stopScanning()
        cancelRetryTimer()
        pendingDevice = device
        shouldAutoReconnect = true
        connectionState = .connecting
        connectedPeripheral = peripheral
        centralManager.connect(peripheral, options: nil)
    }

    // MARK: - Retry Logic

    /// Calculate retry delay with exponential backoff, capped at maxRetryDelay
    private func calculateRetryDelay() -> TimeInterval {
        let baseDelay: TimeInterval = 1.0
        let delay = baseDelay * pow(2.0, Double(min(retryCount, 5)))
        return min(delay, AppConstants.maxRetryDelay)
    }

    private func scheduleRetry() {
        guard shouldAutoReconnect, let device = pendingDevice else { return }

        retryCount += 1
        let currentRetry = retryCount
        let delay = calculateRetryDelay()
        Log.ble.info("Scheduling retry #\(currentRetry) in \(String(format: "%.1f", delay))s...")

        retryTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self = self else { return }

            // Try to reconnect - either from cache or restart scanning
            if let peripheral = self.peripheralCache[device.peripheralIdentifier] {
                Log.ble.info("Retrying connection to \(device.name)...")
                self.connectionState = .connecting
                self.connectedPeripheral = peripheral
                self.centralManager.connect(peripheral, options: nil)
            } else {
                Log.ble.info("Device not in cache, restarting scan...")
                self.startScanning()
            }
        }
    }

    private func cancelRetryTimer() {
        retryTimer?.invalidate()
        retryTimer = nil
    }

    private func resetRetryState() {
        retryCount = 0
        cancelRetryTimer()
    }

    // MARK: - Background Inactivity Timer

    /// Start a timer to disconnect after background inactivity timeout
    func startBackgroundDisconnectTimer() {
        cancelBackgroundDisconnectTimer()
        Log.ble.info("Starting background disconnect timer (\(Int(AppConstants.backgroundInactivityTimeout))s)")
        backgroundDisconnectTimer = Timer.scheduledTimer(
            withTimeInterval: AppConstants.backgroundInactivityTimeout,
            repeats: false
        ) { [weak self] _ in
            Log.ble.info("Background inactivity timeout - disconnecting")
            self?.disconnect(preserveAutoReconnect: true)
        }
    }

    /// Cancel the background disconnect timer
    func cancelBackgroundDisconnectTimer() {
        if backgroundDisconnectTimer != nil {
            Log.ble.info("Cancelling background disconnect timer")
        }
        backgroundDisconnectTimer?.invalidate()
        backgroundDisconnectTimer = nil
    }

    func disconnect(preserveAutoReconnect: Bool = false) {
        Log.ble.info("Disconnecting\(preserveAutoReconnect ? " (preserving auto-reconnect)" : "")...")

        // Stop auto-reconnect
        shouldAutoReconnect = false
        resetRetryState()
        cancelBackgroundDisconnectTimer()
        pendingDevice = nil

        centralManager.stopScan()

        if let peripheral = connectedPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        connectedPeripheral = nil
        progressorService = nil
        connectedDeviceName = nil

        // Clear last connected device to prevent auto-reconnect (unless preserving)
        if !preserveAutoReconnect {
            lastConnectedDeviceId = ""
        }

        // Clear device list for fresh scan
        discoveredDevices.removeAll()
        peripheralCache.removeAll()

        connectionState = .disconnected

        // Restart scanning to find devices (unless preserving auto-reconnect for later)
        if !preserveAutoReconnect {
            startScanning()
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Log.ble.info("Bluetooth state: \(central.state.rawValue)")
        switch central.state {
        case .poweredOn:
            // Auto-start scanning when Bluetooth becomes ready
            startScanning()
        case .poweredOff:
            Log.ble.error("Bluetooth is off")
            connectionState = .error("Bluetooth is off")
        case .unauthorized:
            Log.ble.error("Bluetooth unauthorized")
            connectionState = .error("Bluetooth unauthorized")
        case .unsupported:
            Log.ble.error("Bluetooth unsupported")
            connectionState = .error("Bluetooth unsupported")
        default:
            connectionState = .disconnected
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        // Filter for Progressor devices by name
        guard let name = peripheral.name, name.hasPrefix("Progressor") else {
            return
        }

        // Cache the peripheral for later connection
        peripheralCache[peripheral.identifier] = peripheral

        // Update or add device to list
        let device = ProgressorDevice(peripheral: peripheral, rssi: RSSI.intValue)

        if let index = discoveredDevices.firstIndex(where: { $0.id == device.id }) {
            discoveredDevices[index].rssi = RSSI.intValue
        } else {
            Log.ble.info("Discovered: \(name)")
            discoveredDevices.append(device)

            // Auto-connect if this is the last connected device
            if peripheral.identifier.uuidString == lastConnectedDeviceId {
                Log.ble.info("Auto-reconnecting to last device...")
                connect(to: device)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Log.ble.info("Connected to \(peripheral.name ?? "Unknown")")

        // Reset retry state on successful connection
        resetRetryState()

        connectionState = .connected
        connectedDeviceName = peripheral.name ?? "Unknown Progressor"

        // Save as last connected device for auto-reconnect
        lastConnectedDeviceId = peripheral.identifier.uuidString

        // Create service handler and discover services
        progressorService = ProgressorService(peripheral: peripheral)
        progressorService?.onForceSample = { [weak self] force in
            self?.onForceSample?(force)
        }
        progressorService?.onDiscoveryTimeout = { [weak self] in
            guard let self = self else { return }
            Log.ble.error("Discovery timeout - disconnecting to retry")
            // Cancel connection and let the disconnect handler retry
            if let peripheral = self.connectedPeripheral {
                self.centralManager.cancelPeripheralConnection(peripheral)
            }
        }
        progressorService?.discoverServices()
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        Log.ble.error("Failed to connect: \(error?.localizedDescription ?? "Unknown error")")
        connectionState = .error(error?.localizedDescription ?? "Connection failed")
        connectedPeripheral = nil
        progressorService = nil
        connectedDeviceName = nil

        // Schedule indefinite retry
        scheduleRetry()
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        if let error = error {
            Log.ble.error("Disconnected with error: \(error.localizedDescription)")
        } else {
            Log.ble.info("Disconnected")
        }
        connectionState = .disconnected
        connectedPeripheral = nil
        progressorService = nil
        connectedDeviceName = nil

        // Schedule indefinite retry if we should auto-reconnect
        if shouldAutoReconnect {
            scheduleRetry()
        }
    }
}
