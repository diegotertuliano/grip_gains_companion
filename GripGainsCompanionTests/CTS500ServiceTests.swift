import CoreBluetooth
import XCTest
@testable import GripGainsCompanion

final class CTS500ServiceTests: XCTestCase {
    func testBuildsExpectedCommands() {
        XCTAssertEqual(
            CTS500Protocol.command(.startWeightMeasurement),
            Data([0x05, 0xAA, 0x00, 0x00, 0x00, 0xAF])
        )
        XCTAssertEqual(
            CTS500Protocol.command(.stopWeightMeasurement),
            Data([0x05, 0xAB, 0x00, 0x00, 0x00, 0xB0])
        )
        XCTAssertEqual(
            CTS500Protocol.command(.tare),
            Data([0x05, 0xA6, 0x00, 0x00, 0x00, 0xAB])
        )
    }

    func testParserBuffersFragmentedWeightFrame() {
        var parser = CTS500FrameParser()
        let frame = weightFrame(12.34)

        XCTAssertTrue(parser.append(Data(frame.prefix(3))).isEmpty)
        XCTAssertEqual(parser.append(Data(frame.dropFirst(3))), [.weight(12.34)])
    }

    func testParserExtractsCombinedAcknowledgementAndWeightFrames() {
        var parser = CTS500FrameParser()
        var data = CTS500Protocol.command(.tare)
        data.append(weightFrame(42.5))

        XCTAssertEqual(
            parser.append(data),
            [
                .acknowledgement(opcode: 0xA6, payload: [0x00, 0x00, 0x00]),
                .weight(42.5)
            ]
        )
    }

    func testParserRejectsInvalidChecksumAndRecoversAtNextHeader() {
        var parser = CTS500FrameParser()
        var invalidFrame = weightFrame(20)
        invalidFrame[invalidFrame.index(before: invalidFrame.endIndex)] ^= 0xFF

        var data = Data([0x99, 0x88])
        data.append(invalidFrame)
        data.append(weightFrame(7.25))

        XCTAssertEqual(parser.append(data), [.weight(7.25)])
    }

    func testParserKeepsTypedResponsesOutOfWeightSamples() {
        var parser = CTS500FrameParser()
        let response = makeFrame([0x05, 0x80, 0xC4, 0x00, 0x01, 0x63])

        XCTAssertEqual(
            parser.append(response),
            [.response(opcode: 0xC4, payload: [0x00, 0x01, 0x63])]
        )
    }

    func testDetectsBothKnownCTS500Names() {
        XCTAssertEqual(DeviceType.detect(name: "CTS-300", advertisementData: [:]), .jinlianCTS500)
        XCTAssertEqual(DeviceType.detect(name: "cts500", advertisementData: [:]), .jinlianCTS500)
    }

    func testDetectsCTS500FromAdvertisementLocalName() {
        let advertisementData: [String: Any] = [CBAdvertisementDataLocalNameKey: "CTS500"]

        XCTAssertEqual(DeviceType.detect(name: nil, advertisementData: advertisementData), .jinlianCTS500)
    }

    func testCTS500UsesGATTConnection() {
        XCTAssertTrue(DeviceType.jinlianCTS500.usesGATTConnection)
    }

    private func weightFrame(_ weight: Double) -> Data {
        let rawWeight = UInt32((weight * 100).rounded())
        return makeFrame([
            0x05,
            0x01,
            UInt8((rawWeight >> 24) & 0xFF),
            UInt8((rawWeight >> 16) & 0xFF),
            UInt8((rawWeight >> 8) & 0xFF),
            UInt8(rawWeight & 0xFF)
        ])
    }

    private func makeFrame(_ bytesWithoutChecksum: [UInt8]) -> Data {
        var bytes = bytesWithoutChecksum
        bytes.append(CTS500Protocol.checksum(for: bytes))
        return Data(bytes)
    }
}
