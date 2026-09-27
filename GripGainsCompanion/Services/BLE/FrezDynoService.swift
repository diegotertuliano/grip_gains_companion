import CoreBluetooth
import Foundation

enum FrezGATT {
    static let service = CBUUID(string: "da8a6c41-154b-4b9a-9b00-2f84dfcebfe9")
    static let notify = CBUUID(string: "da8a6c42-154b-4b9a-9b00-2f84dfcebfe9")
    static let write = CBUUID(string: "da8a6c43-154b-4b9a-9b00-2f84dfcebfe9")
    static let information = CBUUID(string: "180A")
    static let serial = CBUUID(string: "2A25")
    static let firmware = CBUUID(string: "2A28")
    static let batteryService = CBUUID(string: "180F")
    static let battery = CBUUID(string: "2A19")
}

protocol FrezPeripheral: AnyObject {
    var delegate: CBPeripheralDelegate? { get set }
    var state: CBPeripheralState { get }
    func discoverServices(_ serviceUUIDs: [CBUUID]?)
    func discoverCharacteristics(_ characteristicUUIDs: [CBUUID]?, for service: CBService)
    func readValue(for characteristic: CBCharacteristic)
    func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic)
    func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType)
}

extension CBPeripheral: FrezPeripheral {}

/// All BLE callbacks and session transitions run on the main queue, like BluetoothManager.
final class FrezDynoService: NSObject, CBPeripheralDelegate {
    private let peripheral: FrezPeripheral
    private let coefficients: FrezCoefficientProviding
    private var accessKey: String?
    private var coefficientTask: Task<Void, Never>?
    private var timer: Timer?
    private var stopTimer: Timer?
    private var stopCompletion: (() -> Void)?
    private var active = false
    private var stopping = false
    private var pendingServices = Set<CBUUID>()
    private var pendingReads = Set<CBUUID>()
    private var notifyCharacteristic: CBCharacteristic?
    private var writeCharacteristic: CBCharacteristic?
    private var serial: String?
    private(set) var firmwareVersion: String?
    private(set) var batteryLevel: UInt8?
    private var measurement: FrezMeasurement?
    private var requestedCoefficient = false
    private var requestedNotifications = false
    private var sentStart = false
    private var ready = false
    private var lastPacketUptime: TimeInterval?

    var onStatus: ((String) -> Void)?
    var onReady: (() -> Void)?
    var onForceSample: ((Double, UInt32) -> Void)?
    var onError: ((FrezError) -> Void)?

    init(peripheral: FrezPeripheral, accessKey: String,
         coefficients: FrezCoefficientProviding = FrezCoefficientClient()) {
        self.peripheral = peripheral
        self.accessKey = accessKey
        self.coefficients = coefficients
        super.init()
        peripheral.delegate = self
    }

    deinit {
        coefficientTask?.cancel()
        timer?.invalidate()
        stopTimer?.invalidate()
    }

    func discoverServices() {
        active = true
        onStatus?("Reading Dyno information… Keep it unloaded.")
        timer = Timer.scheduledTimer(withTimeInterval: AppConstants.discoveryTimeout, repeats: false) { [weak self] _ in
            self?.fail(.protocolFailure("Frez setup timed out. Keep the Dyno nearby and unloaded, then reconnect."))
        }
        peripheral.discoverServices([FrezGATT.service, FrezGATT.information, FrezGATT.batteryService])
    }

    func servicesDiscovered(_ services: [CBService]) {
        guard active else { return }
        let ids = Set(services.map(\.uuid))
        guard ids.contains(FrezGATT.service), ids.contains(FrezGATT.information) else {
            failProtocol("Required Frez services are missing.")
            return
        }
        let relevant = services.filter { [FrezGATT.service, FrezGATT.information, FrezGATT.batteryService].contains($0.uuid) }
        pendingServices = Set(relevant.map(\.uuid))
        for service in relevant {
            let ids: [CBUUID]
            switch service.uuid {
            case FrezGATT.service: ids = [FrezGATT.notify, FrezGATT.write]
            case FrezGATT.information: ids = [FrezGATT.serial, FrezGATT.firmware]
            default: ids = [FrezGATT.battery]
            }
            peripheral.discoverCharacteristics(ids, for: service)
        }
    }

    func characteristicsDiscovered(_ characteristics: [CBCharacteristic], for service: CBUUID) {
        guard active else { return }
        if service == FrezGATT.service {
            notifyCharacteristic = characteristics.first { $0.uuid == FrezGATT.notify && $0.properties.contains(.notify) }
            writeCharacteristic = characteristics.first { $0.uuid == FrezGATT.write && $0.properties.contains(.write) }
            guard notifyCharacteristic != nil, writeCharacteristic != nil else {
                failProtocol("Required Frez measurement characteristics are missing.")
                return
            }
        } else {
            if service == FrezGATT.information,
               !characteristics.contains(where: { $0.uuid == FrezGATT.serial && $0.properties.contains(.read) }) {
                failProtocol("The Frez serial characteristic is missing.")
                return
            }
            for characteristic in characteristics where characteristic.properties.contains(.read) {
                guard [FrezGATT.serial, FrezGATT.firmware, FrezGATT.battery].contains(characteristic.uuid) else { continue }
                pendingReads.insert(characteristic.uuid)
                peripheral.readValue(for: characteristic)
            }
        }
        pendingServices.remove(service)
        fetchCoefficientIfReady()
    }

    func receivedValue(_ data: Data, for uuid: CBUUID) {
        guard active else { return }
        switch uuid {
        case FrezGATT.serial:
            serial = String(data: data, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        case FrezGATT.firmware:
            firmwareVersion = String(data: data, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        case FrezGATT.battery:
            batteryLevel = data.first.flatMap { $0 <= 100 ? $0 : nil }
        case FrezGATT.notify:
            guard sentStart, measurement != nil else { return }
            do {
                // iOS negotiates MTU automatically. The parser requires all 74 bytes;
                // it never reconstructs a truncated notification or guesses missing samples.
                let samples = try measurement!.process(data)
                lastPacketUptime = ProcessInfo.processInfo.systemUptime
                if !ready, !samples.isEmpty {
                    ready = true
                    timer?.invalidate()
                    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                        guard let self, let lastPacketUptime = self.lastPacketUptime else { return }
                        if ProcessInfo.processInfo.systemUptime - lastPacketUptime > 5 {
                            self.failProtocol("The Frez data stream stopped. Reconnect to continue.")
                        }
                    }
                    onReady?()
                }
                for sample in samples {
                    guard active else { break }
                    onForceSample?(sample.weight, sample.timestamp)
                }
            } catch let error as FrezError { fail(error) }
            catch { failProtocol("Invalid Frez measurement.") }
        default: return
        }
        pendingReads.remove(uuid)
        fetchCoefficientIfReady()
    }

    private func fetchCoefficientIfReady() {
        guard active, pendingServices.isEmpty, pendingReads.isEmpty,
              notifyCharacteristic != nil, writeCharacteristic != nil, !requestedCoefficient else { return }
        guard let serial else { fail(.invalidSerial); return }
        guard let accessKey else { fail(.missingKey); return }
        requestedCoefficient = true
        self.accessKey = nil
        onStatus?("Checking Frez calibration… Keep the Dyno unloaded.")
        let provider = coefficients
        coefficientTask = Task { @MainActor [weak self] in
            do {
                let coefficient = try await provider.coefficient(serial: serial, accessKey: accessKey)
                guard !Task.isCancelled, let self, self.active else { return }
                self.measurement = try FrezMeasurement(coefficient: coefficient)
                self.requestedNotifications = true
                if let characteristic = self.notifyCharacteristic {
                    self.peripheral.setNotifyValue(true, for: characteristic)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.fail(error as? FrezError ?? .network)
            }
        }
    }

    func notificationStateChanged(_ enabled: Bool) {
        if stopping { if !enabled { finishStop() }; return }
        guard active, requestedNotifications else { return }
        guard enabled else { failProtocol("Frez notifications were disabled. Reconnect to continue."); return }
        guard !sentStart, let characteristic = writeCharacteristic, measurement != nil else { return }
        sentStart = true
        onStatus?("Zeroing Dyno… Keep it unloaded.")
        peripheral.writeValue(Data([0x01, 0x00]), for: characteristic, type: .withResponse)
    }

    /// Send Stop, await its acknowledgment, then disable notifications before disconnecting.
    /// A bounded timeout still allows cleanup if the peripheral no longer responds.
    func stop(completion: @escaping () -> Void) {
        guard !stopping else { return }
        active = false
        stopping = true
        accessKey = nil
        coefficientTask?.cancel()
        coefficientTask = nil
        measurement = nil
        timer?.invalidate()
        stopCompletion = completion
        guard peripheral.state == .connected else { finishStop(); return }
        stopTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            self?.finishStop()
        }
        if sentStart, let characteristic = writeCharacteristic {
            peripheral.writeValue(Data([0x02, 0x00]), for: characteristic, type: .withResponse)
        } else {
            disableNotifications()
        }
    }

    func commandCompleted(error: Error?) {
        if stopping { disableNotifications(); return }
        if error != nil { failProtocol("The Frez measurement command failed. Reconnect to continue.") }
    }

    private func disableNotifications() {
        if requestedNotifications, let characteristic = notifyCharacteristic {
            peripheral.setNotifyValue(false, for: characteristic)
        } else { finishStop() }
    }

    private func finishStop() {
        stopTimer?.invalidate()
        stopTimer = nil
        let completion = stopCompletion
        stopCompletion = nil
        invalidate()
        completion?()
    }

    /// Unexpected disconnect: discard tare, coefficient, and pending asynchronous work.
    func connectionLost() {
        finishStop()
    }

    func invalidate() {
        active = false
        accessKey = nil
        coefficientTask?.cancel()
        coefficientTask = nil
        timer?.invalidate()
        stopTimer?.invalidate()
        measurement = nil
        if peripheral.delegate === self { peripheral.delegate = nil }
    }

    private func failProtocol(_ message: String) {
        fail(.protocolFailure("\(message) Firmware: \(firmwareVersion ?? "unknown")."))
    }

    private func fail(_ error: FrezError) {
        guard active else { return }
        active = false
        timer?.invalidate()
        coefficientTask?.cancel()
        onError?(error)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else { failProtocol("Frez service discovery failed."); return }
        servicesDiscovered(peripheral.services ?? [])
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else { failProtocol("Frez characteristic discovery failed."); return }
        characteristicsDiscovered(service.characteristics ?? [], for: service.uuid)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else { failProtocol("Could not read Frez data."); return }
        receivedValue(data, for: characteristic.uuid)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil else {
            if stopping { finishStop() } else { failProtocol("Could not enable Frez notifications.") }
            return
        }
        notificationStateChanged(characteristic.isNotifying)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        commandCompleted(error: error)
    }
}
