import XCTest
@testable import GripGainsCompanion

final class StatisticsUtilitiesTests: XCTestCase {

    // MARK: - mean() Tests

    func testMeanEmptyArray() {
        XCTAssertEqual(StatisticsUtilities.mean([]), 0)
    }

    func testMeanSingleValue() {
        XCTAssertEqual(StatisticsUtilities.mean([5.0]), 5.0)
    }

    func testMeanMultipleValues() {
        XCTAssertEqual(StatisticsUtilities.mean([1.0, 2.0, 3.0, 4.0, 5.0]), 3.0)
    }

    func testMeanWithNegatives() {
        XCTAssertEqual(StatisticsUtilities.mean([-2.0, 0.0, 2.0]), 0.0)
    }

    // MARK: - median() Tests

    func testMedianEmptyArray() {
        XCTAssertEqual(StatisticsUtilities.median([]), 0)
    }

    func testMedianSingleValue() {
        XCTAssertEqual(StatisticsUtilities.median([7.0]), 7.0)
    }

    func testMedianOddCount() {
        // Sorted: [1, 2, 3, 4, 5] -> middle is 3
        XCTAssertEqual(StatisticsUtilities.median([3.0, 1.0, 5.0, 2.0, 4.0]), 3.0)
    }

    func testMedianEvenCount() {
        // Sorted: [1, 2, 3, 4] -> average of 2 and 3 = 2.5
        XCTAssertEqual(StatisticsUtilities.median([4.0, 1.0, 2.0, 3.0]), 2.5)
    }

    // MARK: - standardDeviation() Tests (sample, n-1)

    func testStandardDeviationEmptyArray() {
        XCTAssertEqual(StatisticsUtilities.standardDeviation([]), 0)
    }

    func testStandardDeviationSingleValue() {
        // n-1 would be 0, so returns 0
        XCTAssertEqual(StatisticsUtilities.standardDeviation([5.0]), 0)
    }

    func testStandardDeviationMultipleValues() {
        // [2, 4, 4, 4, 5, 5, 7, 9] mean = 5
        // variance = sum((x-5)^2) / (8-1) = (9+1+1+1+0+0+4+16) / 7 = 32/7 ≈ 4.571
        // stdDev ≈ 2.138
        let values: [Float] = [2, 4, 4, 4, 5, 5, 7, 9]
        let result = StatisticsUtilities.standardDeviation(values)
        XCTAssertEqual(result, 2.138, accuracy: 0.001)
    }

    func testStandardDeviationIdenticalValues() {
        // All same values -> stdDev = 0
        XCTAssertEqual(StatisticsUtilities.standardDeviation([5.0, 5.0, 5.0]), 0)
    }

    // MARK: - populationStandardDeviation() Tests (n denominator)

    func testPopulationStandardDeviationEmptyArray() {
        XCTAssertEqual(StatisticsUtilities.populationStandardDeviation([]), 0)
    }

    func testPopulationStandardDeviationSingleValue() {
        // Single value has 0 variance
        XCTAssertEqual(StatisticsUtilities.populationStandardDeviation([5.0]), 0)
    }

    func testPopulationStandardDeviationMultipleValues() {
        // [2, 4, 4, 4, 5, 5, 7, 9] mean = 5
        // variance = sum((x-5)^2) / 8 = 32/8 = 4
        // stdDev = 2.0
        let values: [Float] = [2, 4, 4, 4, 5, 5, 7, 9]
        let result = StatisticsUtilities.populationStandardDeviation(values)
        XCTAssertEqual(result, 2.0, accuracy: 0.001)
    }

    func testPopulationVsSampleStandardDeviation() {
        // Population should be smaller than sample for same data
        let values: [Float] = [1, 2, 3, 4, 5]
        let pop = StatisticsUtilities.populationStandardDeviation(values)
        let sample = StatisticsUtilities.standardDeviation(values)
        XCTAssertLessThan(pop, sample)
    }

    // MARK: - percentile() Tests

    func testPercentileEmptyArray() {
        XCTAssertEqual(StatisticsUtilities.percentile(0.5, of: []), 0)
    }

    func testPercentile0th() {
        XCTAssertEqual(StatisticsUtilities.percentile(0, of: [1, 2, 3, 4, 5]), 1)
    }

    func testPercentile100th() {
        XCTAssertEqual(StatisticsUtilities.percentile(1.0, of: [1, 2, 3, 4, 5]), 5)
    }

    func testPercentile50th() {
        // 50th percentile of [1,2,3,4,5]: index = 0.5 * 4 = 2 -> value = 3
        XCTAssertEqual(StatisticsUtilities.percentile(0.5, of: [1, 2, 3, 4, 5]), 3)
    }

    func testPercentile25th() {
        // 25th percentile of [1,2,3,4,5]: index = 0.25 * 4 = 1 -> value = 2
        XCTAssertEqual(StatisticsUtilities.percentile(0.25, of: [1, 2, 3, 4, 5]), 2)
    }

    func testPercentileInterpolation() {
        // 30th percentile of [1,2,3,4,5]: index = 0.3 * 4 = 1.2
        // lower = 1, upper = 2, fraction = 0.2
        // result = values[1] + 0.2 * (values[2] - values[1]) = 2 + 0.2 * 1 = 2.2
        XCTAssertEqual(StatisticsUtilities.percentile(0.3, of: [1, 2, 3, 4, 5]), 2.2, accuracy: 0.001)
    }

    // MARK: - trimmedMedian() Tests

    func testTrimmedMedianFewSamples() {
        // Less than 5 samples falls back to regular median
        XCTAssertEqual(StatisticsUtilities.trimmedMedian([1, 2, 3, 4]), 2.5)
    }

    func testTrimmedMedianNormalTrim() {
        // 10 samples, trim 30% = 3 from each end
        // Original: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
        // Trimmed: [3, 4, 5, 6] (indices 3..<7)
        // Median of [3, 4, 5, 6] = 4.5
        let values: [Float] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
        XCTAssertEqual(StatisticsUtilities.trimmedMedian(values), 4.5)
    }

    func testTrimmedMedianCustomFraction() {
        // 10 samples, trim 10% = 1 from each end
        // Original: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
        // Trimmed: [1, 2, 3, 4, 5, 6, 7, 8] (indices 1..<9)
        // Median of [1,2,3,4,5,6,7,8] = 4.5
        let values: [Float] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
        XCTAssertEqual(StatisticsUtilities.trimmedMedian(values, trimFraction: 0.1), 4.5)
    }
}
