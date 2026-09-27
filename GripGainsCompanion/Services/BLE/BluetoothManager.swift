import CoreBluetooth
import Combine
import SwiftUI
import UIKit
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

/// Connection state for force measurement devices
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

/// Manages CoreBluetooth central operations for discovering and connecting to force measurement devices
class BluetoothManager: NSObject, ObservableObject {
    @Published var connectionState: ConnectionState = .initializing
    @Published var discoveredDevices: [ForceDevice] = []
    @Published var connectedDeviceName: String?
    @Published var connectedDeviceType: DeviceType?
    @Published var isReconnecting: Bool = false
    @Published private(set) var readingCorrectionDevice: ReadingCorrectionDevice?
    @Published private(set) var readingCorrection: ReadingCorrection = .identity

    // A separate publisher lets the editor preview raw readings without refreshing
    // every view observing BluetoothManager at the device's sample rate.
    let reportedForceSamples = PassthroughSubject<Double, Never>()
    private(set) var latestReportedForce: Double?
    private let correctionStore: ReadingCorrectionStore

    /// Currently selected device type filter for scanning (persisted)
    @Published var selectedDeviceType: DeviceType = .tindeqProgressor {
        didSet {
            UserDefaults.standard.set(selectedDeviceType.rawValue, forKey: "selectedDeviceType")
        }
    }

    /// Persisted ID of last connected device for auto-reconnect
    @AppStorage("lastConnectedDeviceId") private(set) var lastConnectedDeviceId: String = ""
    @AppStorage("lastConnectedDeviceType") private var lastConnectedDeviceTypeRaw: String = ""

    private var centralManager: CentralManagerProtocol!
    private var connectedPeripheral: CBPeripheral?

    // Device-specific services
    private var progressorService: ProgressorService?
    private var pitchSixService: PitchSixService?
    private var cts500Service: CTS500Service?
    private var whc06Service: WHC06Service?

    private var peripheralCache: [UUID: CBPeripheral] = [:]

    /// Retry state for indefinite reconnection
    private var retryCount: Int = 0
    private var retryTimer: Timer?
    private var pendingDevice: ForceDevice?
    private var shouldAutoReconnect: Bool = true

    /// Background inactivity disconnect timer (internal for testability)
    var backgroundDisconnectTimer: Timer?

    /// Callback when force samples are received (force value, timestamp in microseconds)
    var onForceSample: ((Double, UInt32) -> Void)?

    override init() {
        correctionStore = ReadingCorrectionStore()
        super.init()
        // Restore persisted device type
        if let savedType = UserDefaults.standard.string(forKey: "selectedDeviceType"),
           let deviceType = DeviceType(rawValue: savedType) {
            selectedDeviceType = deviceType
        }
        centralManager = CBCentralManager(delegate: self, queue: .main)
        registerAppLifecycleObservers()
    }

    /// Test initializer for dependency injection
    init(centralManager: CentralManagerProtocol, correctionStore: ReadingCorrectionStore = ReadingCorrectionStore()) {
        self.correctionStore = correctionStore
        super.init()
        // Restore persisted device type
        if let savedType = UserDefaults.standard.string(forKey: "selectedDeviceType"),
           let deviceType = DeviceType(rawValue: savedType) {
            selectedDeviceType = deviceType
        }
        self.centralManager = centralManager
        registerAppLifecycleObservers()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func registerAppLifecycleObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillTerminate),
            name: UIApplication.willTerminateNotification,
            object: nil
        )
    }

    @objc private func handleAppWillTerminate() {
        guard connectionState == .connected else { return }
        Log.ble.info("App will terminate - shutting down device")
        sendShutdownAndDisconnect(preserveAutoReconnect: true, immediate: true)
    }

    // MARK: - Public Methods

    /// Load before starting any service, including advertisement-only devices.
    func prepareReadingCorrection(for device: ReadingCorrectionDevice) {
        readingCorrectionDevice = device
        readingCorrection = correctionStore.correction(for: device)
        latestReportedForce = nil
    }

    @discardableResult
    func saveReadingCorrection(_ correction: ReadingCorrection, for device: ReadingCorrectionDevice) -> Bool {
        guard connectionState == .connected, readingCorrectionDevice == device,
              correctionStore.save(correction, for: device) else { return false }
        readingCorrection = correction
        return true
    }

    /// The single ingress for all decoded device samples. Source identity prevents
    /// a late callback from another device from using the current device's profile.
    func receiveForceSample(_ force: Double, timestamp: UInt32, from device: ReadingCorrectionDevice) {
        guard connectionState == .connected, readingCorrectionDevice == device,
              force.isFinite else { return }
        latestReportedForce = force
        reportedForceSamples.send(force)
        guard let corrected = readingCorrection.apply(to: force) else { return }
        onForceSample?(corrected, timestamp)
    }

    private func clearReadingCorrection() {
        readingCorrectionDevice = nil
        readingCorrection = .identity
        latestReportedForce = nil
    }

    /// Set the WHC06 scale unit override (forwarded to the active WHC06 service)
    func setWHC06ScaleUnit(_ unit: WHC06ScaleUnit) {
        whc06Service?.scaleUnitOverride = unit
    }

    func startScanning() {
        guard centralManager.state == .poweredOn else {
            Log.ble.error("Bluetooth not available")
            connectionState = .error("Bluetooth not available")
            return
        }

        Log.ble.info("Starting scan for \(self.selectedDeviceType.displayName)...")
        discoveredDevices.removeAll()
        peripheralCache.removeAll()
        connectionState = .scanning

        // For WHC06, we need to allow duplicates to receive continuous advertisement updates
        let allowDuplicates = selectedDeviceType == .weihengWHC06

        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: allowDuplicates]
        )
    }

    func stopScanning() {
        centralManager.stopScan()
        if connectionState == .scanning {
            connectionState = .disconnected
        }
    }

    func connect(to device: ForceDevice) {
        // For WHC06, we don't actually connect - just track advertisements
        if device.type == .weihengWHC06 {
            connectToWHC06(device)
            return
        }

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

    /// Connect to WHC06 (advertisement-based, no actual GATT connection)
    private func connectToWHC06(_ device: ForceDevice) {
        Log.ble.info("Starting WHC06 advertisement tracking for \(device.name)...")
        cancelRetryTimer()
        pendingDevice = device
        shouldAutoReconnect = true
        isReconnecting = false
        let correctionDevice = ReadingCorrectionDevice(peripheralID: device.peripheralIdentifier, type: device.type)
        prepareReadingCorrection(for: correctionDevice)
        connectionState = .connected
        connectedDeviceName = device.name
        connectedDeviceType = .weihengWHC06

        // Save for auto-reconnect
        lastConnectedDeviceId = device.peripheralIdentifier.uuidString
        lastConnectedDeviceTypeRaw = DeviceType.weihengWHC06.rawValue

        // Create and start WHC06 service
        whc06Service = WHC06Service()
        if let raw = UserDefaults.standard.string(forKey: "whc06ScaleUnit"),
           let unit = WHC06ScaleUnit(rawValue: raw) {
            whc06Service?.scaleUnitOverride = unit
        }
        whc06Service?.onForceSample = { [weak self] force, timestamp in
            self?.receiveForceSample(force, timestamp: timestamp, from: correctionDevice)
        }
        whc06Service?.onDisconnect = { [weak self] in
            guard let self = self else { return }
            Log.ble.info("WHC06 appears disconnected")
            if self.shouldAutoReconnect {
                self.isReconnecting = true
            }
            self.connectionState = .disconnected
            if self.shouldAutoReconnect {
                self.scheduleRetry()
            } else {
                self.connectedDeviceName = nil
                self.connectedDeviceType = nil
            }
        }
        whc06Service?.start()
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

            // For WHC06, just restart scanning
            if device.type == .weihengWHC06 {
                Log.ble.info("Restarting WHC06 scan...")
                self.startScanning()
                return
            }

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
            Log.ble.info("Background inactivity timeout - shutting down device")
            self?.sendShutdownAndDisconnect(preserveAutoReconnect: true, immediate: false)
        }
    }

    /// True when the connected device supports a hardware tare command.
    var supportsHardwareTare: Bool {
        switch connectedDeviceType {
        case .tindeqProgressor, .pitchSixForceBoard, .jinlianCTS500: return true
        default: return false
        }
    }

    /// Send a hardware tare to the connected device, restart streaming if the
    /// device pauses it after tare (Tindeq does), then invoke `completion` once
    /// the device is ready for the software recalibration window. Always calls
    /// `completion` exactly once. Falls through to immediate completion for
    /// unsupported devices.
    func tareDevice(completion: @escaping () -> Void) {
        let settleDelay: TimeInterval = 0.2     // drain in-flight samples
        let safetyTimeout: TimeInterval = 1.5   // chain budget

        var finished = false
        let finish: () -> Void = {
            guard !finished else { return }
            finished = true
            completion()
        }

        switch connectedDeviceType {
        case .tindeqProgressor:
            guard let service = progressorService else { finish(); return }
            Log.ble.info("Hardware tare: Tindeq Progressor (tare -> start -> settle)")
            // On 0x64 ack: re-send 0x65 to resume streaming (Tindeq pauses after tare).
            service.onWriteComplete = {
                service.onWriteComplete = {
                    DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay, execute: finish)
                }
                service.startWeightMeasurement()
            }
            service.tare()

        case .pitchSixForceBoard:
            guard let service = pitchSixService else { finish(); return }
            Log.ble.info("Hardware tare: PitchSix Force Board")
            service.onWriteComplete = {
                DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay, execute: finish)
            }
            service.tare()

        case .jinlianCTS500:
            guard let service = cts500Service else { finish(); return }
            Log.ble.info("Hardware tare: Jinlian CTS500")
            service.onTareComplete = {
                DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay, execute: finish)
            }
            service.tare()

        default:
            Log.ble.info("Hardware tare not supported for \(String(describing: self.connectedDeviceType))")
            finish()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + safetyTimeout) {
            if !finished {
                self.cts500Service?.onTareComplete = nil
                Log.ble.info("Hardware tare chain stalled - proceeding anyway")
                finish()
            }
        }
    }

    /// Send Progressor shutdown (0x6E) and then disconnect.
    /// Falls through to plain disconnect for non-Tindeq devices.
    /// - Parameters:
    ///   - preserveAutoReconnect: forwarded to `disconnect(preserveAutoReconnect:)`
    ///   - immediate: when true, runs synchronously by spinning the run loop until
    ///     the ATT write is acknowledged or a 1s budget elapses. Used on app
    ///     termination, where we have to finish before the process is killed and
    ///     can't rely on a future async callback. When false, returns after issuing
    ///     the write and disconnects from `onWriteComplete` (or a 2s safety timeout).
    func sendShutdownAndDisconnect(preserveAutoReconnect: Bool, immediate: Bool = false) {
        guard connectedDeviceType == .tindeqProgressor,
              let service = progressorService else {
            disconnect(preserveAutoReconnect: preserveAutoReconnect)
            return
        }

        if immediate {
            // .withResponse forces bluetoothd to wait for the device's ATT ack;
            // we spin the runloop so the delegate callback can fire before we
            // tear down the link (otherwise cancelPeripheralConnection races the
            // write and the device never receives 0x6E).
            var writeCompleted = false
            service.onWriteComplete = { writeCompleted = true }
            service.sendShutdown(writeType: .withResponse)
            let deadline = Date().addingTimeInterval(1.0)
            while !writeCompleted && Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            if !writeCompleted {
                Log.ble.info("Shutdown write did not ack within budget - disconnecting anyway")
            }
            disconnect(preserveAutoReconnect: preserveAutoReconnect)
            return
        }

        var disconnected = false
        let finish: () -> Void = { [weak self] in
            guard !disconnected else { return }
            disconnected = true
            self?.disconnect(preserveAutoReconnect: preserveAutoReconnect)
        }

        service.onWriteComplete = finish
        service.sendShutdown(writeType: .withResponse)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if !disconnected {
                Log.ble.info("Shutdown write timeout - forcing disconnect")
                finish()
            }
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
        isReconnecting = false
        resetRetryState()
        cancelBackgroundDisconnectTimer()
        pendingDevice = nil

        centralManager.stopScan()

        // Stop device-specific services
        whc06Service?.stop()
        whc06Service = nil
        cts500Service = nil
        pitchSixService = nil
        progressorService = nil

        if let peripheral = connectedPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        connectedPeripheral = nil
        connectedDeviceName = nil
        connectedDeviceType = nil
        clearReadingCorrection()

        // Clear last connected device to prevent auto-reconnect (unless preserving)
        if !preserveAutoReconnect {
            lastConnectedDeviceId = ""
            lastConnectedDeviceTypeRaw = ""
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
            isReconnecting = false
            connectionState = .error("Bluetooth is off")
        case .unauthorized:
            Log.ble.error("Bluetooth unauthorized")
            isReconnecting = false
            connectionState = .error("Bluetooth unauthorized")
        case .unsupported:
            Log.ble.error("Bluetooth unsupported")
            isReconnecting = false
            connectionState = .error("Bluetooth unsupported")
        default:
            connectionState = .disconnected
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        // Detect device type from advertisement
        guard let deviceType = DeviceType.detect(name: peripheral.name, advertisementData: advertisementData) else {
            return
        }

        // Filter by selected device type
        guard deviceType == selectedDeviceType else {
            return
        }

        // For WHC06, process advertisement data if already "connected" and from the selected device
        if deviceType == .weihengWHC06 && connectionState == .connected && connectedDeviceType == .weihengWHC06,
           let selectedDevice = pendingDevice,
           peripheral.identifier == selectedDevice.peripheralIdentifier {
            whc06Service?.processAdvertisement(advertisementData, rssi: RSSI.intValue)
            return
        }

        // Cache the peripheral for later connection (not for WHC06 which doesn't connect)
        if deviceType.usesGATTConnection {
            peripheralCache[peripheral.identifier] = peripheral
        }

        // Create device
        let device = ForceDevice(peripheral: peripheral, type: deviceType, rssi: RSSI.intValue)

        // Update or add device to list
        if let index = discoveredDevices.firstIndex(where: { $0.id == device.id }) {
            discoveredDevices[index].rssi = RSSI.intValue
        } else {
            Log.ble.info("Discovered \(deviceType.shortName): \(device.name)")
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
        isReconnecting = false

        connectedDeviceName = peripheral.name ?? "Unknown Device"

        // Determine device type from pending device or detect from name
        let deviceType = pendingDevice?.type ?? DeviceType.detect(name: peripheral.name, advertisementData: [:]) ?? .tindeqProgressor
        connectedDeviceType = deviceType
        prepareReadingCorrection(for: ReadingCorrectionDevice(peripheralID: peripheral.identifier, type: deviceType))
        connectionState = .connected

        // Save as last connected device for auto-reconnect
        lastConnectedDeviceId = peripheral.identifier.uuidString
        lastConnectedDeviceTypeRaw = deviceType.rawValue

        // Create appropriate service handler based on device type
        switch deviceType {
        case .tindeqProgressor:
            setupProgressorService(peripheral: peripheral)

        case .pitchSixForceBoard:
            setupPitchSixService(peripheral: peripheral)

        case .jinlianCTS500:
            setupCTS500Service(peripheral: peripheral)

        case .weihengWHC06:
            // WHC06 doesn't use GATT connection, this shouldn't happen
            break
        }
    }

    private func setupProgressorService(peripheral: CBPeripheral) {
        let device = ReadingCorrectionDevice(peripheralID: peripheral.identifier, type: .tindeqProgressor)
        progressorService = ProgressorService(peripheral: peripheral)
        progressorService?.onForceSample = { [weak self] force, timestamp in
            self?.receiveForceSample(force, timestamp: timestamp, from: device)
        }
        progressorService?.onDiscoveryTimeout = { [weak self] in
            guard let self = self else { return }
            Log.ble.error("Discovery timeout - disconnecting to retry")
            if let peripheral = self.connectedPeripheral {
                self.centralManager.cancelPeripheralConnection(peripheral)
            }
        }
        progressorService?.discoverServices()
    }

    private func setupPitchSixService(peripheral: CBPeripheral) {
        let device = ReadingCorrectionDevice(peripheralID: peripheral.identifier, type: .pitchSixForceBoard)
        pitchSixService = PitchSixService(peripheral: peripheral)
        pitchSixService?.onForceSample = { [weak self] force, timestamp in
            self?.receiveForceSample(force, timestamp: timestamp, from: device)
        }
        pitchSixService?.onDiscoveryTimeout = { [weak self] in
            guard let self = self else { return }
            Log.ble.error("PitchSix discovery timeout - disconnecting to retry")
            if let peripheral = self.connectedPeripheral {
                self.centralManager.cancelPeripheralConnection(peripheral)
            }
        }
        pitchSixService?.discoverServices()
    }

    private func setupCTS500Service(peripheral: CBPeripheral) {
        let device = ReadingCorrectionDevice(peripheralID: peripheral.identifier, type: .jinlianCTS500)
        cts500Service = CTS500Service(peripheral: peripheral)
        cts500Service?.onForceSample = { [weak self] force, timestamp in
            self?.receiveForceSample(force, timestamp: timestamp, from: device)
        }
        cts500Service?.onDiscoveryTimeout = { [weak self] in
            guard let self = self else { return }
            Log.ble.error("CTS500 discovery timeout - disconnecting to retry")
            if let peripheral = self.connectedPeripheral {
                self.centralManager.cancelPeripheralConnection(peripheral)
            }
        }
        cts500Service?.discoverServices()
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        Log.ble.error("Failed to connect: \(error?.localizedDescription ?? "Unknown error")")
        connectionState = .error(error?.localizedDescription ?? "Connection failed")
        connectedPeripheral = nil
        progressorService = nil
        pitchSixService = nil
        cts500Service = nil
        connectedDeviceName = nil
        connectedDeviceType = nil

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
        connectedPeripheral = nil
        progressorService = nil
        pitchSixService = nil
        cts500Service = nil

        // Set isReconnecting BEFORE connectionState to prevent SwiftUI from
        // briefly switching to scanner view and destroying the web view
        if shouldAutoReconnect {
            isReconnecting = true
        }
        connectionState = .disconnected

        if shouldAutoReconnect {
            scheduleRetry()
        } else {
            connectedDeviceName = nil
            connectedDeviceType = nil
        }
    }
}
