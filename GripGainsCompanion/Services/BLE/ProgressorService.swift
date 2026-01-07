import CoreBluetooth

/// Handles Tindeq Progressor BLE protocol: service discovery, notifications, and data parsing
class ProgressorService: NSObject, CBPeripheralDelegate {
    private let peripheral: CBPeripheral
    private var notifyCharacteristic: CBCharacteristic?
    private var writeCharacteristic: CBCharacteristic?
    private var discoveryTimer: Timer?

    /// Callback when force samples are received (force value, timestamp in microseconds)
    var onForceSample: ((Float, UInt32) -> Void)?

    /// Callback when discovery times out
    var onDiscoveryTimeout: (() -> Void)?

    init(peripheral: CBPeripheral) {
        self.peripheral = peripheral
        super.init()
        peripheral.delegate = self
    }

    deinit {
        cancelDiscoveryTimeout()
    }

    // MARK: - Public Methods

    func discoverServices() {
        Log.ble.info("Starting service discovery...")
        startDiscoveryTimeout()
        peripheral.discoverServices([AppConstants.progressorServiceUUID])
    }

    // MARK: - Discovery Timeout

    private func startDiscoveryTimeout() {
        cancelDiscoveryTimeout()
        discoveryTimer = Timer.scheduledTimer(withTimeInterval: AppConstants.discoveryTimeout, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            Log.ble.error("Service discovery timed out")
            self.onDiscoveryTimeout?()
        }
    }

    private func cancelDiscoveryTimeout() {
        discoveryTimer?.invalidate()
        discoveryTimer = nil
    }

    /// Send the start weight command to begin measurements
    func startWeightMeasurement() {
        guard let writeChar = writeCharacteristic else {
            Log.ble.error("Write characteristic not available")
            return
        }
        Log.ble.info("Sending start weight command...")
        peripheral.writeValue(AppConstants.startWeightCommand, for: writeChar, type: .withResponse)
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            Log.ble.error("Discovering services: \(error.localizedDescription)")
            return
        }

        Log.ble.info("Services discovered: \(peripheral.services?.count ?? 0)")

        guard let services = peripheral.services else {
            Log.ble.error("No services found")
            return
        }

        for service in services {
            if service.uuid == AppConstants.progressorServiceUUID {
                Log.ble.info("Found Progressor service, discovering characteristics...")
                peripheral.discoverCharacteristics(
                    [AppConstants.notifyCharacteristicUUID, AppConstants.writeCharacteristicUUID],
                    for: service
                )
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error = error {
            Log.ble.error("Discovering characteristics: \(error.localizedDescription)")
            return
        }

        Log.ble.info("Characteristics found: \(service.characteristics?.count ?? 0)")

        guard let characteristics = service.characteristics else {
            Log.ble.error("No characteristics found")
            return
        }

        for characteristic in characteristics {
            switch characteristic.uuid {
            case AppConstants.notifyCharacteristicUUID:
                Log.ble.info("Found notify characteristic, enabling notifications...")
                notifyCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)

            case AppConstants.writeCharacteristicUUID:
                Log.ble.info("Found write characteristic")
                writeCharacteristic = characteristic
                // Start weight measurement once we have the write characteristic
                startWeightMeasurement()

            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error = error {
            Log.ble.error("Receiving notification: \(error.localizedDescription)")
            return
        }

        guard characteristic.uuid == AppConstants.notifyCharacteristicUUID,
              let data = characteristic.value else {
            return
        }

        parseNotification(data)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error = error {
            Log.ble.error("Writing to characteristic: \(error.localizedDescription)")
            return
        }
        Log.ble.info("Write successful")
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error = error {
            Log.ble.error("Enabling notifications: \(error.localizedDescription)")
            return
        }
        Log.ble.info("Notifications \(characteristic.isNotifying ? "enabled" : "disabled")")

        // Discovery complete - cancel timeout
        if characteristic.isNotifying {
            cancelDiscoveryTimeout()
        }
    }

    // MARK: - Data Parsing

    /// Parse incoming BLE notification data
    /// Tindeq batches ~16 samples per notification, each with weight + timestamp
    private func parseNotification(_ data: Data) {
        // Verify packet type and minimum size
        guard data.count >= ProgressorProtocol.packetMinSize,
              data[0] == ProgressorProtocol.weightDataPacketType else {
            return
        }

        // Parse ALL samples from notification (Tindeq batches ~16 samples per notification)
        // Each sample: 4-byte float (weight) + 4-byte uint32 (microseconds) = 8 bytes
        let sampleSize = AppConstants.sampleSize  // 8 bytes
        let payload = data.dropFirst(2)  // Skip packet type and count byte

        for offset in stride(from: 0, to: payload.count - sampleSize + 1, by: sampleSize) {
            let startIndex = payload.startIndex + offset
            let weightData = payload[startIndex..<(startIndex + 4)]
            let timeData = payload[(startIndex + 4)..<(startIndex + 8)]

            let weight = weightData.withUnsafeBytes { $0.load(as: Float.self) }
            let timestamp = timeData.withUnsafeBytes { $0.load(as: UInt32.self) }

            onForceSample?(weight, timestamp)
        }
    }
}
