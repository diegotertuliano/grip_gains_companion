import Foundation
import SwiftData

/// Stores individual rep data including raw force samples and computed statistics
@Model
final class RepLog {
    // MARK: - Primary Key
    var id: UUID = UUID()

    // MARK: - Relationship
    var session: SessionLog?

    // MARK: - Rep Data
    var timestamp: Date = Date()
    var duration: TimeInterval = 0
    var targetWeight: Double?

    // MARK: - Raw Force Samples (stored as Data for efficiency)
    @Attribute(.externalStorage) var samplesData: Data = Data()

    // MARK: - Precomputed Statistics
    var mean: Double = 0
    var median: Double = 0
    var stdDev: Double = 0
    var p1: Double = 0
    var p5: Double = 0
    var p10: Double = 0
    var q1: Double = 0
    var q3: Double = 0
    var p90: Double = 0
    var p95: Double = 0
    var p99: Double = 0

    // MARK: - Filter Bounds
    var filterStartIndex: Int = 0
    var filterEndIndex: Int = 0

    // MARK: - Computed Properties

    /// Decode samples from Data storage
    var samples: [Double] {
        get {
            guard !samplesData.isEmpty else { return [] }
            return samplesData.withUnsafeBytes { buffer in
                Array(buffer.bindMemory(to: Double.self))
            }
        }
        set {
            samplesData = newValue.withUnsafeBytes { Data($0) }
        }
    }

    var iqr: Double {
        q3 - q1
    }

    var absoluteDeviation: Double? {
        guard let target = targetWeight else { return nil }
        return median - target
    }

    var deviationPercentage: Double? {
        guard let target = targetWeight, target > 0 else { return nil }
        return ((median - target) / target) * 100
    }

    // MARK: - Initializers

    /// Create a RepLog from an existing RepResult
    convenience init(from repResult: RepResult, session: SessionLog? = nil) {
        self.init(
            timestamp: repResult.timestamp,
            duration: repResult.duration,
            samples: repResult.samples,
            targetWeight: repResult.targetWeight,
            mean: repResult.mean,
            median: repResult.median,
            stdDev: repResult.stdDev,
            p1: repResult.p1,
            p5: repResult.p5,
            p10: repResult.p10,
            q1: repResult.q1,
            q3: repResult.q3,
            p90: repResult.p90,
            p95: repResult.p95,
            p99: repResult.p99,
            filterStartIndex: repResult.filterResult.startIndex,
            filterEndIndex: repResult.filterResult.endIndex,
            session: session
        )
    }

    init(
        timestamp: Date,
        duration: TimeInterval,
        samples: [Double],
        targetWeight: Double?,
        mean: Double,
        median: Double,
        stdDev: Double,
        p1: Double,
        p5: Double,
        p10: Double,
        q1: Double,
        q3: Double,
        p90: Double,
        p95: Double,
        p99: Double,
        filterStartIndex: Int,
        filterEndIndex: Int,
        session: SessionLog? = nil
    ) {
        self.id = UUID()
        self.timestamp = timestamp
        self.duration = duration
        self.targetWeight = targetWeight
        self.mean = mean
        self.median = median
        self.stdDev = stdDev
        self.p1 = p1
        self.p5 = p5
        self.p10 = p10
        self.q1 = q1
        self.q3 = q3
        self.p90 = p90
        self.p95 = p95
        self.p99 = p99
        self.filterStartIndex = filterStartIndex
        self.filterEndIndex = filterEndIndex
        self.session = session
        self.samplesData = samples.withUnsafeBytes { Data($0) }
    }
}
