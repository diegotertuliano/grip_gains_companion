import Foundation

/// Local hardware compatibility settings; independent of general app preferences.
final class ReadingCorrectionStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func correction(for device: ReadingCorrectionDevice) -> ReadingCorrection {
        guard let data = defaults.data(forKey: key(for: device)),
              let correction = try? JSONDecoder().decode(ReadingCorrection.self, from: data),
              correction.isValid else { return .identity }
        return correction
    }

    @discardableResult
    func save(_ correction: ReadingCorrection, for device: ReadingCorrectionDevice) -> Bool {
        guard correction.isValid else { return false }
        if correction == .identity {
            defaults.removeObject(forKey: key(for: device))
        } else {
            guard let data = try? JSONEncoder().encode(correction) else { return false }
            defaults.set(data, forKey: key(for: device))
        }
        return true
    }

    private func key(for device: ReadingCorrectionDevice) -> String {
        "deviceReadingCorrection.v1.\(device.id)"
    }
}
