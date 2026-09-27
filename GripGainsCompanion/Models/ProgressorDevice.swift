import Foundation
import CoreBluetooth

// MARK: - Device Type

/// Supported force measurement device types
enum DeviceType: String, CaseIterable, Codable {
    case tindeqProgressor
    case pitchSixForceBoard
    case jinlianCTS500
    case weihengWHC06
    case frezDyno

    var displayName: String {
        switch self {
        case .tindeqProgressor: return "Tindeq Progressor"
        case .pitchSixForceBoard: return "PitchSix Force Board"
        case .jinlianCTS500: return "Jinlian CTS500"
        case .weihengWHC06: return "Weiheng WH-C06"
        case .frezDyno: return "Frez Dyno"
        }
    }

    var shortName: String {
        switch self {
        case .tindeqProgressor: return "Tindeq"
        case .pitchSixForceBoard: return "PitchSix"
        case .jinlianCTS500: return "CTS500"
        case .weihengWHC06: return "WH-C06"
        case .frezDyno: return "Frez Dyno"
        }
    }

    /// Whether this device uses GATT connection (vs advertisement-only)
    var usesGATTConnection: Bool {
        switch self {
        case .tindeqProgressor, .pitchSixForceBoard, .jinlianCTS500, .frezDyno: return true
        case .weihengWHC06: return false
        }
    }

    /// Detect device type from advertisement data
    static func detect(name: String?, advertisementData: [String: Any]) -> DeviceType? {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let names = [name, advertisedName].compactMap { $0 }

        if names.contains(where: { $0.hasPrefix("FrezDyno-") }) {
            return .frezDyno
        }

        // Tindeq: name starts with "Progressor"
        if names.contains(where: { $0.hasPrefix("Progressor") }) {
            return .tindeqProgressor
        }

        // PitchSix: name contains "Force Board" or "PitchSix" or "Forceboard"
        if names.contains(where: {
            $0.contains("Force Board") || $0.contains("PitchSix") || $0.contains("Forceboard")
        }) {
            return .pitchSixForceBoard
        }

        // Jinlian/Jlyscales CTS500: known firmware names
        if names.contains(where: { $0.caseInsensitiveCompare("CTS-300") == .orderedSame ||
            $0.caseInsensitiveCompare("CTS500") == .orderedSame }) {
            return .jinlianCTS500
        }

        // WHC06: manufacturer ID 0x0100
        if let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
           manufacturerData.count >= 2 {
            let manufacturerId = UInt16(manufacturerData[0]) | (UInt16(manufacturerData[1]) << 8)
            if manufacturerId == AppConstants.whc06ManufacturerId {
                return .weihengWHC06
            }
        }

        return nil
    }
}

// MARK: - Force Device

/// A discovered force measurement device
struct ForceDevice: Identifiable, Equatable {
    let id: UUID
    let name: String
    let peripheralIdentifier: UUID
    let type: DeviceType
    var rssi: Int

    init(peripheral: CBPeripheral, type: DeviceType, rssi: Int = 0) {
        self.id = peripheral.identifier
        self.name = peripheral.name ?? type.displayName
        self.peripheralIdentifier = peripheral.identifier
        self.type = type
        self.rssi = rssi
    }

    /// Initialize from advertisement data (for WHC06 which doesn't connect)
    init(id: UUID, name: String, type: DeviceType, rssi: Int = 0) {
        self.id = id
        self.name = name
        self.peripheralIdentifier = id
        self.type = type
        self.rssi = rssi
    }

    var signalStrength: String {
        if rssi > SignalThreshold.excellent { return "Excellent" }
        if rssi > SignalThreshold.good { return "Good" }
        if rssi > SignalThreshold.fair { return "Fair" }
        return "Weak"
    }

    var signalBars: Int {
        if rssi > SignalThreshold.excellent { return 4 }
        if rssi > SignalThreshold.good { return 3 }
        if rssi > SignalThreshold.fair { return 2 }
        return 1
    }
}
