import Foundation

/// Captures statistics for a single rep (grip session)
final class RepResult: Identifiable {
    let id = UUID()
    let timestamp: Date
    let duration: TimeInterval
    let samples: [Float]
    let targetWeight: Float?

    init(timestamp: Date, duration: TimeInterval, samples: [Float], targetWeight: Float?) {
        self.timestamp = timestamp
        self.duration = duration
        self.samples = samples
        self.targetWeight = targetWeight
    }

    // MARK: - Sample Filtering

    /// Filter result containing indices and the stable band used
    struct FilterResult {
        let startIndex: Int
        let endIndex: Int
        let bandMedian: Float
        let bandStdDev: Float
        let bandLower: Float
        let bandUpper: Float
    }

    /// Number of standard deviations for the stable band
    private static let bandMultiplier: Float = 3.0

    /// Cached filter result (calculated once on first access)
    private lazy var _filterResult: FilterResult = computeFilterResult()

    /// Cached filtered samples (calculated once on first access)
    private lazy var _filteredSamples: [Float] = computeFilteredSamples()

    /// Calculate filter bounds using middle 50% of samples to define stable band
    var filterResult: FilterResult { _filterResult }

    /// Filtered samples (holding phase only, excluding pickup and release)
    var filteredSamples: [Float] { _filteredSamples }

    private func computeFilterResult() -> FilterResult {
        guard samples.count >= 4 else {
            return FilterResult(
                startIndex: 0,
                endIndex: max(0, samples.count - 1),
                bandMedian: 0,
                bandStdDev: 0,
                bandLower: 0,
                bandUpper: 0
            )
        }

        // Take middle 50% of samples to estimate stable region
        let quarterCount = samples.count / 4
        let middleStart = quarterCount
        let middleEnd = samples.count - quarterCount
        let middleSamples = Array(samples[middleStart..<middleEnd])

        // Calculate median and std dev of middle portion
        let bandMedian = StatisticsUtilities.median(middleSamples)
        let bandStdDev = StatisticsUtilities.populationStandardDeviation(middleSamples)

        // Define stable band
        let bandLower = bandMedian - Self.bandMultiplier * bandStdDev
        let bandUpper = bandMedian + Self.bandMultiplier * bandStdDev

        // Find start: first sample that enters the band
        var startIndex = 0
        for (i, sample) in samples.enumerated() {
            if sample >= bandLower && sample <= bandUpper {
                startIndex = i
                break
            }
        }

        // Find end: last sample before permanently leaving the band (scan backwards)
        var endIndex = samples.count - 1
        for i in stride(from: samples.count - 1, through: startIndex, by: -1) {
            if samples[i] >= bandLower && samples[i] <= bandUpper {
                endIndex = i
                break
            }
        }

        return FilterResult(
            startIndex: startIndex,
            endIndex: endIndex,
            bandMedian: bandMedian,
            bandStdDev: bandStdDev,
            bandLower: bandLower,
            bandUpper: bandUpper
        )
    }

    private func computeFilteredSamples() -> [Float] {
        let filter = filterResult
        guard filter.startIndex <= filter.endIndex else { return samples }
        return Array(samples[filter.startIndex...filter.endIndex])
    }

    // MARK: - Computed Statistics (using filtered samples)

    var mean: Float {
        StatisticsUtilities.mean(filteredSamples)
    }

    var median: Float {
        StatisticsUtilities.median(filteredSamples)
    }

    /// 25th percentile (first quartile)
    var q1: Float {
        StatisticsUtilities.percentile(0.25, of: filteredSamples)
    }

    /// 75th percentile (third quartile)
    var q3: Float {
        StatisticsUtilities.percentile(0.75, of: filteredSamples)
    }

    /// Interquartile range
    var iqr: Float {
        q3 - q1
    }

    /// Standard deviation of filtered samples
    var stdDev: Float {
        StatisticsUtilities.standardDeviation(filteredSamples)
    }

    /// Absolute deviation from target weight in kg (nil if no target)
    var absoluteDeviation: Float? {
        guard let target = targetWeight else { return nil }
        return median - target
    }

    /// Deviation from target weight as percentage (nil if no target)
    /// Uses median as the measured value for comparison
    var deviationPercentage: Float? {
        guard let target = targetWeight, target > 0 else { return nil }
        return ((median - target) / target) * 100
    }

    // MARK: - Raw Statistics (for comparison in debug view)

    var rawMedian: Float {
        StatisticsUtilities.median(samples)
    }

    var rawStdDev: Float {
        StatisticsUtilities.standardDeviation(samples)
    }
}
