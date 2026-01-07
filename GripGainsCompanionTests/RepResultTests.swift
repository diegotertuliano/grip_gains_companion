import XCTest
@testable import GripGainsCompanion

final class RepResultTests: XCTestCase {

    // MARK: - filterResult Edge Cases

    func testFilterResultWithFewerThan4Samples() {
        let rep = RepResult(
            timestamp: Date(),
            duration: 1.0,
            samples: [10.0, 11.0, 12.0],
            targetWeight: nil
        )

        let filter = rep.filterResult
        XCTAssertEqual(filter.startIndex, 0)
        XCTAssertEqual(filter.endIndex, 2)
        XCTAssertEqual(filter.bandMedian, 0)
        XCTAssertEqual(filter.bandStdDev, 0)
    }

    func testFilterResultWithEmptySamples() {
        let rep = RepResult(
            timestamp: Date(),
            duration: 0,
            samples: [],
            targetWeight: nil
        )

        let filter = rep.filterResult
        XCTAssertEqual(filter.startIndex, 0)
        XCTAssertEqual(filter.endIndex, 0)
    }

    // MARK: - filterResult Normal Cases

    func testFilterResultWithStableSamples() {
        // Stable samples in the middle, transients at start/end
        // Start: pickup phase (low values)
        // Middle: stable holding (~20kg)
        // End: release phase (dropping values)
        let samples: [Float] = [
            5.0, 10.0, 15.0,           // pickup (indices 0-2)
            20.0, 20.1, 19.9, 20.0, 20.2, 19.8, 20.0, 20.1,  // stable (indices 3-10)
            15.0, 10.0, 5.0            // release (indices 11-13)
        ]

        let rep = RepResult(
            timestamp: Date(),
            duration: 7.0,
            samples: samples,
            targetWeight: 20.0
        )

        let filter = rep.filterResult

        // Middle 50% is indices 3-10 (samples[3..<11])
        // Band should be around 20.0 with small stdDev
        XCTAssertEqual(filter.bandMedian, 20.0, accuracy: 0.2)
        XCTAssertLessThan(filter.bandStdDev, 1.0)

        // Start index should skip the pickup phase
        XCTAssertGreaterThanOrEqual(filter.startIndex, 3)

        // End index should exclude the release phase
        XCTAssertLessThanOrEqual(filter.endIndex, 10)
    }

    // MARK: - filteredSamples

    func testFilteredSamplesMatchesFilterIndices() {
        let samples: [Float] = [5, 10, 20, 20, 20, 20, 10, 5]
        let rep = RepResult(
            timestamp: Date(),
            duration: 4.0,
            samples: samples,
            targetWeight: 20.0
        )

        let filter = rep.filterResult
        let filtered = rep.filteredSamples

        // Verify filtered samples are the correct slice
        let expectedSlice = Array(samples[filter.startIndex...filter.endIndex])
        XCTAssertEqual(filtered, expectedSlice)
    }

    // MARK: - Computed Statistics

    func testComputedStatsUseFilteredSamples() {
        // Create samples where raw and filtered would give different results
        // Need enough samples so middle 50% is truly stable (at least 20 samples)
        var samples: [Float] = []
        samples.append(contentsOf: Array(repeating: 0.0, count: 5))   // pickup noise
        samples.append(contentsOf: Array(repeating: 10.0, count: 20)) // stable region
        samples.append(contentsOf: Array(repeating: 0.0, count: 5))   // release noise

        let rep = RepResult(
            timestamp: Date(),
            duration: 5.0,
            samples: samples,
            targetWeight: 10.0
        )

        // Middle 50% of 30 samples = indices 7-22, which is all 10s
        // Band should be centered around 10 with very small stdDev
        // So filtered samples should be the stable 10s region
        // Median of filtered should be ~10
        XCTAssertEqual(rep.median, 10.0, accuracy: 0.1)

        // Raw median of 30 samples (5 zeros, 20 tens, 5 zeros) = sorted middle = 10
        // Actually both will be 10 in this case, let me verify the filtering works differently
        // The key is that rawStdDev > stdDev because raw includes the transition
        XCTAssertLessThan(rep.stdDev, rep.rawStdDev)
    }

    func testMeanCalculation() {
        let samples: [Float] = Array(repeating: 15.0, count: 20)
        let rep = RepResult(
            timestamp: Date(),
            duration: 5.0,
            samples: samples,
            targetWeight: nil
        )

        XCTAssertEqual(rep.mean, 15.0, accuracy: 0.001)
    }

    func testStdDevCalculation() {
        // All identical values -> stdDev = 0
        let samples: [Float] = Array(repeating: 20.0, count: 20)
        let rep = RepResult(
            timestamp: Date(),
            duration: 5.0,
            samples: samples,
            targetWeight: nil
        )

        XCTAssertEqual(rep.stdDev, 0.0, accuracy: 0.001)
    }

    // MARK: - Deviation Calculations

    func testAbsoluteDeviationWithTarget() {
        let samples: [Float] = Array(repeating: 20.5, count: 20)
        let rep = RepResult(
            timestamp: Date(),
            duration: 5.0,
            samples: samples,
            targetWeight: 20.0
        )

        XCTAssertEqual(rep.absoluteDeviation!, 0.5, accuracy: 0.001)
    }

    func testAbsoluteDeviationWithoutTarget() {
        let samples: [Float] = Array(repeating: 20.0, count: 20)
        let rep = RepResult(
            timestamp: Date(),
            duration: 5.0,
            samples: samples,
            targetWeight: nil
        )

        XCTAssertNil(rep.absoluteDeviation)
    }

    func testDeviationPercentageWithTarget() {
        let samples: [Float] = Array(repeating: 22.0, count: 20)
        let rep = RepResult(
            timestamp: Date(),
            duration: 5.0,
            samples: samples,
            targetWeight: 20.0
        )

        // (22 - 20) / 20 * 100 = 10%
        XCTAssertEqual(rep.deviationPercentage!, 10.0, accuracy: 0.001)
    }

    func testDeviationPercentageNegative() {
        let samples: [Float] = Array(repeating: 18.0, count: 20)
        let rep = RepResult(
            timestamp: Date(),
            duration: 5.0,
            samples: samples,
            targetWeight: 20.0
        )

        // (18 - 20) / 20 * 100 = -10%
        XCTAssertEqual(rep.deviationPercentage!, -10.0, accuracy: 0.001)
    }

    func testDeviationPercentageWithoutTarget() {
        let samples: [Float] = Array(repeating: 20.0, count: 20)
        let rep = RepResult(
            timestamp: Date(),
            duration: 5.0,
            samples: samples,
            targetWeight: nil
        )

        XCTAssertNil(rep.deviationPercentage)
    }

    func testDeviationPercentageWithZeroTarget() {
        let samples: [Float] = Array(repeating: 20.0, count: 20)
        let rep = RepResult(
            timestamp: Date(),
            duration: 5.0,
            samples: samples,
            targetWeight: 0.0
        )

        // Should return nil to avoid division by zero
        XCTAssertNil(rep.deviationPercentage)
    }

    // MARK: - Quartiles

    func testQuartileCalculations() {
        // Create predictable samples
        let samples: [Float] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20]
        let rep = RepResult(
            timestamp: Date(),
            duration: 10.0,
            samples: samples,
            targetWeight: nil
        )

        // These will use filtered samples, so values depend on filtering
        // Just verify IQR = Q3 - Q1
        XCTAssertEqual(rep.iqr, rep.q3 - rep.q1, accuracy: 0.001)
    }
}
