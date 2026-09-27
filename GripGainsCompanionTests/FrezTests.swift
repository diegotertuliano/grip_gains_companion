import CoreBluetooth
import XCTest
@testable import GripGainsCompanion

final class FrezTests: XCTestCase {
    private func packet(start: UInt32 = 0, adc: Int32 = -10_000) -> Data {
        var data = Data([1, 0])
        for i in 0..<9 {
            var raw = adc.littleEndian
            var elapsed = (start + UInt32(i * 4)).littleEndian
            withUnsafeBytes(of: &raw) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &elapsed) { data.append(contentsOf: $0) }
        }
        return data
    }

    func testDetectionUsesAdvertisedNameAndGATT() {
        XCTAssertEqual(DeviceType.detect(name: nil, advertisementData: [CBAdvertisementDataLocalNameKey: "FrezDyno-000123"]), .frezDyno)
        XCTAssertEqual(DeviceType.detect(name: "FrezDyno-000123", advertisementData: [:]), .frezDyno)
        XCTAssertNil(DeviceType.detect(name: "Frez", advertisementData: [:]))
        XCTAssertTrue(DeviceType.frezDyno.usesGATTConnection)
    }

    func testSignedLittleEndianSamplesAndDeviceTime() throws {
        let samples = try FrezRawSample.parse(packet(start: 400, adc: -123_456))
        XCTAssertEqual(samples.count, 9)
        XCTAssertEqual(samples.first, FrezRawSample(adc: -123_456, elapsedMilliseconds: 400))
        XCTAssertEqual(samples.last?.elapsedMilliseconds, 432)
    }

    func testRejectsFragmentsExtraSamplesAndInvalidHeaders() {
        let valid = packet()
        var wrongCode = valid; wrongCode[0] = 2
        var wrongReserved = valid; wrongReserved[1] = 1
        for data in [Data(), Data(valid.prefix(20)), Data(valid.dropLast()), valid + Data(repeating: 0, count: 8), wrongCode, wrongReserved] {
            XCTAssertThrowsError(try FrezRawSample.parse(data))
        }
    }

    func testFirstHundredSamplesAreTareIncludingMidPacketBoundary() throws {
        var measurement = try FrezMeasurement(coefficient: 0.01)
        for index in 0..<11 {
            XCTAssertTrue(try measurement.process(packet(start: UInt32(index * 36))).isEmpty)
        }
        XCTAssertNil(measurement.tareADC)
        var boundary = packet(start: 396, adc: -9_000)
        var unloaded = Int32(-10_000).littleEndian
        withUnsafeBytes(of: &unloaded) { boundary.replaceSubrange(2..<6, with: $0) }
        let output = try measurement.process(boundary)
        XCTAssertEqual(measurement.tareADC, -10_000)
        XCTAssertEqual(output.count, 8)
        XCTAssertEqual(output.first?.weight, 10)
        XCTAssertEqual(output.first?.timestamp, 400_000)
        XCTAssertEqual(output.last?.timestamp, 428_000)
    }

    func testTareIsAverageAndNegativeSlopeIsSupported() throws {
        var measurement = try FrezMeasurement(coefficient: -0.01)
        for index in 0..<11 {
            _ = try measurement.process(packet(start: UInt32(index * 36), adc: 100))
        }
        _ = try measurement.process(packet(start: 396, adc: 200))
        XCTAssertEqual(measurement.tareADC, 101)
        let samples = try measurement.process(packet(start: 432, adc: 1))
        XCTAssertEqual(samples.first?.weight, 1)
    }

    func testClockRegressionRejectsEntireBatchWithoutChangingTare() throws {
        var measurement = try FrezMeasurement(coefficient: 0.01)
        _ = try measurement.process(packet())
        XCTAssertThrowsError(try measurement.process(packet()))
        var regressed = packet(start: 36, adc: 500)
        regressed.replaceSubrange(70..<74, with: [0, 0, 0, 0])
        XCTAssertThrowsError(try measurement.process(regressed))
        for index in 1..<12 {
            _ = try measurement.process(packet(start: UInt32(index * 36)))
        }
        XCTAssertEqual(measurement.tareADC, -10_000)
    }

    func testSessionStopsAt71MinutesBeforeTimestampOverflow() throws {
        var measurement = try FrezMeasurement(coefficient: 0.01)
        for index in 0..<12 { _ = try measurement.process(packet(start: UInt32(index * 36))) }
        let end = FrezMeasurement.maximumElapsedMilliseconds
        let samples = try measurement.process(packet(start: end - 36, adc: -9_000))
        XCTAssertEqual(samples.last?.timestamp, (end - 4) * 1_000)
        for start in [end, 5_000_000, UInt32.max - 32] {
            XCTAssertThrowsError(try measurement.process(packet(start: start))) {
                XCTAssertTrue($0.localizedDescription.contains("71 minutes"))
            }
        }
    }

    func testNewMeasurementDiscardsOldTareAndClock() throws {
        var old = try FrezMeasurement(coefficient: 0.01)
        for i in 0..<12 { _ = try old.process(packet(start: UInt32(i * 36))) }
        XCTAssertNotNil(old.tareADC)
        var new = try FrezMeasurement(coefficient: 0.02)
        XCTAssertTrue(try new.process(packet(adc: 500)).isEmpty)
        XCTAssertNil(new.tareADC)
    }

    func testInvalidCoefficientsNeverProduceForce() {
        for coefficient in [0, Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try FrezMeasurement(coefficient: coefficient))
        }
        for json in ["{}", "{\"a\":0}", "{\"a\":null}", "{\"a\":\"NaN\"}", "{\"a\":1e999}", "not json"] {
            XCTAssertThrowsError(try FrezCoefficientClient.decode(Data(json.utf8), statusCode: 200))
        }
    }

    func testRequestHasOnlySerialAndKeyIsInHeader() throws {
        let request = try FrezCoefficientClient.request(serial: "FrezDyno-000123", accessKey: "  test-key\n")
        XCTAssertEqual(request.url?.absoluteString, "https://api.frez.app/functions/v1/dyno-coefficient?serial=FrezDyno-000123")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Frez-Access-Key"), "test-key")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertThrowsError(try FrezCoefficientClient.request(serial: "FrezDyno-000123&name=other", accessKey: "key"))
        XCTAssertThrowsError(try FrezCoefficientClient.request(serial: "FrezDyno-000123", accessKey: ""))
        XCTAssertThrowsError(try FrezCoefficientClient.request(serial: "FrezDyno-000123", accessKey: "key\r\nInjected: value"))
    }

    func testAllDocumentedAPIFailuresHaveActionableErrors() {
        let cases: [(Int, String, FrezError)] = [
            (400, "invalid_request", .invalidRequest),
            (401, "invalid_access_key", .invalidKey),
            (403, "device_limit_reached", .deviceLimit),
            (403, "developer_device_not_allowlisted", .notAllowlisted),
            (404, "device_not_found", .deviceNotFound),
            (409, "device_ownership_review_required", .ownershipReview),
            (422, "coefficient_request_failed", .invalidCoefficient),
            (429, "service_unavailable", .rateLimited),
            (503, "secret-server-details", .unavailable),
            (302, "", .unavailable)
        ]
        for (status, code, expected) in cases {
            XCTAssertThrowsError(try FrezCoefficientClient.decode(Data("{\"error\":\"\(code)\"}".utf8), statusCode: status)) {
                XCTAssertEqual($0 as? FrezError, expected)
            }
        }
    }

    func testHTTPClientUsesInjectedTransport() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FrezURLProtocol.self]
        let client = FrezCoefficientClient(configuration: config)
        let coefficient = try await client.coefficient(serial: "FrezDyno-000123", accessKey: "test-key")
        XCTAssertEqual(coefficient, 0.000012345678)
    }

    func testRedirectsAreRejected() {
        let client = FrezCoefficientClient()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: URL(string: "https://example.com")!)
        let task = session.dataTask(with: request)
        client.urlSession(session, task: task,
                          willPerformHTTPRedirection: HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!,
                          newRequest: request) { XCTAssertNil($0) }
    }

    func testKeychainSaveReplaceAndRemove() throws {
        let store = FrezAccessKeyStore(service: "com.gripgains.tests.frez.\(UUID().uuidString)")
        defer { try? store.delete() }
        XCTAssertNil(try store.read())
        try store.save(" test-key ")
        XCTAssertEqual(try store.read(), "test-key")
        try store.save("replacement-key")
        XCTAssertEqual(try store.read(), "replacement-key")
        try store.delete()
        XCTAssertNil(try store.read())
    }

    @MainActor
    func testKeySettingsReflectOnlySuccessfulStorage() throws {
        let store = FrezMemoryKeyStore()
        let manager = BluetoothManager(centralManager: MockCentralManager(), frezKeyStore: store)
        XCTAssertFalse(manager.hasFrezAccessKey)
        store.fails = true
        XCTAssertThrowsError(try manager.saveFrezAccessKey("key"))
        XCTAssertFalse(manager.hasFrezAccessKey)
        store.fails = false
        try manager.saveFrezAccessKey("key")
        XCTAssertTrue(manager.hasFrezAccessKey)
        manager.connectedDeviceType = .frezDyno
        XCTAssertThrowsError(try manager.deleteFrezAccessKey())
        manager.connectedDeviceType = nil
        try manager.deleteFrezAccessKey()
        XCTAssertFalse(manager.hasFrezAccessKey)
    }

    @MainActor
    private func configuredService(provider: FrezCoefficientProviding) -> (FrezDynoService, FrezMockPeripheral) {
        let peripheral = FrezMockPeripheral()
        let service = FrezDynoService(peripheral: peripheral, accessKey: "test-key", coefficients: provider)
        service.discoverServices()
        service.servicesDiscovered([CBMutableService(type: FrezGATT.service, primary: true),
                                    CBMutableService(type: FrezGATT.information, primary: false)])
        // Exercise identity arriving before the measurement characteristics.
        service.characteristicsDiscovered([
            CBMutableCharacteristic(type: FrezGATT.serial, properties: [.read], value: nil, permissions: [.readable]),
            CBMutableCharacteristic(type: FrezGATT.firmware, properties: [.read], value: nil, permissions: [.readable])
        ], for: FrezGATT.information)
        service.receivedValue(Data("FrezDyno-000123\0".utf8), for: FrezGATT.serial)
        service.receivedValue(Data("1.0".utf8), for: FrezGATT.firmware)
        service.characteristicsDiscovered([
            CBMutableCharacteristic(type: FrezGATT.write, properties: [.write], value: nil, permissions: [.writeable]),
            CBMutableCharacteristic(type: FrezGATT.notify, properties: [.notify], value: nil, permissions: [])
        ], for: FrezGATT.service)
        return (service, peripheral)
    }

    @MainActor
    func testServiceWaitsForAuthorizationSubscriptionAndTareBeforePublishing() async {
        let provider = FrezStubCoefficients()
        let (service, peripheral) = configuredService(provider: provider)
        defer { service.invalidate() }
        let subscription = expectation(description: "Subscribe after coefficient")
        peripheral.onNotify = { if $0 { subscription.fulfill() } }
        XCTAssertTrue(peripheral.writes.isEmpty)
        await fulfillment(of: [subscription], timeout: 2)
        XCTAssertEqual(provider.requests, 1)
        XCTAssertTrue(peripheral.writes.isEmpty)
        service.notificationStateChanged(true)
        service.notificationStateChanged(true)
        XCTAssertEqual(peripheral.writes, [Data([1, 0])])
        var ready = false
        var samples: [Double] = []
        service.onReady = { ready = true }
        service.onForceSample = { weight, _ in
            XCTAssertTrue(ready)
            samples.append(weight)
        }
        for i in 0..<11 { service.receivedValue(packet(start: UInt32(i * 36)), for: FrezGATT.notify) }
        XCTAssertFalse(ready)
        XCTAssertTrue(samples.isEmpty)
        service.receivedValue(packet(start: 396), for: FrezGATT.notify)
        XCTAssertTrue(ready)
        XCTAssertEqual(samples.count, 8)

        var stopped = false
        service.stop { stopped = true }
        XCTAssertEqual(peripheral.writes.last, Data([2, 0]))
        XCTAssertEqual(peripheral.notifications, [true])
        service.commandCompleted(error: nil)
        XCTAssertEqual(peripheral.notifications, [true, false])
        XCTAssertFalse(stopped)
        service.notificationStateChanged(false)
        XCTAssertTrue(stopped)
        service.receivedValue(packet(start: 432), for: FrezGATT.notify)
        XCTAssertEqual(samples.count, 8)
    }

    @MainActor
    func testRejectedAccessDoesNotSubscribeStartOrRetry() async {
        let provider = FrezStubCoefficients()
        provider.failure = .invalidKey
        let (service, peripheral) = configuredService(provider: provider)
        defer { service.invalidate() }
        let failed = expectation(description: "Access denied")
        service.onError = { error in XCTAssertEqual(error, .invalidKey); failed.fulfill() }
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertEqual(provider.requests, 1)
        XCTAssertTrue(peripheral.notifications.isEmpty)
        XCTAssertTrue(peripheral.writes.isEmpty)
    }

    @MainActor
    func testLateCoefficientAfterDisconnectCannotRestartMeasurement() async {
        let provider = FrezStubCoefficients()
        provider.pause = true
        let requested = expectation(description: "Request began")
        provider.onRequest = { requested.fulfill() }
        let (service, peripheral) = configuredService(provider: provider)
        await fulfillment(of: [requested], timeout: 2)
        service.invalidate()
        let returned = expectation(description: "Late response returned")
        provider.onReturn = { returned.fulfill() }
        provider.continuation?.resume(returning: 0.01)
        await fulfillment(of: [returned], timeout: 2)
        XCTAssertTrue(peripheral.notifications.isEmpty)
        XCTAssertTrue(peripheral.writes.isEmpty)
    }

    @MainActor
    func testMalformedPacketStopsPublishing() async {
        let (service, peripheral) = configuredService(provider: FrezStubCoefficients())
        defer { service.invalidate() }
        let subscribed = expectation(description: "Subscribed")
        peripheral.onNotify = { if $0 { subscribed.fulfill() } }
        await fulfillment(of: [subscribed], timeout: 2)
        service.notificationStateChanged(true)
        var failure: FrezError?
        service.onError = { failure = $0 }
        service.onForceSample = { _, _ in XCTFail("No samples after invalid frame") }
        service.receivedValue(Data([1, 0]), for: FrezGATT.notify)
        XCTAssertNotNil(failure)
        service.receivedValue(packet(), for: FrezGATT.notify)
    }
}

private final class FrezURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Frez-Access-Key"), "test-key")
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"a\":0.000012345678}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class FrezMemoryKeyStore: FrezAccessKeyStoring {
    var key: String?
    var fails = false
    func read() throws -> String? { key }
    func save(_ key: String) throws { if fails { throw FrezError.keychain }; self.key = key }
    func delete() throws { if fails { throw FrezError.keychain }; key = nil }
}

private final class FrezStubCoefficients: FrezCoefficientProviding {
    var requests = 0
    var failure: FrezError?
    var pause = false
    var continuation: CheckedContinuation<Double, Never>?
    var onRequest: (() -> Void)?
    var onReturn: (() -> Void)?
    func coefficient(serial: String, accessKey: String) async throws -> Double {
        requests += 1
        XCTAssertEqual(serial, "FrezDyno-000123")
        XCTAssertEqual(accessKey, "test-key")
        if let failure { throw failure }
        if pause {
            let result = await withCheckedContinuation { continuation in
                self.continuation = continuation
                onRequest?()
            }
            onReturn?()
            return result
        }
        return 0.01
    }
}

private final class FrezMockPeripheral: FrezPeripheral {
    weak var delegate: CBPeripheralDelegate?
    var state: CBPeripheralState = .connected
    var writes: [Data] = []
    var notifications: [Bool] = []
    var onNotify: ((Bool) -> Void)?
    func discoverServices(_ serviceUUIDs: [CBUUID]?) {}
    func discoverCharacteristics(_ characteristicUUIDs: [CBUUID]?, for service: CBService) {}
    func readValue(for characteristic: CBCharacteristic) {}
    func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic) {
        notifications.append(enabled)
        onNotify?(enabled)
    }
    func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) {
        writes.append(data)
    }
}
