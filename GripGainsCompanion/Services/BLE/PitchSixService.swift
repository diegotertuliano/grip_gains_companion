import CoreBluetooth

/// Handles PitchSix Force Board BLE protocol: service discovery, notifications, and data parsing
class PitchSixService: NSObject, CBPeripheralDelegate {
    private let peripheral: CBPeripheral
    private var forceRxCharacteristic: CBCharacteristic?
    private var weightTxCharacteristic: CBCharacteristic?
    private var discoveryTimer: Timer?

    /// Callback when force samples are received (force value in kg, timestamp in microseconds)
    var onForceSample: ((Double, UInt32) -> Void)?

    /// Callback when discovery times out
    var onDiscoveryTimeout: (() -> Void)?

    /// Callback fired on successful write to the TX characteristic (one-shot consumers should re-set)
    var onWriteComplete: (() -> Void)?

    /// Base timestamp for generating synthetic timestamps (PitchSix doesn't provide timestamps)
    private var baseTimestamp: Date?
    private var sampleCounter: UInt32 = 0

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
        Log.ble.info("Starting PitchSix service discovery...")
        startDiscoveryTimeout()
        // Discover both Force service (for RX) and Weight service (for TX commands)
        peripheral.discoverServices([
            AppConstants.pitchSixForceServiceUUID,
            AppConstants.pitchSixWeightServiceUUID
        ])
    }

    /// Start continuous force streaming
    func startStreaming() {
        guard let txChar = weightTxCharacteristic else {
            Log.ble.error("TX characteristic not available")
            return
        }
        Log.ble.info("Starting PitchSix streaming...")
        baseTimestamp = Date()
        sampleCounter = 0
        peripheral.writeValue(AppConstants.pitchSixStartStreamingCommand, for: txChar, type: .withResponse)
    }

    /// Stop streaming
    func stopStreaming() {
        guard let txChar = weightTxCharacteristic else {
            Log.ble.error("TX characteristic not available")
            return
        }
        Log.ble.info("Stopping PitchSix streaming...")
        peripheral.writeValue(AppConstants.pitchSixStopCommand, for: txChar, type: .withResponse)
    }

    /// Tare/zero the scale
    func tare() {
        guard let txChar = weightTxCharacteristic else {
            Log.ble.error("TX characteristic not available")
            return
        }
        Log.ble.info("Taring PitchSix...")
        peripheral.writeValue(AppConstants.pitchSixTareCommand, for: txChar, type: .withResponse)
    }

    // MARK: - Discovery Timeout

    private func startDiscoveryTimeout() {
        cancelDiscoveryTimeout()
        discoveryTimer = Timer.scheduledTimer(withTimeInterval: AppConstants.discoveryTimeout, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            Log.ble.error("PitchSix service discovery timed out")
            self.onDiscoveryTimeout?()
        }
    }

    private func cancelDiscoveryTimeout() {
        discoveryTimer?.invalidate()
        discoveryTimer = nil
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            Log.ble.error("Discovering PitchSix services: \(error.localizedDescription)")
            return
        }

        Log.ble.info("PitchSix services discovered: \(peripheral.services?.count ?? 0)")

        guard let services = peripheral.services else {
            Log.ble.error("No services found")
            return
        }

        for service in services {
            if service.uuid == AppConstants.pitchSixForceServiceUUID {
                Log.ble.info("Found PitchSix Force service, discovering characteristics...")
                peripheral.discoverCharacteristics(
                    [AppConstants.pitchSixForceRxCharacteristicUUID],
                    for: service
                )
            } else if service.uuid == AppConstants.pitchSixWeightServiceUUID {
                Log.ble.info("Found PitchSix Weight service, discovering characteristics...")
                peripheral.discoverCharacteristics(
                    [AppConstants.pitchSixWeightTxCharacteristicUUID],
                    for: service
                )
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error = error {
            Log.ble.error("Discovering PitchSix characteristics: \(error.localizedDescription)")
            return
        }

        Log.ble.info("PitchSix characteristics found for service \(service.uuid): \(service.characteristics?.count ?? 0)")

        guard let characteristics = service.characteristics else {
            Log.ble.error("No characteristics found")
            return
        }

        for characteristic in characteristics {
            switch characteristic.uuid {
            case AppConstants.pitchSixForceRxCharacteristicUUID:
                Log.ble.info("Found PitchSix Force RX characteristic, enabling notifications...")
                forceRxCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)

            case AppConstants.pitchSixWeightTxCharacteristicUUID:
                Log.ble.info("Found PitchSix Weight TX characteristic")
                weightTxCharacteristic = characteristic
                // Start streaming once we have the TX characteristic
                startStreaming()

            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error = error {
            Log.ble.error("Receiving PitchSix notification: \(error.localizedDescription)")
            return
        }

        guard characteristic.uuid == AppConstants.pitchSixForceRxCharacteristicUUID,
              let data = characteristic.value else {
            return
        }

        parseNotification(data)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error = error {
            Log.ble.error("Writing to PitchSix characteristic: \(error.localizedDescription)")
            return
        }
        Log.ble.info("PitchSix write successful")
        onWriteComplete?()
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error = error {
            Log.ble.error("Enabling PitchSix notifications: \(error.localizedDescription)")
            return
        }
        Log.ble.info("PitchSix notifications \(characteristic.isNotifying ? "enabled" : "disabled")")

        // Discovery complete - cancel timeout
        if characteristic.isNotifying && characteristic.uuid == AppConstants.pitchSixForceRxCharacteristicUUID {
            cancelDiscoveryTimeout()
        }
    }

    // MARK: - Data Parsing

    /// Parse incoming PitchSix BLE notification data
    /// Format: bytes 0-1 = sample count, then 3-byte samples
    /// Each sample: raw value = (byte0 × 32768) + (byte1 × 256) + byte2
    /// Weight in kg = raw value × 0.453592
    private func parseNotification(_ data: Data) {
        guard data.count >= 2 else { return }

        // First 2 bytes are sample count (big-endian)
        let sampleCount = Int(data[0]) << 8 | Int(data[1])
        let payload = data.dropFirst(2)

        let sampleSize = PitchSixProtocol.sampleSize  // 3 bytes

        for i in 0..<sampleCount {
            let offset = i * sampleSize
            guard offset + sampleSize <= payload.count else { break }

            let startIndex = payload.startIndex + offset
            let byte0 = Int(payload[startIndex])
            let byte1 = Int(payload[startIndex + 1])
            let byte2 = Int(payload[startIndex + 2])

            // Raw value calculation: (byte0 × 32768) + (byte1 × 256) + byte2
            let rawValue = Double(byte0 * 32768 + byte1 * 256 + byte2)

            // Convert to kg: raw × 0.453592
            let weightKg = rawValue * PitchSixProtocol.rawToKgFactor

            // Generate synthetic timestamp (microseconds since start)
            let timestamp = generateTimestamp()

            onForceSample?(weightKg, timestamp)
        }
    }

    /// Generate synthetic timestamp in microseconds
    private func generateTimestamp() -> UInt32 {
        sampleCounter += 1

        if let base = baseTimestamp {
            // Calculate elapsed time in microseconds
            let elapsed = Date().timeIntervalSince(base)
            return UInt32(elapsed * 1_000_000)
        }

        // Fallback: use counter with assumed 80Hz sample rate
        return sampleCounter * 12500  // 1,000,000 / 80 = 12,500 µs per sample
    }
}
