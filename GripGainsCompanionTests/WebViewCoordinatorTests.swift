import XCTest
@testable import GripGainsCompanion

final class WebViewCoordinatorTests: XCTestCase {

    var coordinator: WebViewCoordinator!

    override func setUp() {
        super.setUp()
        coordinator = WebViewCoordinator()
    }

    override func tearDown() {
        coordinator = nil
        super.tearDown()
    }

    func testPreparationPhaseIsCurrentInsideCallback() {
        let coordinator = self.coordinator!
        var phases: [Bool] = []
        coordinator.onPreparationStateChanged = { preparing in
            XCTAssertEqual(coordinator.isPreparationPhase, preparing)
            phases.append(coordinator.isPreparationPhase)
        }
        XCTAssertFalse(coordinator.isPreparationPhase)
        coordinator.updatePreparationState(true)  // Initial countdown, before any rep.
        coordinator.updatePreparationState(false) // Rep starts.
        coordinator.updatePreparationState(true)  // Rest.
        coordinator.updatePreparationState(false) // Timer exits.
        XCTAssertEqual(phases, [true, false, true, false])
    }

    // MARK: - parseWeight Tests

    func testParseKgWithUnit() {
        let result = coordinator.parseWeight("20.5 kg")
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, 20.5, accuracy: 0.001)
    }

    func testParseLbsWithUnit() {
        // 44.0 lbs / 2.20462 = ~19.958 kg
        let result = coordinator.parseWeight("44.0 lbs")
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, 44.0 / AppConstants.kgToLbs, accuracy: 0.001)
    }

    func testParseLbSingular() {
        // 10 lb / 2.20462 = ~4.536 kg
        let result = coordinator.parseWeight("10 lb")
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, 10.0 / AppConstants.kgToLbs, accuracy: 0.001)
    }

    func testParseUppercaseKg() {
        let result = coordinator.parseWeight("20 KG")
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, 20.0, accuracy: 0.001)
    }

    func testParseMixedCaseLbs() {
        // 15 Lbs / 2.20462 = ~6.804 kg
        let result = coordinator.parseWeight("15 Lbs")
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, 15.0 / AppConstants.kgToLbs, accuracy: 0.001)
    }

    func testParseWithExtraWhitespace() {
        let result = coordinator.parseWeight("  25.5 kg  ")
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, 25.5, accuracy: 0.001)
    }

    func testParseInteger() {
        let result = coordinator.parseWeight("30 kg")
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, 30.0, accuracy: 0.001)
    }

    func testParseEmptyString() {
        let result = coordinator.parseWeight("")
        XCTAssertNil(result)
    }

    func testParseNoUnit() {
        // No unit detected, should assume kg (no conversion)
        let result = coordinator.parseWeight("25.5")
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, 25.5, accuracy: 0.001)
    }

    func testParseInvalidString() {
        let result = coordinator.parseWeight("abc")
        XCTAssertNil(result)
    }

    func testParseNegative() {
        let result = coordinator.parseWeight("-5 kg")
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, -5.0, accuracy: 0.001)
    }

    func testParseZero() {
        let result = coordinator.parseWeight("0 kg")
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, 0.0, accuracy: 0.001)
    }

    func testParseOnlyUnit() {
        let result = coordinator.parseWeight("kg")
        XCTAssertNil(result)
    }

    func testParseWhitespaceOnly() {
        let result = coordinator.parseWeight("   ")
        XCTAssertNil(result)
    }

    func testParseLbsUppercase() {
        let result = coordinator.parseWeight("20 LBS")
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, 20.0 / AppConstants.kgToLbs, accuracy: 0.001)
    }

    func testParseLargeValue() {
        let result = coordinator.parseWeight("100.5 kg")
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, 100.5, accuracy: 0.001)
    }

    func testParseSmallDecimal() {
        let result = coordinator.parseWeight("0.5 kg")
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, 0.5, accuracy: 0.001)
    }
}
