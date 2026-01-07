import XCTest
@testable import GripGainsCompanion

final class SetStatisticsTests: XCTestCase {

    // MARK: - hasSummaryData

    func testHasSummaryDataWithTarget() {
        let stats = SetStatistics(reps: [
            RepResult(timestamp: Date(), duration: 7.0, samples: Array(repeating: 20.0, count: 70), targetWeight: 20.0)
        ])

        XCTAssertTrue(stats.hasSummaryData)
    }

    func testHasSummaryDataWithoutTarget() {
        let stats = SetStatistics(reps: [
            RepResult(timestamp: Date(), duration: 7.0, samples: Array(repeating: 20.0, count: 70), targetWeight: nil)
        ])

        // No target, single rep (no std dev) → no summary data
        XCTAssertFalse(stats.hasSummaryData)
    }

    func testHasSummaryDataWithMultipleRepsNoTarget() {
        let stats = SetStatistics(reps: [
            RepResult(timestamp: Date(), duration: 7.0, samples: Array(repeating: 20.0, count: 70), targetWeight: nil),
            RepResult(timestamp: Date(), duration: 6.5, samples: Array(repeating: 19.5, count: 65), targetWeight: nil)
        ])

        // Multiple reps → has std dev → has summary data
        XCTAssertTrue(stats.hasSummaryData)
    }

    // MARK: - meanAbsoluteDeviation

    func testMeanAbsoluteDeviationAveragesIndividualDeviations() {
        // Rep 1: median ~11.9, deviation = -0.1
        // Rep 2: median ~12.1, deviation = +0.1
        // Average should be 0.0, not calculated from mean of medians
        let stats = SetStatistics(reps: [
            RepResult(timestamp: Date(), duration: 7.0, samples: Array(repeating: 11.9, count: 70), targetWeight: 12.0),
            RepResult(timestamp: Date(), duration: 6.5, samples: Array(repeating: 12.1, count: 65), targetWeight: 12.0)
        ])

        XCTAssertNotNil(stats.meanAbsoluteDeviation)
        // (-0.1 + 0.1) / 2 = 0.0
        XCTAssertEqual(stats.meanAbsoluteDeviation!, 0.0, accuracy: 0.01)
    }

    func testMeanAbsoluteDeviationWithAsymmetricValues() {
        // Rep 1: median 11.9, deviation = -0.1
        // Rep 2: median 12.0, deviation = 0.0
        // Average should be -0.05
        let stats = SetStatistics(reps: [
            RepResult(timestamp: Date(), duration: 7.0, samples: Array(repeating: 11.9, count: 70), targetWeight: 12.0),
            RepResult(timestamp: Date(), duration: 6.5, samples: Array(repeating: 12.0, count: 65), targetWeight: 12.0)
        ])

        XCTAssertNotNil(stats.meanAbsoluteDeviation)
        // (-0.1 + 0.0) / 2 = -0.05
        XCTAssertEqual(stats.meanAbsoluteDeviation!, -0.05, accuracy: 0.01)
    }

    func testMeanAbsoluteDeviationNilWithoutTarget() {
        let stats = SetStatistics(reps: [
            RepResult(timestamp: Date(), duration: 7.0, samples: Array(repeating: 20.0, count: 70), targetWeight: nil)
        ])

        XCTAssertNil(stats.meanAbsoluteDeviation)
    }
}
