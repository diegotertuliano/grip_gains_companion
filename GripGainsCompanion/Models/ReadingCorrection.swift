import Foundation

/// Applied to protocol-decoded kilograms, before display, detection, or recording.
struct ReadingCorrection: Codable, Equatable {
    var multiplier: Double = 1
    var offsetKg: Double = 0

    static let identity = ReadingCorrection()

    var isValid: Bool {
        multiplier.isFinite && multiplier > 0 && offsetKg.isFinite
    }

    var isActive: Bool { self != .identity }

    func apply(to reportedKg: Double) -> Double? {
        guard isValid, reportedKg.isFinite else { return nil }
        let corrected = reportedKg * multiplier + offsetKg
        return corrected.isFinite ? corrected : nil
    }

    var multiplierText: String { Self.inputText(multiplier) }

    func offsetText(useLbs: Bool) -> String {
        Self.inputText(useLbs ? offsetKg * AppConstants.kgToLbs : offsetKg)
    }

    /// Accept either decimal separator, without interpreting grouping separators.
    static func parse(multiplier: String, offset: String, useLbs: Bool) -> ReadingCorrection? {
        func number(_ text: String) -> Double? {
            Double(text.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: ",", with: "."))
        }
        guard let factor = number(multiplier), let displayedOffset = number(offset) else { return nil }
        let correction = ReadingCorrection(
            multiplier: factor,
            offsetKg: useLbs ? displayedOffset / AppConstants.kgToLbs : displayedOffset
        )
        return correction.isValid ? correction : nil
    }

    private static func inputText(_ value: Double) -> String {
        let text = String(value)
        let compact = text.hasSuffix(".0") ? String(text.dropLast(2)) : text
        return compact.replacingOccurrences(of: ".", with: Locale.current.decimalSeparator ?? ".")
    }
}

struct ReadingCorrectionDevice: Equatable, Identifiable {
    let peripheralID: UUID
    let type: DeviceType

    var id: String { "\(type.rawValue).\(peripheralID.uuidString)" }
}
