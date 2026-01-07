import Foundation
import CoreBluetooth

/// Configuration constants ported from Python config.py
struct AppConstants {
    // MARK: - Thresholds (kg)
    static let engageThreshold: Double = 3.0
    static let failThreshold: Double = 1.0
    static let calibrationDuration: TimeInterval = 5.0

    // MARK: - Grip Detection Defaults (kg)
    static let defaultEngageThreshold: Double = 3.0
    static let defaultFailThreshold: Double = 1.0
    static let minGripThreshold: Double = 0.5
    static let maxEngageThreshold: Double = 10.0
    static let maxFailThreshold: Double = 5.0

    // MARK: - Target Weight
    static let defaultWeightTolerance: Double = 0.5  // kg
    static let minWeightTolerance: Double = 0.1      // kg
    static let maxWeightTolerance: Double = 1.0      // kg
    static let offTargetFeedbackInterval: TimeInterval = 1.0  // seconds (throttle)

    // MARK: - Percentage-Based Thresholds
    static let defaultEnablePercentageThresholds: Bool = true
    static let defaultEngagePercentage: Double = 0.50      // 50% of target weight
    static let defaultDisengagePercentage: Double = 0.20   // 20% of target weight
    static let defaultTolerancePercentage: Double = 0.05   // 5% of target weight
    static let minPercentage: Double = 0.05                // 5% minimum
    static let maxEngagePercentage: Double = 0.90          // 90% maximum for engage
    static let maxDisengagePercentage: Double = 0.50       // 50% maximum for disengage

    // MARK: - Percentage Threshold Bounds (kg)
    // Floor = minimum absolute value (0 = disabled, use pure percentage)
    // Ceiling = maximum absolute value (0 = disabled, use pure percentage)
    static let defaultEngageFloor: Double = 3.0
    static let defaultEngageCeiling: Double = 0.0
    static let defaultDisengageFloor: Double = 2.0
    static let defaultDisengageCeiling: Double = 0.0
    static let defaultToleranceFloor: Double = 0.3
    static let defaultToleranceCeiling: Double = 1.5

    // MARK: - Weight Calibration
    /// Fixed threshold for weight calibration mode (separate from grip engage threshold)
    static let defaultWeightCalibrationThreshold: Double = 3.0  // kg

    // MARK: - UI Defaults
    static let defaultEnableHaptics: Bool = true
    static let defaultEnableTargetSound: Bool = true
    static let defaultShowGripStats: Bool = true
    static let defaultShowSetReview: Bool = false
    static let defaultShowStatusBar: Bool = true
    static let defaultExpandedForceBar: Bool = true
    static let defaultShowForceGraph: Bool = true
    static let defaultForceGraphWindow: Int = 5
    static let defaultFullScreen: Bool = true
    static let defaultEnableTargetWeight: Bool = true
    static let defaultUseManualTarget: Bool = false
    static let defaultManualTargetWeight: Double = 20.0
    static let defaultEnableCalibration: Bool = true
    static let defaultBackgroundTimeSync: Bool = true
    static let defaultEnableLiveActivity: Bool = true
    static let defaultAutoSelectWeight: Bool = true
    static let defaultAutoSelectFromManual: Bool = false
    static let defaultUseKeyboardInput: Bool = false

    // MARK: - Web
    static let gripGainsURL = URL(string: "https://gripgains.ca/timer")!

    // MARK: - Tindeq Progressor BLE UUIDs
    static let progressorServiceUUID = CBUUID(string: "7E4E1701-1EA6-40C9-9DCC-13D34FFEAD57")
    static let notifyCharacteristicUUID = CBUUID(string: "7E4E1702-1EA6-40C9-9DCC-13D34FFEAD57")
    static let writeCharacteristicUUID = CBUUID(string: "7E4E1703-1EA6-40C9-9DCC-13D34FFEAD57")

    // MARK: - BLE Commands
    static let startWeightCommand = Data([101])

    // MARK: - Data Format
    /// Each sample: 4-byte float (weight) + 4-byte uint32 (microseconds)
    static let sampleSize = 8

    // MARK: - Timing
    static let sessionRefreshInterval: TimeInterval = 2.0
    static let bleReconnectDelay: TimeInterval = 3.0
    static let discoveryTimeout: TimeInterval = 30.0
    static let maxRetryDelay: TimeInterval = 30.0
    static let backgroundInactivityTimeout: TimeInterval = 300  // 5 minutes

    // MARK: - File Paths
    static let csvFileName = "grip_log.csv"

    // MARK: - Unit Conversion
    static let kgToLbs: Double = 2.20462
}

// MARK: - RSSI Signal Thresholds
enum SignalThreshold {
    static let excellent: Int = -50
    static let good: Int = -60
    static let fair: Int = -70
    static let weak: Int = -90
}

// MARK: - Progressor BLE Protocol
enum ProgressorProtocol {
    static let weightDataPacketType: UInt8 = 1
    static let packetMinSize: Int = 6
    static let floatDataStart: Int = 2
    static let floatDataEnd: Int = 6
}

// MARK: - BLE Errors
enum BLEError: Error, LocalizedError {
    case bluetoothNotAvailable
    case bluetoothOff
    case bluetoothUnauthorized
    case deviceNotFound
    case connectionFailed(String)
    case discoveryTimeout
    case characteristicNotAvailable
    case parseError(ParseError)

    var errorDescription: String? {
        switch self {
        case .bluetoothNotAvailable: return "Bluetooth not available"
        case .bluetoothOff: return "Bluetooth is off"
        case .bluetoothUnauthorized: return "Bluetooth unauthorized"
        case .deviceNotFound: return "Device not found"
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .discoveryTimeout: return "Service discovery timed out"
        case .characteristicNotAvailable: return "Characteristic not available"
        case .parseError(let error): return error.errorDescription
        }
    }
}

// MARK: - Parse Errors
enum ParseError: Error, LocalizedError {
    case insufficientData(Int)
    case invalidPacketType(UInt8)
    case invalidValue(Float)

    var errorDescription: String? {
        switch self {
        case .insufficientData(let count):
            return "Data too short: \(count) bytes, need \(ProgressorProtocol.packetMinSize)"
        case .invalidPacketType(let type):
            return "Invalid packet type: \(type), expected \(ProgressorProtocol.weightDataPacketType)"
        case .invalidValue(let value):
            return "Invalid weight value: \(value)"
        }
    }
}
