import XCTest
@testable import GripGainsCompanion

final class DeviceBatteryTests: XCTestCase {
    // MARK: - Progressor response parsing

    func testParsesProgressorBatteryResponseAsLittleEndianMillivolts() {
        // 3950 mV = 0x0F6E
        let data = Data([0x00, 0x04, 0x6E, 0x0F, 0x00, 0x00])
        XCTAssertEqual(DeviceBattery.progressorMillivolts(fromResponse: data), 3950)
    }

    func testParsesResponseFromSlicedData() {
        let data = Data([0xFF, 0x00, 0x04, 0x6E, 0x0F, 0x00, 0x00]).dropFirst()
        XCTAssertEqual(DeviceBattery.progressorMillivolts(fromResponse: data), 3950)
    }

    func testRejectsWeightPacketsAndShortOrMislabelledResponses() {
        XCTAssertNil(DeviceBattery.progressorMillivolts(fromResponse: Data([0x01, 0x04, 0x6E, 0x0F, 0x00, 0x00])))
        XCTAssertNil(DeviceBattery.progressorMillivolts(fromResponse: Data([0x00, 0x04, 0x6E, 0x0F, 0x00])))
        XCTAssertNil(DeviceBattery.progressorMillivolts(fromResponse: Data([0x00, 0x02, 0x6E, 0x0F, 0x00, 0x00])))
        XCTAssertNil(DeviceBattery.progressorMillivolts(fromResponse: Data()))
    }

    // MARK: - Voltage to percentage

    func testVoltageAtCurvePointsMapsExactly() {
        XCTAssertEqual(DeviceBattery.percent(fromLithiumMillivolts: 4200), 100)
        XCTAssertEqual(DeviceBattery.percent(fromLithiumMillivolts: 3820), 50)
        XCTAssertEqual(DeviceBattery.percent(fromLithiumMillivolts: 3300), 0)
    }

    func testVoltageBetweenCurvePointsInterpolates() {
        XCTAssertEqual(DeviceBattery.percent(fromLithiumMillivolts: 4150), 95)
        XCTAssertEqual(DeviceBattery.percent(fromLithiumMillivolts: 3710), 15)
    }

    func testVoltageOutsideCurveIsClamped() {
        XCTAssertEqual(DeviceBattery.percent(fromLithiumMillivolts: 4350), 100)
        XCTAssertEqual(DeviceBattery.percent(fromLithiumMillivolts: 3000), 0)
        XCTAssertEqual(DeviceBattery.percent(fromLithiumMillivolts: 0), 0)
    }

    func testPercentageNeverIncreasesAsVoltageDrops() {
        var previous = 100
        for mv in stride(from: UInt32(4300), through: 3200, by: -5) {
            let percent = DeviceBattery.percent(fromLithiumMillivolts: mv)
            XCTAssertLessThanOrEqual(percent, previous, "at \(mv) mV")
            XCTAssertTrue((0...100).contains(percent))
            previous = percent
        }
    }
}
