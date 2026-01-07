import Foundation

/// Aggregated statistics for a complete set (multiple reps)
struct SetStatistics {
    let reps: [RepResult]

    var totalReps: Int { reps.count }

    // MARK: - Duration Statistics

    var totalDuration: TimeInterval {
        reps.reduce(0) { $0 + $1.duration }
    }

    // MARK: - Target Weight

    /// Target weight (from the first rep that has one)
    var targetWeight: Float? {
        reps.first(where: { $0.targetWeight != nil })?.targetWeight
    }

    // MARK: - Median Statistics

    /// Mean of rep medians (for calculating absolute std dev)
    var medianMean: Float? {
        let medians = reps.map(\.median)
        guard !medians.isEmpty else { return nil }
        return medians.reduce(0, +) / Float(medians.count)
    }

    /// Standard deviation of rep medians (absolute, in kg)
    var medianStdDev: Float? {
        let medians = reps.map(\.median)
        guard medians.count > 1, let mean = medianMean else { return nil }
        let variance = medians.reduce(0) { $0 + pow($1 - mean, 2) } / Float(medians.count - 1)
        return sqrt(variance)
    }

    // MARK: - Deviation from Target Statistics

    /// Mean absolute deviation from target (in kg)
    var meanAbsoluteDeviation: Float? {
        let validDeviations = reps.compactMap(\.absoluteDeviation)
        guard !validDeviations.isEmpty else { return nil }
        return validDeviations.reduce(0, +) / Float(validDeviations.count)
    }

    /// Mean deviation from target across all reps (%)
    var meanDeviation: Float? {
        let validDeviations = reps.compactMap(\.deviationPercentage)
        guard !validDeviations.isEmpty else { return nil }
        return validDeviations.reduce(0, +) / Float(validDeviations.count)
    }

    /// Whether the summary section has any meaningful data to display
    var hasSummaryData: Bool {
        meanAbsoluteDeviation != nil || medianStdDev != nil || targetWeight != nil
    }
}
