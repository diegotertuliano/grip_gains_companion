import Foundation
import Combine

// MARK: - Progressor State Machine

/// Explicit state for the Progressor force handler
enum ProgressorState: Equatable {
    case waitingForSamples
    case calibrating(startTime: Date, samples: [Float])
    case idle(baseline: Float)
    case gripping(baseline: Float, startTime: Date, samples: [Float])
    case weightCalibration(baseline: Float, samples: [Float], isHolding: Bool)

    // Convenience computed properties for UI
    var isCalibrating: Bool {
        if case .calibrating = self { return true }
        return false
    }

    var isWaitingForSamples: Bool {
        if case .waitingForSamples = self { return true }
        return false
    }

    var isEngaged: Bool {
        if case .gripping = self { return true }
        return false
    }

    var baseline: Float {
        switch self {
        case .idle(let baseline), .gripping(let baseline, _, _), .weightCalibration(let baseline, _, _):
            return baseline
        default:
            return 0
        }
    }
}

/// State machine for processing Tindeq Progressor force samples
class ProgressorHandler: ObservableObject {
    // MARK: - Published State

    @Published private(set) var state: ProgressorState = .waitingForSamples
    @Published private(set) var currentForce: Float = 0.0
    @Published private(set) var calibrationTimeRemaining: TimeInterval = AppConstants.calibrationDuration
    @Published private(set) var weightMedian: Float?

    // MARK: - Target Weight State

    /// Target weight from website or manual input (in kg)
    var targetWeight: Float?

    /// Tolerance for off-target detection (in kg)
    var weightTolerance: Float = AppConstants.defaultWeightTolerance

    /// Whether current weight is off target (only valid during gripping)
    @Published private(set) var isOffTarget: Bool = false

    /// Direction of off-target: positive = too heavy, negative = too light, nil = on target
    @Published private(set) var offTargetDirection: Float?

    /// Timer for continuous off-target feedback
    private var offTargetTimer: Timer?

    // MARK: - Combine Publishers

    /// Publishes when calibration completes
    let calibrationCompleted = PassthroughSubject<Void, Never>()

    /// Publishes when grip fails (force drops below threshold)
    let gripFailed = PassthroughSubject<Void, Never>()

    /// Publishes grip session data when disengaged (duration, samples)
    let gripDisengaged = PassthroughSubject<(TimeInterval, [Float]), Never>()

    /// Publishes force updates (force, engaged, weightMedian, weightCalibrationEngaged)
    let forceUpdated = PassthroughSubject<(Float, Bool, Float?, Bool), Never>()

    /// Publishes when off-target state changes during gripping (isOffTarget, direction)
    let offTargetChanged = PassthroughSubject<(Bool, Float?), Never>()

    // MARK: - External Input

    /// Whether engagement is currently allowed (fail button enabled)
    var canEngage: Bool = false

    // MARK: - Convenience Properties (for backward compatibility)

    var engaged: Bool { state.isEngaged }
    var calibrating: Bool { state.isCalibrating }
    var waitingForSamples: Bool { state.isWaitingForSamples }

    // MARK: - Public Methods

    /// Process a single weight sample from the BLE device
    func processSample(_ rawWeight: Float) {
        DispatchQueue.main.async { [self] in
            currentForce = rawWeight
            processStateTransition(rawWeight: rawWeight)
        }
    }

    /// Reset handler state for a new session
    func reset() {
        stopOffTargetTimer()
        state = .waitingForSamples
        currentForce = 0.0
        calibrationTimeRemaining = AppConstants.calibrationDuration
        weightMedian = nil
        isOffTarget = false
        offTargetDirection = nil
    }

    // MARK: - State Machine Logic

    private func processStateTransition(rawWeight: Float) {
        switch state {
        case .waitingForSamples:
            // First sample received - start calibration
            state = .calibrating(startTime: Date(), samples: [rawWeight])
            calibrationTimeRemaining = AppConstants.calibrationDuration

        case .calibrating(let startTime, var samples):
            samples.append(rawWeight)
            let elapsed = Date().timeIntervalSince(startTime)
            calibrationTimeRemaining = max(0, AppConstants.calibrationDuration - elapsed)

            if elapsed >= AppConstants.calibrationDuration {
                let baseline = samples.reduce(0, +) / Float(samples.count)
                state = .idle(baseline: baseline)
                calibrationTimeRemaining = 0
                calibrationCompleted.send()
            } else {
                state = .calibrating(startTime: startTime, samples: samples)
            }

        case .idle(let baseline):
            let taredWeight = rawWeight - baseline
            handleIdleState(rawWeight: rawWeight, taredWeight: taredWeight, baseline: baseline)

        case .gripping(let baseline, let startTime, var samples):
            samples.append(rawWeight)
            let taredWeight = rawWeight - baseline

            if taredWeight < AppConstants.failThreshold {
                // Grip failed
                stopOffTargetTimer()
                let duration = Date().timeIntervalSince(startTime)
                state = .idle(baseline: baseline)
                isOffTarget = false
                offTargetDirection = nil
                gripFailed.send()
                gripDisengaged.send((duration, samples))
            } else {
                state = .gripping(baseline: baseline, startTime: startTime, samples: samples)
                checkOffTarget(taredWeight: taredWeight)
            }
            publishForceUpdate()

        case .weightCalibration(let baseline, var samples, let isHolding):
            let taredWeight = rawWeight - baseline
            handleWeightCalibrationState(
                rawWeight: rawWeight,
                taredWeight: taredWeight,
                baseline: baseline,
                samples: &samples,
                isHolding: isHolding
            )
        }
    }

    private func handleIdleState(rawWeight: Float, taredWeight: Float, baseline: Float) {
        if taredWeight >= AppConstants.engageThreshold {
            if canEngage {
                // Start real grip session
                weightMedian = nil
                state = .gripping(baseline: baseline, startTime: Date(), samples: [rawWeight])
            } else {
                // Start weight calibration
                state = .weightCalibration(baseline: baseline, samples: [rawWeight], isHolding: true)
                weightMedian = rawWeight
            }
        }
        publishForceUpdate()
    }

    private func handleWeightCalibrationState(
        rawWeight: Float,
        taredWeight: Float,
        baseline: Float,
        samples: inout [Float],
        isHolding: Bool
    ) {
        if taredWeight >= AppConstants.engageThreshold {
            if canEngage {
                // Switch to real grip session
                weightMedian = nil
                state = .gripping(baseline: baseline, startTime: Date(), samples: [rawWeight])
            } else if isHolding {
                // Continue weight calibration
                samples.append(rawWeight)
                weightMedian = median(samples)
                state = .weightCalibration(baseline: baseline, samples: samples, isHolding: true)
            } else {
                // Re-engaging weight - start fresh
                state = .weightCalibration(baseline: baseline, samples: [rawWeight], isHolding: true)
                weightMedian = rawWeight
            }
        } else if taredWeight < AppConstants.engageThreshold && isHolding {
            // Put down weight - keep median but mark as not holding
            state = .weightCalibration(baseline: baseline, samples: samples, isHolding: false)
        } else if taredWeight < AppConstants.failThreshold {
            // Completely released - back to idle but keep median
            state = .idle(baseline: baseline)
        }
        publishForceUpdate()
    }

    private func publishForceUpdate() {
        let isWeightCalibrationEngaged: Bool
        if case .weightCalibration(_, _, let isHolding) = state {
            isWeightCalibrationEngaged = isHolding
        } else {
            isWeightCalibrationEngaged = false
        }
        forceUpdated.send((currentForce, engaged, weightMedian, isWeightCalibrationEngaged))
    }

    // MARK: - Target Weight Checking

    /// Check if current weight is off target during gripping
    private func checkOffTarget(taredWeight: Float) {
        guard let target = targetWeight else {
            // No target set, reset off-target state
            stopOffTargetTimer()
            if isOffTarget {
                isOffTarget = false
                offTargetDirection = nil
                offTargetChanged.send((false, nil))
            }
            return
        }

        let difference = taredWeight - target
        let wasOffTarget = isOffTarget

        if abs(difference) >= weightTolerance {
            isOffTarget = true
            offTargetDirection = difference
            if !wasOffTarget {
                // Just went off target - start continuous feedback
                startOffTargetTimer()
            }
        } else {
            stopOffTargetTimer()
            isOffTarget = false
            offTargetDirection = nil
            if wasOffTarget {
                // Just came back on target
                offTargetChanged.send((false, nil))
            }
        }
    }

    // MARK: - Off-Target Timer

    /// Start repeating timer for continuous off-target feedback (every 0.5s)
    private func startOffTargetTimer() {
        stopOffTargetTimer()
        // Fire immediately
        offTargetChanged.send((true, offTargetDirection))
        // Then repeat every 0.5 seconds
        offTargetTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, self.isOffTarget else { return }
            self.offTargetChanged.send((true, self.offTargetDirection))
        }
    }

    /// Stop the off-target feedback timer
    private func stopOffTargetTimer() {
        offTargetTimer?.invalidate()
        offTargetTimer = nil
    }

    // MARK: - Utilities

    private func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2
        } else {
            return sorted[mid]
        }
    }
}
