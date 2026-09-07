import Foundation

/// Sample-driven feedback, independent of rep engagement and recording.
struct PreparationFeedback {
    private(set) var loaded = false
    private var lastFeedbackTime: TimeInterval?
    private var lastSampleTime: TimeInterval?

    mutating func reset() {
        loaded = false
        lastFeedbackTime = nil
        lastSampleTime = nil
    }

    mutating func update(rawWeight: Double, baseline: Double, target: Double?,
                         engageThreshold: Double, releaseThreshold: Double,
                         tolerance: Double, eligible: Bool,
                         now: TimeInterval) -> Double? {
        guard eligible, let target, target.isFinite, target > 0,
              rawWeight.isFinite else {
            reset()
            return nil
        }
        // A stream interruption must not carry a previous hold into a new one.
        if let lastSampleTime, now - lastSampleTime > 1.0 { reset() }
        lastSampleTime = now
        let force = rawWeight - baseline
        if force <= 0 || force < releaseThreshold {
            loaded = false
        } else if force >= engageThreshold {
            loaded = true
        }
        let difference = rawWeight - target
        guard loaded, abs(difference) >= tolerance else {
            lastFeedbackTime = nil
            return nil
        }
        guard lastFeedbackTime.map({ now - $0 >= 0.5 }) ?? true else { return nil }
        lastFeedbackTime = now
        return difference
    }
}
