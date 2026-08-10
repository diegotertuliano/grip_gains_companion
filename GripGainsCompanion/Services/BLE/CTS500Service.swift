import CoreBluetooth
import Foundation

/// CTS500 command and frame constants for the transparent UART protocol.
enum CTS500Protocol {
    enum Opcode: UInt8, CaseIterable {
        case tare = 0xA6
        case startWeightMeasurement = 0xAA
        case stopWeightMeasurement = 0xAB
    }

    static let header: UInt8 = 0x05
    static let responseFlag: UInt8 = 0x80
    static let acknowledgementFrameSize = 6
    static let dataFrameSize = 7

    static let commandOpcodes = Set(Opcode.allCases.map(\.rawValue))

    static func checksum<S: Sequence>(for bytes: S) -> UInt8 where S.Element == UInt8 {
        bytes.reduce(UInt8.zero) { UInt8(truncatingIfNeeded: UInt16($0) + UInt16($1)) }
    }

    static func command(_ opcode: Opcode, payload: (UInt8, UInt8, UInt8) = (0, 0, 0)) -> Data {
        var bytes = [header, opcode.rawValue, payload.0, payload.1, payload.2]
        bytes.append(checksum(for: bytes))
        return Data(bytes)
    }

    static func isValidFrame(_ data: Data) -> Bool {
        guard data.count >= acknowledgementFrameSize,
              data.first == header,
              let expectedChecksum = data.last else {
            return false
        }

        return checksum(for: data.dropLast()) == expectedChecksum
    }
}

/// A validated frame emitted by ``CTS500FrameParser``.
enum CTS500Frame: Equatable {
    case acknowledgement(opcode: UInt8, payload: [UInt8])
    case response(opcode: UInt8, payload: [UInt8])
    case weight(Double)
}

/// Buffers and validates CTS500 UART frames, including fragmented or combined BLE notifications.
struct CTS500FrameParser {
    private var buffer = Data()

    mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
    }

    mutating func append(_ data: Data) -> [CTS500Frame] {
        guard !data.isEmpty else { return [] }

        buffer.append(data)
        var frames: [CTS500Frame] = []

        while buffer.count >= CTS500Protocol.acknowledgementFrameSize {
            guard let headerIndex = buffer.firstIndex(of: CTS500Protocol.header) else {
                buffer.removeAll(keepingCapacity: true)
                break
            }

            let bytesBeforeHeader = buffer.distance(from: buffer.startIndex, to: headerIndex)
            if bytesBeforeHeader > 0 {
                buffer.removeFirst(bytesBeforeHeader)
            }

            guard buffer.count >= CTS500Protocol.acknowledgementFrameSize else { break }

            let secondByteIndex = buffer.index(after: buffer.startIndex)
            let secondByte = buffer[secondByteIndex]

            if CTS500Protocol.commandOpcodes.contains(secondByte) {
                let candidate = Data(buffer.prefix(CTS500Protocol.acknowledgementFrameSize))
                if CTS500Protocol.isValidFrame(candidate) {
                    let bytes = Array(candidate)
                    frames.append(.acknowledgement(opcode: bytes[1], payload: Array(bytes[2...4])))
                    buffer.removeFirst(candidate.count)
                    continue
                }
            }

            guard buffer.count >= CTS500Protocol.dataFrameSize else { break }

            let candidate = Data(buffer.prefix(CTS500Protocol.dataFrameSize))
            guard CTS500Protocol.isValidFrame(candidate) else {
                // Drop the invalid header and scan again so a following valid frame can recover.
                buffer.removeFirst()
                continue
            }

            let bytes = Array(candidate)
            if bytes[1] == CTS500Protocol.responseFlag {
                frames.append(.response(opcode: bytes[2], payload: Array(bytes[3...5])))
            } else if !CTS500Protocol.commandOpcodes.contains(bytes[1]) {
                let rawWeight = UInt32(bytes[2]) << 24 |
                    UInt32(bytes[3]) << 16 |
                    UInt32(bytes[4]) << 8 |
                    UInt32(bytes[5])
                frames.append(.weight(Double(rawWeight) / 100.0))
            }

            buffer.removeFirst(candidate.count)
        }

        return frames
    }
}

/// Handles Jinlian CTS500 service discovery, streaming commands, and weight notifications.
final class CTS500Service: NSObject, CBPeripheralDelegate {
    private let peripheral: CBPeripheral
    private var notifyCharacteristic: CBCharacteristic?
    private var writeCharacteristic: CBCharacteristic?
    private var discoveryTimer: Timer?
    private var notificationsReady = false
    private var didSendStartCommand = false
    private var frameParser = CTS500FrameParser()
    private var streamStartUptime: TimeInterval?

    /// Callback when force samples are received (force value in kg, timestamp in microseconds).
    var onForceSample: ((Double, UInt32) -> Void)?

    /// Callback when discovery times out.
    var onDiscoveryTimeout: (() -> Void)?

    /// One-shot callback fired when the device acknowledges a hardware tare.
    var onTareComplete: (() -> Void)?

    init(peripheral: CBPeripheral) {
        self.peripheral = peripheral
        super.init()
        peripheral.delegate = self
    }

    deinit {
        cancelDiscoveryTimeout()
    }

    func discoverServices() {
        Log.ble.info("Starting CTS500 service discovery...")
        startDiscoveryTimeout()
        peripheral.discoverServices([AppConstants.cts500ServiceUUID])
    }

    @discardableResult
    func startStreaming() -> Bool {
        guard writeCommand(CTS500Protocol.command(.startWeightMeasurement), description: "start streaming") else {
            return false
        }

        streamStartUptime = ProcessInfo.processInfo.systemUptime
        frameParser.reset()
        return true
    }

    func stopStreaming() {
        _ = writeCommand(CTS500Protocol.command(.stopWeightMeasurement), description: "stop streaming")
    }

    func tare() {
        _ = writeCommand(CTS500Protocol.command(.tare), description: "tare")
    }

    private func startDiscoveryTimeout() {
        cancelDiscoveryTimeout()
        discoveryTimer = Timer.scheduledTimer(
            withTimeInterval: AppConstants.discoveryTimeout,
            repeats: false
        ) { [weak self] _ in
            Log.ble.error("CTS500 service discovery timed out")
            self?.onDiscoveryTimeout?()
        }
    }

    private func cancelDiscoveryTimeout() {
        discoveryTimer?.invalidate()
        discoveryTimer = nil
    }

    private func startStreamingIfReady() {
        guard notificationsReady, writeCharacteristic != nil, !didSendStartCommand else { return }
        didSendStartCommand = true
        guard startStreaming() else {
            didSendStartCommand = false
            return
        }
        cancelDiscoveryTimeout()
    }

    @discardableResult
    private func writeCommand(_ data: Data, description: String) -> Bool {
        guard let characteristic = writeCharacteristic else {
            Log.ble.error("CTS500 write characteristic is unavailable for \(description)")
            return false
        }

        let writeType: CBCharacteristicWriteType
        if characteristic.properties.contains(.write) {
            writeType = .withResponse
        } else if characteristic.properties.contains(.writeWithoutResponse) {
            writeType = .withoutResponse
        } else {
            Log.ble.error("CTS500 write characteristic does not support writes")
            return false
        }

        Log.ble.info("Sending CTS500 \(description) command...")
        peripheral.writeValue(data, for: characteristic, type: writeType)
        return true
    }

    private func generatedTimestamp() -> UInt32 {
        let now = ProcessInfo.processInfo.systemUptime
        let start = streamStartUptime ?? now
        streamStartUptime = start
        let elapsedMicroseconds = UInt64(max(0, now - start) * 1_000_000)
        return UInt32(truncatingIfNeeded: elapsedMicroseconds)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            Log.ble.error("Discovering CTS500 services: \(error.localizedDescription)")
            return
        }

        guard let service = peripheral.services?.first(where: { $0.uuid == AppConstants.cts500ServiceUUID }) else {
            Log.ble.error("CTS500 service not found")
            return
        }

        peripheral.discoverCharacteristics(
            [AppConstants.cts500NotifyCharacteristicUUID, AppConstants.cts500WriteCharacteristicUUID],
            for: service
        )
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error {
            Log.ble.error("Discovering CTS500 characteristics: \(error.localizedDescription)")
            return
        }

        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case AppConstants.cts500NotifyCharacteristicUUID:
                notifyCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)

            case AppConstants.cts500WriteCharacteristicUUID:
                writeCharacteristic = characteristic

            default:
                break
            }
        }

        startStreamingIfReady()
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            Log.ble.error("Enabling CTS500 notifications: \(error.localizedDescription)")
            return
        }

        guard characteristic.uuid == AppConstants.cts500NotifyCharacteristicUUID else { return }
        notificationsReady = characteristic.isNotifying
        Log.ble.info("CTS500 notifications \(self.notificationsReady ? "enabled" : "disabled")")
        startStreamingIfReady()
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            Log.ble.error("Receiving CTS500 notification: \(error.localizedDescription)")
            return
        }

        guard characteristic.uuid == AppConstants.cts500NotifyCharacteristicUUID,
              let data = characteristic.value else {
            return
        }

        for frame in frameParser.append(data) {
            switch frame {
            case .weight(let weight):
                onForceSample?(weight, generatedTimestamp())

            case .acknowledgement(let opcode, _):
                if opcode == CTS500Protocol.Opcode.tare.rawValue {
                    let completion = onTareComplete
                    onTareComplete = nil
                    completion?()
                }

            case .response:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            Log.ble.error("Writing to CTS500 characteristic: \(error.localizedDescription)")
        }
    }
}
