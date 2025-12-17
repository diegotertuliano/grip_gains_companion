import SwiftUI

/// Bundles all state needed for the status bar display
struct StatusBarState {
    let force: Float
    let engaged: Bool
    let calibrating: Bool
    let waitingForSamples: Bool
    let calibrationTimeRemaining: TimeInterval
    let weightMedian: Float?

    // Target weight state
    let targetWeight: Float?
    let isOffTarget: Bool
    let offTargetDirection: Float?  // positive = too heavy, negative = too light

    /// Show weight only when idle (not gripping, calibrating, or connecting)
    var showWeight: Bool {
        weightMedian != nil && !engaged && !calibrating && !waitingForSamples
    }

    var stateText: String {
        if waitingForSamples { return "CONNECTING" }
        if calibrating { return "CALIBRATING \(Int(ceil(calibrationTimeRemaining)))s" }
        if engaged { return "GRIPPING" }
        return "IDLE"
    }

    var stateColor: Color {
        if waitingForSamples { return .orange }
        if calibrating { return .gray }
        if engaged { return .green }
        return .blue
    }

    func forceColor(baseline: Float = 0, isDarkMode: Bool = true) -> Color {
        if waitingForSamples || calibrating { return .gray }
        if engaged {
            // Show red/orange if off target during gripping
            if isOffTarget { return .red }
            return .green
        }
        if force - baseline >= AppConstants.engageThreshold { return .orange }
        return isDarkMode ? .white : .primary
    }

    /// Color for weight display when off target
    var weightDisplayColor: Color {
        if engaged && isOffTarget {
            return .red
        }
        return .secondary
    }

    /// Formatted difference from target weight (e.g., "+0.5" or "-0.3")
    func formattedDifference(useLbs: Bool) -> String? {
        guard let direction = offTargetDirection else { return nil }
        let value = useLbs ? direction * AppConstants.kgToLbs : direction
        let sign = value >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.1f", value))"
    }
}
