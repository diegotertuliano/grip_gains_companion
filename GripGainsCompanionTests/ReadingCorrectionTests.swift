import XCTest
import Combine
@testable import GripGainsCompanion

final class ReadingCorrectionTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var store: ReadingCorrectionStore!
    private var manager: BluetoothManager!
    private var cancellables: Set<AnyCancellable> = []
    private let device = ReadingCorrectionDevice(peripheralID: UUID(), type: .pitchSixForceBoard)

    override func setUp() {
        super.setUp()
        suiteName = "ReadingCorrectionTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        store = ReadingCorrectionStore(defaults: defaults)
        manager = BluetoothManager(centralManager: MockCentralManager(), correctionStore: store)
    }

    override func tearDown() {
        cancellables.removeAll()
        manager = nil
        store = nil
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func connect(_ device: ReadingCorrectionDevice) {
        manager.prepareReadingCorrection(for: device)
        manager.connectedDeviceType = device.type
        manager.connectionState = .connected
    }

    private func drainMainQueue() {
        let drained = expectation(description: "Pending samples processed")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }

    func testIdentityPreservesPrecisionAndSignedReadings() {
        for value in [0, -0.0123456789, 34.567890123] {
            XCTAssertEqual(ReadingCorrection.identity.apply(to: value), value)
        }
        XCTAssertFalse(ReadingCorrection.identity.isActive)
    }

    func testHundredfoldCorrectionAndSignedOffset() {
        let correction = ReadingCorrection(multiplier: 0.01, offsetKg: -2)
        XCTAssertEqual(correction.apply(to: 2500), 23)
        XCTAssertEqual(correction.apply(to: 0), -2)
        XCTAssertEqual(ReadingCorrection(multiplier: 2, offsetKg: 3).apply(to: 4), 11)
    }

    func testInvalidValuesAndOverflowAreRejected() {
        for factor in [0, -1, Double.nan, .infinity, -.infinity] {
            XCTAssertFalse(ReadingCorrection(multiplier: factor).isValid)
        }
        XCTAssertFalse(ReadingCorrection(offsetKg: .nan).isValid)
        XCTAssertFalse(ReadingCorrection(offsetKg: .infinity).isValid)
        XCTAssertNil(ReadingCorrection.identity.apply(to: .infinity))
        XCTAssertNil(ReadingCorrection.identity.apply(to: .nan))
        XCTAssertNil(ReadingCorrection(multiplier: 2).apply(to: .greatestFiniteMagnitude))
    }

    func testDecimalSeparatorsAndInvalidDrafts() {
        XCTAssertEqual(ReadingCorrection.parse(multiplier: "0,01", offset: " -2,5 ", useLbs: false),
                       ReadingCorrection(multiplier: 0.01, offsetKg: -2.5))
        XCTAssertEqual(ReadingCorrection.parse(multiplier: "0.01", offset: "+2.5", useLbs: false),
                       ReadingCorrection(multiplier: 0.01, offsetKg: 2.5))
        for text in ["", "-", "0", "-1", "nan", "inf", "1e999", "1,2.3", "1,2,3", "abc"] {
            XCTAssertNil(ReadingCorrection.parse(multiplier: text, offset: "0", useLbs: false), text)
        }
        for text in ["", "-", "nan", "inf", "1,2.3"] {
            XCTAssertNil(ReadingCorrection.parse(multiplier: "1", offset: text, useLbs: false), text)
        }
    }

    func testPoundsOffsetConvertsOnceAndRoundTrips() throws {
        let correction = try XCTUnwrap(ReadingCorrection.parse(
            multiplier: "0.01", offset: String(-2 * AppConstants.kgToLbs), useLbs: true))
        XCTAssertEqual(correction.offsetKg, -2, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(correction.apply(to: 2500)), 23, accuracy: 1e-12)
        for useLbs in [false, true] {
            let roundTrip = try XCTUnwrap(ReadingCorrection.parse(
                multiplier: correction.multiplierText, offset: correction.offsetText(useLbs: useLbs), useLbs: useLbs))
            XCTAssertEqual(roundTrip.multiplier, correction.multiplier)
            XCTAssertEqual(roundTrip.offsetKg, correction.offsetKg, accuracy: 1e-12)
        }
    }

    func testPersistenceIsScopedByDeviceAndTypeAndCanBeRemoved() {
        let correction = ReadingCorrection(multiplier: 0.01, offsetKg: 1)
        XCTAssertTrue(store.save(correction, for: device))
        let restored = ReadingCorrectionStore(defaults: defaults)
        XCTAssertEqual(restored.correction(for: device), correction)
        XCTAssertEqual(restored.correction(for: ReadingCorrectionDevice(peripheralID: UUID(), type: device.type)), .identity)
        XCTAssertEqual(restored.correction(for: ReadingCorrectionDevice(peripheralID: device.peripheralID, type: .tindeqProgressor)), .identity)
        XCTAssertFalse(restored.save(ReadingCorrection(multiplier: 0), for: device))
        XCTAssertEqual(restored.correction(for: device), correction)
        XCTAssertTrue(restored.save(.identity, for: device))
        XCTAssertEqual(store.correction(for: device), .identity)
    }

    func testCorruptOrInvalidStoredProfileFallsBackToIdentity() {
        store.save(ReadingCorrection(multiplier: 0.01), for: device)
        let key = defaults.dictionaryRepresentation().keys.first { $0.hasPrefix("deviceReadingCorrection.") }!
        for data in [Data("bad json".utf8), Data("{\"multiplier\":0,\"offsetKg\":0}".utf8)] {
            defaults.set(data, forKey: key)
            XCTAssertEqual(store.correction(for: device), .identity)
        }
    }

    func testSharedPipelineCorrectsEveryDeviceTypeAndKeepsRawPreviewAndTimestamp() {
        var corrected: [(Double, UInt32)] = []
        var previews: [Double] = []
        manager.onForceSample = { corrected.append(($0, $1)) }
        manager.reportedForceSamples.sink { previews.append($0) }.store(in: &cancellables)
        for type in DeviceType.allCases {
            let source = ReadingCorrectionDevice(peripheralID: UUID(), type: type)
            store.save(ReadingCorrection(multiplier: 0.01, offsetKg: -1), for: source)
            connect(source)
            manager.receiveForceSample(2500, timestamp: 12345, from: source)
            XCTAssertEqual(corrected.last?.0, 24)
            XCTAssertEqual(corrected.last?.1, 12345)
            XCTAssertEqual(previews.last, 2500)
        }
        XCTAssertEqual(corrected.count, DeviceType.allCases.count)
    }

    func testReconnectReloadsCorrectionAndSwitchingDevicesUsesIdentity() {
        connect(device)
        XCTAssertTrue(manager.saveReadingCorrection(ReadingCorrection(multiplier: 0.01), for: device))
        manager.disconnect(preserveAutoReconnect: true)
        XCTAssertNil(manager.readingCorrectionDevice)
        connect(device)
        XCTAssertEqual(manager.readingCorrection.multiplier, 0.01)
        connect(ReadingCorrectionDevice(peripheralID: UUID(), type: device.type))
        XCTAssertEqual(manager.readingCorrection, .identity)
        XCTAssertFalse(manager.saveReadingCorrection(ReadingCorrection(multiplier: 2), for: device))
        XCTAssertEqual(store.correction(for: device).multiplier, 0.01)
    }

    func testDisconnectedStaleAndNonfiniteSamplesAreIgnored() {
        connect(device)
        manager.onForceSample = { _, _ in XCTFail("Invalid sample must not leave the manager") }
        let other = ReadingCorrectionDevice(peripheralID: UUID(), type: device.type)
        manager.receiveForceSample(100, timestamp: 1, from: other)
        manager.receiveForceSample(.nan, timestamp: 2, from: device)
        manager.receiveForceSample(.infinity, timestamp: 3, from: device)
        manager.connectionState = .disconnected
        manager.receiveForceSample(100, timestamp: 4, from: device)
        XCTAssertFalse(manager.saveReadingCorrection(ReadingCorrection(multiplier: 2), for: device))
    }

    func testCorrectionFeedsDisplayGraphGripDetectionAndRecordedRep() {
        connect(device)
        manager.saveReadingCorrection(ReadingCorrection(multiplier: 0.01), for: device)
        let handler = ProgressorHandler()
        handler.enableCalibration = false
        handler.enablePercentageThresholds = false
        handler.engageThreshold = 3
        handler.failThreshold = 1
        handler.canEngage = true
        let tracker = RepTracker()
        var chartForces: [Double] = []
        handler.onSampleProcessed = { _, force in chartForces.append(force) }
        handler.gripDisengaged.sink { duration, samples in
            tracker.recordRep(duration: duration, samples: samples, targetWeight: nil)
        }.store(in: &cancellables)
        manager.onForceSample = { handler.processSample($0, timestamp: $1) }

        manager.receiveForceSample(0, timestamp: 0, from: device)
        manager.receiveForceSample(200, timestamp: 100_000, from: device)
        drainMainQueue()
        XCTAssertEqual(handler.currentForce, 2)
        XCTAssertFalse(handler.engaged) // 200 raw must not cross the 3 kg threshold.

        manager.receiveForceSample(2500, timestamp: 200_000, from: device)
        drainMainQueue()
        XCTAssertTrue(handler.engaged)
        XCTAssertEqual(handler.currentForce, 25)

        manager.receiveForceSample(50, timestamp: 300_000, from: device)
        drainMainQueue()
        XCTAssertFalse(handler.engaged) // 50 raw becomes 0.5 kg and ends the rep.
        XCTAssertEqual(chartForces, [0, 2, 25, 0.5])
        XCTAssertEqual(tracker.currentSetReps.count, 1)
        XCTAssertEqual(tracker.currentSetReps.first?.samples, [25, 0.5])
    }

    func testApplyingCorrectionAndResetDropsAlreadyQueuedOldScaleSamples() {
        connect(device)
        let handler = ProgressorHandler()
        handler.enableCalibration = false
        var chartForces: [Double] = []
        handler.onSampleProcessed = { _, force in chartForces.append(force) }
        manager.onForceSample = { handler.processSample($0, timestamp: $1) }
        manager.receiveForceSample(2500, timestamp: 1, from: device)
        manager.saveReadingCorrection(ReadingCorrection(multiplier: 0.01), for: device)
        handler.reset()
        manager.receiveForceSample(2500, timestamp: 2, from: device)
        drainMainQueue()
        XCTAssertEqual(chartForces, [25])
        XCTAssertEqual(handler.currentForce, 25)
    }
}
