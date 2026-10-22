import CoreBluetooth

/// Handles Tindeq Progressor BLE protocol: service discovery, notifications, and data parsing
class ProgressorService: NSObject, CBPeripheralDelegate {
    private let peripheral: CBPeripheral
    private var notifyCharacteristic: CBCharacteristic?
    private var writeCharacteristic: CBCharacteristic?
    private var discoveryTimer: Timer?
    private var notificationsReady = false
    private var didStartMeasurement = false
    private var awaitingBatteryResponse = false
    /// Kinds of in-flight writes with response; acks arrive in write order.
    private var pendingWriteIsBatteryQuery: [Bool] = []

    /// Callback when force samples are received (force value, timestamp in microseconds)
    var onForceSample: ((Double, UInt32) -> Void)?

    /// Callback when discovery times out
    var onDiscoveryTimeout: (() -> Void)?

    /// Callback fired on successful write to the control point (one-shot consumers should re-set)
    var onWriteComplete: (() -> Void)?

    /// Callback with the estimated battery percentage (0–100)
    var onBatteryLevel: ((Int) -> Void)?

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
        write(AppConstants.progressorStartWeightCommand, to: writeChar, type: .withResponse)
    }

    /// Request the battery voltage (0x6F). The reply arrives as a command-response notification.
    func requestBatteryVoltage() {
        guard let writeChar = writeCharacteristic else {
            Log.ble.error("Write characteristic not available for battery query")
            return
        }
        Log.ble.info("Sending Progressor battery voltage command (0x6F)")
        awaitingBatteryResponse = true
        write(AppConstants.progressorGetBatteryVoltageCommand, to: writeChar, type: .withResponse, isBatteryQuery: true)
    }

    /// Send the tare command to zero the scale (no load should be applied)
    func tare(writeType: CBCharacteristicWriteType = .withResponse) {
        guard let writeChar = writeCharacteristic else {
            Log.ble.error("Write characteristic not available for tare")
            return
        }
        Log.ble.info("Sending Progressor tare command (0x64)")
        write(AppConstants.progressorTareCommand, to: writeChar, type: writeType)
    }

    /// Send the shutdown (sleep) command to power off the device
    func sendShutdown(writeType: CBCharacteristicWriteType = .withResponse) {
        guard let writeChar = writeCharacteristic else {
            Log.ble.error("Write characteristic not available for shutdown")
            return
        }
        Log.ble.info("Sending Progressor shutdown command (0x6E)")
        write(AppConstants.progressorShutdownCommand, to: writeChar, type: writeType)
    }

    private func write(_ data: Data, to characteristic: CBCharacteristic,
                       type: CBCharacteristicWriteType, isBatteryQuery: Bool = false) {
        if type == .withResponse {
            pendingWriteIsBatteryQuery.append(isBatteryQuery)
        }
        peripheral.writeValue(data, for: characteristic, type: type)
    }

    /// Once notifications are on (so the battery reply isn't missed), query the battery
    /// and then start measuring. The query goes first so it never interrupts a live stream.
    private func startMeasurementIfReady() {
        guard notificationsReady, writeCharacteristic != nil, !didStartMeasurement else { return }
        didStartMeasurement = true
        requestBatteryVoltage()
        startWeightMeasurement()
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
                    [AppConstants.progressorNotifyCharacteristicUUID, AppConstants.progressorWriteCharacteristicUUID],
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
            case AppConstants.progressorNotifyCharacteristicUUID:
                Log.ble.info("Found notify characteristic, enabling notifications...")
                notifyCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)

            case AppConstants.progressorWriteCharacteristicUUID:
                Log.ble.info("Found write characteristic")
                writeCharacteristic = characteristic

            default:
                break
            }
        }

        startMeasurementIfReady()
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error = error {
            Log.ble.error("Receiving notification: \(error.localizedDescription)")
            return
        }

        guard characteristic.uuid == AppConstants.progressorNotifyCharacteristicUUID,
              let data = characteristic.value else {
            return
        }

        parseNotification(data)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        let wasBatteryQuery = pendingWriteIsBatteryQuery.isEmpty ? false : pendingWriteIsBatteryQuery.removeFirst()
        if wasBatteryQuery {
            if let error {
                Log.ble.error("Writing battery query: \(error.localizedDescription)")
                awaitingBatteryResponse = false
            }
            return
        }
        if let error = error {
            Log.ble.error("Writing to characteristic: \(error.localizedDescription)")
            return
        }
        Log.ble.info("Write successful")
        onWriteComplete?()
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

        guard characteristic.uuid == AppConstants.progressorNotifyCharacteristicUUID else { return }
        notificationsReady = characteristic.isNotifying
        startMeasurementIfReady()
    }

    // MARK: - Data Parsing

    /// Parse incoming BLE notification data
    /// Tindeq batches ~16 samples per notification, each with weight + timestamp
    private func parseNotification(_ data: Data) {
        if awaitingBatteryResponse, let millivolts = DeviceBattery.progressorMillivolts(fromResponse: data) {
            awaitingBatteryResponse = false
            let percent = DeviceBattery.percent(fromLithiumMillivolts: millivolts)
            Log.ble.info("Progressor battery: \(millivolts) mV (~\(percent)%)")
            onBatteryLevel?(percent)
            return
        }

        // Verify packet type and minimum size
        guard data.count >= ProgressorProtocol.packetMinSize,
              data[0] == ProgressorProtocol.weightDataPacketType else {
            return
        }

        // Parse ALL samples from notification (Tindeq batches ~16 samples per notification)
        // Each sample: 4-byte float (weight) + 4-byte uint32 (microseconds) = 8 bytes
        let sampleSize = AppConstants.progressorSampleSize  // 8 bytes
        let payload = data.dropFirst(2)  // Skip packet type and count byte

        for offset in stride(from: 0, to: payload.count - sampleSize + 1, by: sampleSize) {
            let startIndex = payload.startIndex + offset
            let weightData = payload[startIndex..<(startIndex + 4)]
            let timeData = payload[(startIndex + 4)..<(startIndex + 8)]

            // BLE sends 4-byte Float, convert to Double for consistency with rest of codebase
            let weightFloat = weightData.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
            let timestamp = timeData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }

            onForceSample?(Double(weightFloat), timestamp)
        }
    }
}
