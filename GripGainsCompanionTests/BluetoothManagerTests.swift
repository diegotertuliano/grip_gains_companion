import XCTest
import CoreBluetooth
@testable import GripGainsCompanion

final class BluetoothManagerTests: XCTestCase {
    var manager: BluetoothManager!
    var mockCentralManager: MockCentralManager!

    override func setUp() {
        super.setUp()
        mockCentralManager = MockCentralManager()
        manager = BluetoothManager(centralManager: mockCentralManager)
        // Clear any persisted lastConnectedDeviceId from previous tests
        UserDefaults.standard.removeObject(forKey: "lastConnectedDeviceId")
    }

    override func tearDown() {
        manager.cancelBackgroundDisconnectTimer()
        manager = nil
        mockCentralManager = nil
        UserDefaults.standard.removeObject(forKey: "lastConnectedDeviceId")
        super.tearDown()
    }

    // MARK: - Background Disconnect Timer Tests

    func testStartBackgroundDisconnectTimerCreatesActiveTimer() {
        // Given: No timer is active
        XCTAssertNil(manager.backgroundDisconnectTimer)

        // When: Start the timer
        manager.startBackgroundDisconnectTimer()

        // Then: Timer should be active
        XCTAssertTrue(manager.backgroundDisconnectTimer?.isValid ?? false)
    }

    func testCancelBackgroundDisconnectTimerInvalidatesTimer() {
        // Given: Timer is active
        manager.startBackgroundDisconnectTimer()
        XCTAssertTrue(manager.backgroundDisconnectTimer?.isValid ?? false)

        // When: Cancel the timer
        manager.cancelBackgroundDisconnectTimer()

        // Then: Timer should no longer be active
        XCTAssertNil(manager.backgroundDisconnectTimer)
    }

    func testStartBackgroundDisconnectTimerCancelsPreviousTimer() {
        // Given: Timer is active
        manager.startBackgroundDisconnectTimer()
        let firstTimerActive = manager.backgroundDisconnectTimer?.isValid ?? false

        // When: Start a new timer
        manager.startBackgroundDisconnectTimer()

        // Then: Should still have an active timer (new one replaced old)
        XCTAssertTrue(firstTimerActive)
        XCTAssertTrue(manager.backgroundDisconnectTimer?.isValid ?? false)
    }

    func testCancelBackgroundDisconnectTimerWhenNoTimerIsNoop() {
        // Given: No timer is active
        XCTAssertNil(manager.backgroundDisconnectTimer)

        // When: Cancel (should not crash)
        manager.cancelBackgroundDisconnectTimer()

        // Then: Still no timer
        XCTAssertNil(manager.backgroundDisconnectTimer)
    }

    // MARK: - Disconnect with preserveAutoReconnect Tests

    func testDisconnectWithPreserveAutoReconnectKeepsLastConnectedDeviceId() {
        // Given: Set a lastConnectedDeviceId via UserDefaults
        let testDeviceId = "test-device-123"
        UserDefaults.standard.set(testDeviceId, forKey: "lastConnectedDeviceId")

        // Recreate manager to pick up the persisted value
        manager = BluetoothManager(centralManager: mockCentralManager)

        // When: Disconnect with preserveAutoReconnect = true
        manager.disconnect(preserveAutoReconnect: true)

        // Then: lastConnectedDeviceId should be preserved
        let persistedId = UserDefaults.standard.string(forKey: "lastConnectedDeviceId")
        XCTAssertEqual(persistedId, testDeviceId, "lastConnectedDeviceId should be preserved")
    }

    func testDisconnectWithoutPreserveAutoReconnectClearsLastConnectedDeviceId() {
        // Given: Set a lastConnectedDeviceId via UserDefaults
        let testDeviceId = "test-device-456"
        UserDefaults.standard.set(testDeviceId, forKey: "lastConnectedDeviceId")

        // Recreate manager to pick up the persisted value
        manager = BluetoothManager(centralManager: mockCentralManager)

        // When: Disconnect with preserveAutoReconnect = false (default)
        manager.disconnect(preserveAutoReconnect: false)

        // Then: lastConnectedDeviceId should be cleared
        let persistedId = UserDefaults.standard.string(forKey: "lastConnectedDeviceId")
        XCTAssertTrue(persistedId?.isEmpty ?? true, "lastConnectedDeviceId should be cleared")
    }

    func testDisconnectDefaultParameterClearsLastConnectedDeviceId() {
        // Given: Set a lastConnectedDeviceId via UserDefaults
        let testDeviceId = "test-device-789"
        UserDefaults.standard.set(testDeviceId, forKey: "lastConnectedDeviceId")

        // Recreate manager to pick up the persisted value
        manager = BluetoothManager(centralManager: mockCentralManager)

        // When: Disconnect with default parameter (should be false)
        manager.disconnect()

        // Then: lastConnectedDeviceId should be cleared
        let persistedId = UserDefaults.standard.string(forKey: "lastConnectedDeviceId")
        XCTAssertTrue(persistedId?.isEmpty ?? true, "lastConnectedDeviceId should be cleared with default parameter")
    }

    // MARK: - Disconnect Scanning Behavior Tests

    func testDisconnectWithPreserveAutoReconnectDoesNotStartScanning() {
        // Given: Mock is ready
        mockCentralManager.reset()

        // When: Disconnect with preserveAutoReconnect = true
        manager.disconnect(preserveAutoReconnect: true)

        // Then: Should NOT call scanForPeripherals
        XCTAssertFalse(mockCentralManager.scanForPeripheralsCalled,
                       "Should not start scanning when preserveAutoReconnect is true")
    }

    func testDisconnectWithoutPreserveAutoReconnectStartsScanning() {
        // Given: Mock is ready with powered on state
        mockCentralManager.reset()
        mockCentralManager.state = .poweredOn

        // When: Disconnect with preserveAutoReconnect = false
        manager.disconnect(preserveAutoReconnect: false)

        // Then: Should call scanForPeripherals
        XCTAssertTrue(mockCentralManager.scanForPeripheralsCalled,
                      "Should start scanning when preserveAutoReconnect is false")
    }

    // MARK: - Disconnect State Tests

    func testDisconnectSetsConnectionStateToDisconnected() {
        // Given: Manager might be in any state
        manager.startScanning()

        // When: Disconnect
        manager.disconnect()

        // Then: Connection state should be disconnected
        XCTAssertEqual(manager.connectionState, .disconnected)
    }

    func testDisconnectCancelsBackgroundDisconnectTimer() {
        // Given: Background timer is active
        manager.startBackgroundDisconnectTimer()
        XCTAssertTrue(manager.backgroundDisconnectTimer?.isValid ?? false)

        // When: Disconnect
        manager.disconnect()

        // Then: Timer should be cancelled
        XCTAssertNil(manager.backgroundDisconnectTimer)
    }

    func testDisconnectStopsScanning() {
        // Given: Manager is scanning
        mockCentralManager.reset()

        // When: Disconnect
        manager.disconnect()

        // Then: Should call stopScan
        XCTAssertTrue(mockCentralManager.stopScanCalled)
    }

    func testDisconnectClearsDeviceList() {
        // Given: Manager has discovered devices (simulate by checking initial state)
        // Note: We can't easily add devices without more mocking, but we verify the method runs

        // When: Disconnect
        manager.disconnect()

        // Then: Discovered devices should be empty
        XCTAssertTrue(manager.discoveredDevices.isEmpty)
    }

    func testDisconnectClearsConnectedDeviceName() {
        // Given: Manager might have a connected device name
        // When: Disconnect
        manager.disconnect()

        // Then: Connected device name should be nil
        XCTAssertNil(manager.connectedDeviceName)
    }

    // MARK: - Start Scanning Tests

    func testStartScanningWhenBluetoothPoweredOn() {
        // Given: Bluetooth is powered on
        mockCentralManager.state = .poweredOn
        mockCentralManager.reset()

        // When: Start scanning
        manager.startScanning()

        // Then: Should call scanForPeripherals
        XCTAssertTrue(mockCentralManager.scanForPeripheralsCalled)
        XCTAssertEqual(manager.connectionState, .scanning)
    }

    func testStartScanningWhenBluetoothNotAvailable() {
        // Given: Bluetooth is not powered on
        mockCentralManager.state = .poweredOff
        mockCentralManager.reset()

        // When: Start scanning
        manager.startScanning()

        // Then: Should NOT call scanForPeripherals and should set error state
        XCTAssertFalse(mockCentralManager.scanForPeripheralsCalled)
        if case .error = manager.connectionState {
            // Expected
        } else {
            XCTFail("Expected error state when Bluetooth not available")
        }
    }

    func testStopScanningCallsStopScan() {
        // Given: Manager is scanning
        mockCentralManager.state = .poweredOn
        manager.startScanning()
        mockCentralManager.reset()

        // When: Stop scanning
        manager.stopScanning()

        // Then: Should call stopScan
        XCTAssertTrue(mockCentralManager.stopScanCalled)
    }

    func testStopScanningSetsStateToDisconnected() {
        // Given: Manager is scanning
        mockCentralManager.state = .poweredOn
        manager.startScanning()
        XCTAssertEqual(manager.connectionState, .scanning)

        // When: Stop scanning
        manager.stopScanning()

        // Then: State should be disconnected
        XCTAssertEqual(manager.connectionState, .disconnected)
    }
}
