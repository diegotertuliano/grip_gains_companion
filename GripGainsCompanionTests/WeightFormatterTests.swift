import XCTest
@testable import GripGainsCompanion

final class WeightFormatterTests: XCTestCase {

    // MARK: - format() Tests

    func testFormatKgWithUnit() {
        let result = WeightFormatter.format(10.5, useLbs: false, includeUnit: true)
        XCTAssertEqual(result, "10.5 kg")
    }

    func testFormatLbsWithUnit() {
        // 10.0 kg * 2.20462 = 22.0462, rounds to 22.0
        let result = WeightFormatter.format(10.0, useLbs: true, includeUnit: true)
        XCTAssertEqual(result, "22.0 lbs")
    }

    func testFormatWithoutUnit() {
        let result = WeightFormatter.format(10.0, useLbs: false, includeUnit: false)
        XCTAssertEqual(result, "10.0")
    }

    func testFormatLbsWithoutUnit() {
        let result = WeightFormatter.format(10.0, useLbs: true, includeUnit: false)
        XCTAssertEqual(result, "22.0")
    }

    func testSmallNegativeRoundsToZero() {
        // Values between -0.1 and 0 should round to 0.0
        let result = WeightFormatter.format(-0.05, useLbs: false, includeUnit: true)
        XCTAssertEqual(result, "0.0 kg")
    }

    func testNegativeOutsideThresholdStaysNegative() {
        // Values <= -0.1 should remain negative
        let result = WeightFormatter.format(-0.2, useLbs: false, includeUnit: true)
        XCTAssertEqual(result, "-0.2 kg")
    }

    func testZeroValue() {
        let result = WeightFormatter.format(0.0, useLbs: false, includeUnit: true)
        XCTAssertEqual(result, "0.0 kg")
    }

    func testDecimalPrecision() {
        // Should round to 1 decimal place
        let result = WeightFormatter.format(10.123, useLbs: false, includeUnit: true)
        XCTAssertEqual(result, "10.1 kg")
    }

    func testDecimalPrecisionRoundsUp() {
        // 10.15 should round to 10.2 (banker's rounding varies, but format rounds)
        let result = WeightFormatter.format(10.16, useLbs: false, includeUnit: true)
        XCTAssertEqual(result, "10.2 kg")
    }

    func testLargeValue() {
        let result = WeightFormatter.format(100.0, useLbs: false, includeUnit: true)
        XCTAssertEqual(result, "100.0 kg")
    }

    func testLbsConversionAccuracy() {
        // Test that conversion uses correct factor (2.20462)
        let kg: Float = 1.0
        let expectedLbs = kg * AppConstants.kgToLbs // 2.20462
        let result = WeightFormatter.format(kg, useLbs: true, includeUnit: false)
        XCTAssertEqual(result, String(format: "%.1f", expectedLbs))
    }

    // MARK: - unitLabel Tests

    func testUnitLabelKg() {
        XCTAssertEqual(WeightFormatter.unitLabel(false), "kg")
    }

    func testUnitLabelLbs() {
        XCTAssertEqual(WeightFormatter.unitLabel(true), "lbs")
    }
}
