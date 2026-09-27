import Foundation

/// Protocol v1: one complete notification, never a fragment or combined frames.
struct FrezRawSample: Equatable {
    let adc: Int32
    let elapsedMilliseconds: UInt32

    static func parse(_ data: Data) throws -> [FrezRawSample] {
        let bytes = Array(data)
        guard bytes.count == 74, bytes[0] == 0x01, bytes[1] == 0 else {
            throw FrezError.protocolFailure("Invalid Frez data packet. Expected 74 bytes with nine samples. Check the Dyno firmware and reconnect.")
        }
        func uint32(at offset: Int) -> UInt32 {
            UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 |
            UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        }
        return (0..<9).map { index in
            FrezRawSample(adc: Int32(bitPattern: uint32(at: 2 + index * 8)),
                          elapsedMilliseconds: uint32(at: 6 + index * 8))
        }
    }
}

struct FrezMeasurement {
    // Keep the app's existing UInt32 microsecond timeline safely below overflow.
    static let maximumElapsedMilliseconds: UInt32 = 71 * 60 * 1_000
    private let coefficient: Double
    private var lastElapsed: UInt32?
    private var tareSum: Double = 0
    private var tareCount = 0
    private(set) var tareADC: Double?

    init(coefficient: Double) throws {
        guard coefficient.isFinite, coefficient != 0 else { throw FrezError.invalidCoefficient }
        self.coefficient = coefficient
    }

    mutating func process(_ packet: Data) throws -> [TimestampedSample] {
        let samples = try FrezRawSample.parse(packet)
        // Validate the whole batch before updating tare or publishing any samples.
        var previous = lastElapsed
        for sample in samples {
            guard sample.elapsedMilliseconds < Self.maximumElapsedMilliseconds else {
                throw FrezError.protocolFailure("Frez measurement reached 71 minutes. Reconnect the Dyno to start a new measurement.")
            }
            if let previous, sample.elapsedMilliseconds <= previous {
                throw FrezError.protocolFailure("The Frez device clock restarted or repeated a sample. Reconnect to start a new measurement.")
            }
            previous = sample.elapsedMilliseconds
        }
        lastElapsed = previous
        var output: [TimestampedSample] = []
        for sample in samples {
            guard let tareADC else {
                tareSum += Double(sample.adc)
                tareCount += 1
                if tareCount == 100 { self.tareADC = tareSum / 100 }
                continue
            }
            let weight = coefficient * (Double(sample.adc) - tareADC)
            guard weight.isFinite else { throw FrezError.invalidCoefficient }
            output.append(TimestampedSample(weight: weight, timestamp: sample.elapsedMilliseconds * 1_000))
        }
        return output
    }
}
