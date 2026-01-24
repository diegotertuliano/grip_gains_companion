import CoreBluetooth

/// Handles Weiheng WH-C06 BLE protocol: advertisement-based weight data parsing
/// Unlike other devices, the WHC06 broadcasts data via advertisements rather than GATT connection
class WHC06Service {
    /// Callback when force samples are received (force value in kg, timestamp in microseconds)
    var onForceSample: ((Double, UInt32) -> Void)?

    /// Base timestamp for generating synthetic timestamps
    private var baseTimestamp: Date?
    private var sampleCounter: UInt32 = 0

    /// Timeout timer for detecting device disconnect (no advertisements)
    private var disconnectTimer: Timer?

    /// Callback when device appears to be disconnected (no advertisements received)
    var onDisconnect: (() -> Void)?

    /// Time without advertisement before considering device disconnected
    private let disconnectTimeout: TimeInterval = 10.0

    init() {
        baseTimestamp = Date()
    }

    deinit {
        stopDisconnectTimer()
    }

    // MARK: - Public Methods

    /// Start "connection" - for WHC06 this just resets the state
    func start() {
        Log.ble.info("Starting WHC06 service...")
        baseTimestamp = Date()
        sampleCounter = 0
        resetDisconnectTimer()
    }

    /// Stop "connection"
    func stop() {
        Log.ble.info("Stopping WHC06 service...")
        stopDisconnectTimer()
    }

    /// Process advertisement data from the WHC06
    /// Called by BluetoothManager when an advertisement is received
    func processAdvertisement(_ advertisementData: [String: Any], rssi: Int) {
        guard let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data else {
            return
        }

        guard let weight = parseManufacturerData(manufacturerData) else {
            return
        }

        // Reset disconnect timer since we received data
        resetDisconnectTimer()

        // Send every sample - iOS advertisement rate is already slow for WHC06,
        // and we need continuous samples for calibration to complete
        let timestamp = generateTimestamp()
        onForceSample?(weight, timestamp)
    }

    // MARK: - Data Parsing

    /// Parse manufacturer data from WHC06 advertisement
    /// Format: bytes 12-13 contain weight as big-endian 16-bit integer, divided by 100 for kg
    /// (bytes 0-1 are the manufacturer ID prefix in iOS CoreBluetooth)
    private func parseManufacturerData(_ data: Data) -> Double? {
        // Verify minimum data size (need bytes 12-13 for weight)
        guard data.count >= WHC06Protocol.minDataSize else {
            return nil
        }

        // Extract weight from bytes 12-13 (big-endian, signed Int16 for negative values after tare)
        let weightOffset = WHC06Protocol.weightByteOffset
        let weightBytes = data.subdata(in: weightOffset..<weightOffset + 2)
        let rawWeight = weightBytes.withUnsafeBytes { buffer in
            Int16(bigEndian: buffer.load(as: Int16.self))
        }

        // Convert to kg (divide by 100)
        let weightKg = Double(rawWeight) / WHC06Protocol.weightDivisor

        return weightKg
    }

    // MARK: - Timestamp Generation

    /// Generate synthetic timestamp in microseconds
    private func generateTimestamp() -> UInt32 {
        sampleCounter += 1

        if let base = baseTimestamp {
            // Calculate elapsed time in microseconds
            let elapsed = Date().timeIntervalSince(base)
            return UInt32(elapsed * 1_000_000)
        }

        // Fallback: use counter with assumed 2Hz sample rate
        return sampleCounter * 500_000  // 1,000,000 / 2 = 500,000 µs per sample
    }

    // MARK: - Disconnect Detection

    private func resetDisconnectTimer() {
        stopDisconnectTimer()
        disconnectTimer = Timer.scheduledTimer(withTimeInterval: disconnectTimeout, repeats: false) { [weak self] _ in
            Log.ble.info("WHC06 advertisement timeout - device may be disconnected")
            self?.onDisconnect?()
        }
    }

    private func stopDisconnectTimer() {
        disconnectTimer?.invalidate()
        disconnectTimer = nil
    }
}
