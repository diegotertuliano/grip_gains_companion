import CoreBluetooth
@testable import GripGainsCompanion

/// Mock implementation of CentralManagerProtocol for testing
class MockCentralManager: CentralManagerProtocol {
    // MARK: - Protocol Properties

    var state: CBManagerState = .poweredOn

    // MARK: - Call Tracking

    var scanForPeripheralsCalled = false
    var scanForPeripheralsCallCount = 0
    var lastScanServices: [CBUUID]?
    var lastScanOptions: [String: Any]?

    var stopScanCalled = false
    var stopScanCallCount = 0

    var connectCalled = false
    var connectCallCount = 0
    var lastConnectedPeripheral: CBPeripheral?

    var cancelConnectionCalled = false
    var cancelConnectionCallCount = 0
    var lastCancelledPeripheral: CBPeripheral?

    // MARK: - Protocol Methods

    func scanForPeripherals(withServices serviceUUIDs: [CBUUID]?, options: [String: Any]?) {
        scanForPeripheralsCalled = true
        scanForPeripheralsCallCount += 1
        lastScanServices = serviceUUIDs
        lastScanOptions = options
    }

    func stopScan() {
        stopScanCalled = true
        stopScanCallCount += 1
    }

    func connect(_ peripheral: CBPeripheral, options: [String: Any]?) {
        connectCalled = true
        connectCallCount += 1
        lastConnectedPeripheral = peripheral
    }

    func cancelPeripheralConnection(_ peripheral: CBPeripheral) {
        cancelConnectionCalled = true
        cancelConnectionCallCount += 1
        lastCancelledPeripheral = peripheral
    }

    // MARK: - Test Helpers

    func reset() {
        scanForPeripheralsCalled = false
        scanForPeripheralsCallCount = 0
        lastScanServices = nil
        lastScanOptions = nil

        stopScanCalled = false
        stopScanCallCount = 0

        connectCalled = false
        connectCallCount = 0
        lastConnectedPeripheral = nil

        cancelConnectionCalled = false
        cancelConnectionCallCount = 0
        lastCancelledPeripheral = nil
    }
}
