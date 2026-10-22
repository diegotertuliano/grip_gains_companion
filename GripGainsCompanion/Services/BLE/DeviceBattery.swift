import Foundation

/// Converts device-reported battery data into a 0–100 percentage.
enum DeviceBattery {
    /// Parse a Tindeq Progressor GET_BATTERY_VOLTAGE response:
    /// tag 0x00, length 4, then uint32 little-endian millivolts.
    static func progressorMillivolts(fromResponse data: Data) -> UInt32? {
        guard data.count >= 6,
              data[data.startIndex] == ProgressorProtocol.commandResponsePacketType,
              data[data.startIndex + 1] == 4 else {
            return nil
        }
        let start = data.startIndex + 2
        return data[start..<(start + 4)].withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
    }

    /// Resting single-cell Li-ion discharge curve (millivolts, percent), highest first.
    private static let lithiumCurve: [(mv: Double, percent: Double)] = [
        (4200, 100), (4100, 90), (4000, 80), (3920, 70), (3870, 60), (3820, 50),
        (3790, 40), (3770, 30), (3740, 20), (3680, 10), (3450, 5), (3300, 0)
    ]

    /// Approximate state of charge from a single-cell Li-ion voltage.
    /// Voltage sags under load, so this is an estimate rather than a fuel-gauge reading.
    static func percent(fromLithiumMillivolts millivolts: UInt32) -> Int {
        let mv = Double(millivolts)
        for (upper, lower) in zip(lithiumCurve, lithiumCurve.dropFirst()) {
            if mv >= upper.mv { return Int(upper.percent) }
            if mv >= lower.mv {
                let fraction = (mv - lower.mv) / (upper.mv - lower.mv)
                return Int((lower.percent + fraction * (upper.percent - lower.percent)).rounded())
            }
        }
        return 0
    }
}
