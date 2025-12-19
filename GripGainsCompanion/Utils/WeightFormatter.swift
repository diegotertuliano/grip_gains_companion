import Foundation

enum WeightFormatter {
    static func format(_ kg: Float, useLbs: Bool, includeUnit: Bool = true, decimals: Int = 1) -> String {
        var displayValue = useLbs ? kg * AppConstants.kgToLbs : kg
        if displayValue > -0.1 && displayValue < 0.0 {
            displayValue = 0.0
        }
        let valueStr = String(format: "%.\(decimals)f", displayValue)
        if includeUnit {
            return "\(valueStr) \(useLbs ? "lbs" : "kg")"
        }
        return valueStr
    }

    static var unitLabel: (Bool) -> String = { useLbs in
        useLbs ? "lbs" : "kg"
    }
}
