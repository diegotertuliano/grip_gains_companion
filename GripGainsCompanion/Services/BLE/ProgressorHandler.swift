import Foundation
import Combine

// MARK: - Progressor State Machine

/// Explicit state for the Progressor force handler
enum ProgressorState: Equatable {
    case waitingForSamples
    case calibrating(startTime: Date, samples: [TimestampedSample])
    case idle(baseline: Float)
    case gripping(baseline: Float, startTimestamp: UInt32, samples: [TimestampedSample])
    case weightCalibration(baseline: Float, samples: [TimestampedSample], isHolding: Bool)

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

    // Session statistics (live during grip, final after grip ends)
    @Published private(set) var sessionMean: Float?
    @Published private(set) var sessionStdDev: Float?

    // Force history for graph (timestamp, force value)
    @Published private(set) var forceHistory: [(timestamp: Date, force: Float)] = []

    // Last device timestamp received (microseconds) - used for elapsed time calculation
    private var lastTimestamp: UInt32 = 0

    // Reference point for converting device timestamps to display timestamps
    private var firstDeviceTimestamp: UInt32?
    private var firstDisplayTimestamp: Date?

    // MARK: - Target Weight State

    /// Target weight from website or manual input
    var targetWeight: Float?

    /// Tolerance for off-target detection
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

    /// Whether to run calibration on startup (default: true)
    var enableCalibration: Bool = true

    /// Configurable engage threshold (kg) - force needed to start grip
    var engageThreshold: Float = AppConstants.defaultEngageThreshold

    /// Configurable fail threshold (kg) - force below this ends grip
    var failThreshold: Float = AppConstants.defaultFailThreshold

    // MARK: - Percentage-Based Thresholds

    /// Whether to use percentage-based thresholds instead of fixed kg values
    var enablePercentageThresholds: Bool = AppConstants.defaultEnablePercentageThresholds

    /// Engage threshold as percentage of target weight (0.0-1.0)
    var engagePercentage: Float = AppConstants.defaultEngagePercentage

    /// Disengage threshold as percentage of target weight (0.0-1.0)
    var disengagePercentage: Float = AppConstants.defaultDisengagePercentage

    /// Tolerance as percentage of target weight (0.0-1.0)
    var tolerancePercentage: Float = AppConstants.defaultTolerancePercentage

    // MARK: - Percentage Threshold Bounds

    /// Minimum engage threshold in kg (0 = disabled, use pure percentage)
    var engageFloor: Float = AppConstants.defaultEngageFloor
    /// Maximum engage threshold in kg (0 = disabled, use pure percentage)
    var engageCeiling: Float = AppConstants.defaultEngageCeiling
    /// Minimum disengage threshold in kg (0 = disabled, use pure percentage)
    var disengageFloor: Float = AppConstants.defaultDisengageFloor
    /// Maximum disengage threshold in kg (0 = disabled, use pure percentage)
    var disengageCeiling: Float = AppConstants.defaultDisengageCeiling
    /// Minimum tolerance in kg (0 = disabled, use pure percentage)
    var toleranceFloor: Float = AppConstants.defaultToleranceFloor
    /// Maximum tolerance in kg (0 = disabled, use pure percentage)
    var toleranceCeiling: Float = AppConstants.defaultToleranceCeiling

    /// Apply floor and ceiling bounds to a value (0 = disabled for that bound)
    private func applyBounds(_ value: Float, floor: Float, ceiling: Float) -> Float {
        let floored = floor > 0 ? max(value, floor) : value
        return ceiling > 0 ? min(floored, ceiling) : floored
    }

    /// Effective engage threshold - uses percentage if enabled, otherwise fixed kg
    private var effectiveEngageThreshold: Float {
        if enablePercentageThresholds, let target = targetWeight {
            return applyBounds(target * engagePercentage, floor: engageFloor, ceiling: engageCeiling)
        }
        return engageThreshold
    }

    /// Effective fail threshold - uses percentage if enabled, otherwise fixed kg
    private var effectiveFailThreshold: Float {
        if enablePercentageThresholds, let target = targetWeight {
            return applyBounds(target * disengagePercentage, floor: disengageFloor, ceiling: disengageCeiling)
        }
        return failThreshold
    }

    /// Effective tolerance - uses percentage if enabled, otherwise fixed kg
    private var effectiveTolerance: Float {
        if enablePercentageThresholds, let target = targetWeight {
            return applyBounds(target * tolerancePercentage, floor: toleranceFloor, ceiling: toleranceCeiling)
        }
        return weightTolerance
    }

    // MARK: - Convenience Properties (for backward compatibility)

    var engaged: Bool { state.isEngaged }
    var calibrating: Bool { state.isCalibrating }
    var waitingForSamples: Bool { state.isWaitingForSamples }

    /// Elapsed seconds since grip started (0 if not gripping)
    var gripElapsedSeconds: Int {
        if case .gripping(_, let startTimestamp, _) = state {
            return Int((lastTimestamp - startTimestamp) / 1_000_000)
        }
        return 0
    }

    // MARK: - Public Methods

    /// Process a single force sample from the BLE device
    /// - Parameters:
    ///   - rawWeight: Force value from device
    ///   - timestamp: Device timestamp in microseconds
    func processSample(_ rawWeight: Float, timestamp: UInt32) {
        DispatchQueue.main.async { [self] in
            currentForce = rawWeight
            lastTimestamp = timestamp

            // Calculate display timestamp from device timestamp to properly space batched samples
            let displayTimestamp: Date
            if let firstDevice = firstDeviceTimestamp, let firstDisplay = firstDisplayTimestamp {
                // Calculate offset from first sample in microseconds, convert to seconds
                let offsetMicros = timestamp - firstDevice
                displayTimestamp = firstDisplay.addingTimeInterval(Double(offsetMicros) / 1_000_000.0)
            } else {
                // First sample - establish reference point
                firstDeviceTimestamp = timestamp
                firstDisplayTimestamp = Date()
                displayTimestamp = firstDisplayTimestamp!
            }

            forceHistory.append((timestamp: displayTimestamp, force: rawWeight))
            processStateTransition(rawWeight: rawWeight, timestamp: timestamp)
        }
    }

    /// Reset handler state for a new session
    func reset() {
        resetCommonState()
        currentForce = 0.0
    }

    /// Trigger recalibration - resets to waitingForSamples state
    func recalibrate() {
        resetCommonState()
    }

    /// Common reset logic shared between reset() and recalibrate()
    private func resetCommonState() {
        stopOffTargetTimer()
        state = .waitingForSamples
        calibrationTimeRemaining = AppConstants.calibrationDuration
        weightMedian = nil
        isOffTarget = false
        offTargetDirection = nil
        sessionMean = nil
        sessionStdDev = nil
        forceHistory = []
        firstDeviceTimestamp = nil
        firstDisplayTimestamp = nil
    }

    // MARK: - State Machine Logic

    private func processStateTransition(rawWeight: Float, timestamp: UInt32) {
        let sample = TimestampedSample(weight: rawWeight, timestamp: timestamp)

        switch state {
        case .waitingForSamples:
            // First sample received - start calibration or skip to idle
            forceHistory = []  // Clear history on new session
            if enableCalibration {
                state = .calibrating(startTime: Date(), samples: [sample])
                calibrationTimeRemaining = AppConstants.calibrationDuration
            } else {
                // Skip calibration - baseline is 0
                state = .idle(baseline: 0)
                calibrationTimeRemaining = 0
                calibrationCompleted.send()
            }

        case .calibrating(let startTime, var samples):
            samples.append(sample)
            let elapsed = Date().timeIntervalSince(startTime)
            calibrationTimeRemaining = max(0, AppConstants.calibrationDuration - elapsed)

            if elapsed >= AppConstants.calibrationDuration {
                let baseline = samples.map(\.weight).reduce(0, +) / Float(samples.count)
                state = .idle(baseline: baseline)
                calibrationTimeRemaining = 0
                calibrationCompleted.send()
            } else {
                state = .calibrating(startTime: startTime, samples: samples)
            }

        case .idle(let baseline):
            let taredWeight = rawWeight - baseline
            handleIdleState(rawWeight: rawWeight, taredWeight: taredWeight, baseline: baseline, timestamp: timestamp)

        case .gripping(let baseline, let startTimestamp, var samples):
            samples.append(sample)
            let taredWeight = rawWeight - baseline

            // Calculate live statistics from raw samples
            let weights = samples.map(\.weight)
            sessionMean = mean(weights)
            sessionStdDev = standardDeviation(weights)

            if taredWeight < effectiveFailThreshold {
                // Grip failed - keep statistics for display after grip ends
                stopOffTargetTimer()
                // Calculate duration from device timestamps (microseconds to seconds)
                let duration = Double(timestamp - startTimestamp) / 1_000_000.0
                state = .idle(baseline: baseline)
                canEngage = false
                isOffTarget = false
                offTargetDirection = nil
                gripFailed.send()
                gripDisengaged.send((duration, weights))
            } else {
                state = .gripping(baseline: baseline, startTimestamp: startTimestamp, samples: samples)
                checkOffTarget(rawWeight: rawWeight)
            }
            publishForceUpdate()

        case .weightCalibration(let baseline, var samples, let isHolding):
            let taredWeight = rawWeight - baseline
            handleWeightCalibrationState(
                rawWeight: rawWeight,
                taredWeight: taredWeight,
                baseline: baseline,
                samples: &samples,
                isHolding: isHolding,
                timestamp: timestamp
            )
        }
    }

    private func handleIdleState(rawWeight: Float, taredWeight: Float, baseline: Float, timestamp: UInt32) {
        let sample = TimestampedSample(weight: rawWeight, timestamp: timestamp)
        if taredWeight >= effectiveEngageThreshold {
            if canEngage {
                // Start real grip session
                weightMedian = nil
                state = .gripping(baseline: baseline, startTimestamp: timestamp, samples: [sample])
            } else {
                // Start weight calibration
                state = .weightCalibration(baseline: baseline, samples: [sample], isHolding: true)
                weightMedian = rawWeight
            }
        }
        publishForceUpdate()
    }

    private func handleWeightCalibrationState(
        rawWeight: Float,
        taredWeight: Float,
        baseline: Float,
        samples: inout [TimestampedSample],
        isHolding: Bool,
        timestamp: UInt32
    ) {
        let sample = TimestampedSample(weight: rawWeight, timestamp: timestamp)
        let weights = samples.map(\.weight)

        if taredWeight >= effectiveEngageThreshold {
            if canEngage {
                // Switch to real grip session
                weightMedian = nil
                state = .gripping(baseline: baseline, startTimestamp: timestamp, samples: [sample])
            } else if isHolding {
                // Continue weight calibration
                samples.append(sample)
                weightMedian = median(samples.map(\.weight))
                state = .weightCalibration(baseline: baseline, samples: samples, isHolding: true)
            } else {
                // Re-engaging weight - start fresh
                state = .weightCalibration(baseline: baseline, samples: [sample], isHolding: true)
                weightMedian = rawWeight
            }
        } else if taredWeight < effectiveEngageThreshold && isHolding {
            // Put down weight - calculate final trimmed median and mark as not holding
            weightMedian = trimmedMedian(weights)
            state = .weightCalibration(baseline: baseline, samples: samples, isHolding: false)
        } else if taredWeight < effectiveFailThreshold {
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
    private func checkOffTarget(rawWeight: Float) {
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

        let difference = rawWeight - target
        let wasOffTarget = isOffTarget

        if abs(difference) >= effectiveTolerance {
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

    // MARK: - Statistics Utilities (delegating to shared implementation)

    func median(_ values: [Float]) -> Float {
        StatisticsUtilities.median(values)
    }

    func mean(_ values: [Float]) -> Float {
        StatisticsUtilities.mean(values)
    }

    func standardDeviation(_ values: [Float]) -> Float {
        StatisticsUtilities.standardDeviation(values)
    }

    func trimmedMedian(_ values: [Float], trimFraction: Float = 0.3) -> Float {
        StatisticsUtilities.trimmedMedian(values, trimFraction: trimFraction)
    }
}
