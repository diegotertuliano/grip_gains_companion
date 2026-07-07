import XCTest
@testable import GripGainsCompanion

final class CountdownSoundTests: XCTestCase {

    func testPlaysCountdownOnceForEachSecondFromFiveToZero() {
        var calls: [Int] = []
        let countdownSound = CountdownSound { calls.append($0) }

        [20, 6, 5, 5, 4, 3, 2, 1, 0, -1].forEach {
            countdownSound.onRemainingTimeChanged($0)
        }

        XCTAssertEqual(calls, [5, 4, 3, 2, 1, 0])
    }

    func testResetsCountdownAfterTimerReturnsAboveFiveSeconds() {
        var calls: [Int] = []
        let countdownSound = CountdownSound { calls.append($0) }

        [5, 4, 20, 5, 4].forEach {
            countdownSound.onRemainingTimeChanged($0)
        }

        XCTAssertEqual(calls, [5, 4, 5, 4])
    }

    func testNullRemainingTimeClearsCountdownState() {
        var calls: [Int] = []
        let countdownSound = CountdownSound { calls.append($0) }

        countdownSound.onRemainingTimeChanged(5)
        countdownSound.onRemainingTimeChanged(nil)
        countdownSound.onRemainingTimeChanged(5)

        XCTAssertEqual(calls, [5, 5])
    }
}
