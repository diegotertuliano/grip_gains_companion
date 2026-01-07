import Foundation

/// Shared statistics utility functions for calculating mean, median, std dev, etc.
enum StatisticsUtilities {
    /// Calculate the arithmetic mean of a collection of values
    static func mean(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Float(values.count)
    }

    /// Calculate the median (middle value) of a collection
    static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2
        } else {
            return sorted[mid]
        }
    }

    /// Calculate the sample standard deviation (using n-1 denominator)
    static func standardDeviation(_ values: [Float]) -> Float {
        guard values.count > 1 else { return 0 }
        let avg = mean(values)
        let variance = values.reduce(0) { $0 + pow($1 - avg, 2) } / Float(values.count - 1)
        return sqrt(variance)
    }

    /// Calculate the population standard deviation (using n denominator)
    static func populationStandardDeviation(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let avg = mean(values)
        let variance = values.reduce(0) { $0 + pow($1 - avg, 2) } / Float(values.count)
        return sqrt(variance)
    }

    /// Calculate percentile using linear interpolation
    static func percentile(_ p: Float, of values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let count = Float(sorted.count)

        let index = p * (count - 1)
        let lower = Int(index)
        let upper = min(lower + 1, sorted.count - 1)
        let fraction = index - Float(lower)

        return sorted[lower] + fraction * (sorted[upper] - sorted[lower])
    }

    /// Calculate median after trimming a fraction of samples from start and end.
    /// Used to exclude transient pickup/release phases for more accurate weight detection.
    static func trimmedMedian(_ values: [Float], trimFraction: Float = 0.3) -> Float {
        guard values.count >= 5 else { return median(values) }

        let trimCount = Int(Float(values.count) * trimFraction)
        let startIndex = trimCount
        let endIndex = values.count - trimCount

        guard startIndex < endIndex else { return median(values) }

        let trimmedValues = Array(values[startIndex..<endIndex])
        return median(trimmedValues)
    }
}
