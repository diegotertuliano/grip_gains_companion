import Foundation

/// Captures statistics for a single rep (grip session)
final class RepResult: Identifiable {
    let id = UUID()
    let timestamp: Date
    let duration: TimeInterval
    let samples: [Double]
    let targetWeight: Double?

    init(timestamp: Date, duration: TimeInterval, samples: [Double], targetWeight: Double?) {
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
        let bandMedian: Double
        let bandStdDev: Double
        let bandLower: Double
        let bandUpper: Double
    }

    /// Number of standard deviations for the stable band
    private static let bandMultiplier: Double = 3.0

    /// Cached filter result (calculated once on first access)
    private lazy var _filterResult: FilterResult = computeFilterResult()

    /// Cached filtered samples (calculated once on first access)
    private lazy var _filteredSamples: [Double] = computeFilteredSamples()

    /// Calculate filter bounds using middle 50% of samples to define stable band
    var filterResult: FilterResult { _filterResult }

    /// Filtered samples (holding phase only, excluding pickup and release)
    var filteredSamples: [Double] { _filteredSamples }

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

    private func computeFilteredSamples() -> [Double] {
        let filter = filterResult
        guard filter.startIndex <= filter.endIndex else { return samples }
        return Array(samples[filter.startIndex...filter.endIndex])
    }

    // MARK: - Computed Statistics (using filtered samples)

    var mean: Double {
        StatisticsUtilities.mean(filteredSamples)
    }

    var median: Double {
        StatisticsUtilities.median(filteredSamples)
    }

    /// 1st percentile
    var p1: Double {
        StatisticsUtilities.percentile(0.01, of: filteredSamples)
    }

    /// 5th percentile
    var p5: Double {
        StatisticsUtilities.percentile(0.05, of: filteredSamples)
    }

    /// 10th percentile
    var p10: Double {
        StatisticsUtilities.percentile(0.10, of: filteredSamples)
    }

    /// 25th percentile (first quartile)
    var q1: Double {
        StatisticsUtilities.percentile(0.25, of: filteredSamples)
    }

    /// 75th percentile (third quartile)
    var q3: Double {
        StatisticsUtilities.percentile(0.75, of: filteredSamples)
    }

    /// 90th percentile
    var p90: Double {
        StatisticsUtilities.percentile(0.90, of: filteredSamples)
    }

    /// 95th percentile
    var p95: Double {
        StatisticsUtilities.percentile(0.95, of: filteredSamples)
    }

    /// 99th percentile
    var p99: Double {
        StatisticsUtilities.percentile(0.99, of: filteredSamples)
    }

    /// Interquartile range
    var iqr: Double {
        q3 - q1
    }

    /// Standard deviation of filtered samples
    var stdDev: Double {
        StatisticsUtilities.standardDeviation(filteredSamples)
    }

    /// Absolute deviation from target weight in kg (nil if no target)
    var absoluteDeviation: Double? {
        guard let target = targetWeight else { return nil }
        return median - target
    }

    /// Deviation from target weight as percentage (nil if no target)
    /// Uses median as the measured value for comparison
    var deviationPercentage: Double? {
        guard let target = targetWeight, target > 0 else { return nil }
        return ((median - target) / target) * 100
    }

    // MARK: - Raw Statistics (for comparison in debug view)

    var rawMedian: Double {
        StatisticsUtilities.median(samples)
    }

    var rawStdDev: Double {
        StatisticsUtilities.standardDeviation(samples)
    }
}
