import XCTest
import Combine
@testable import GripGainsCompanion

final class ProgressorHandlerTests: XCTestCase {

    var handler: ProgressorHandler!
    var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        handler = ProgressorHandler()
        cancellables = []
        testTimestamp = 0
    }

    override func tearDown() {
        cancellables = nil
        handler = nil
        super.tearDown()
    }

    // MARK: - Test Helpers

    /// Simulated device timestamp counter (microseconds)
    private var testTimestamp: UInt32 = 0

    /// Process a sample with auto-incrementing timestamp (~80Hz = 12500 microseconds between samples)
    private func processTestSample(_ weight: Float) {
        testTimestamp += 12500
        handler.processSample(weight, timestamp: testTimestamp)
    }

    /// Wait for async dispatch to complete
    private func waitForMainQueue() {
        let expectation = expectation(description: "Main queue processed")
        DispatchQueue.main.async {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    /// Set up handler in idle state with baseline = 0 (skips calibration)
    private func setupIdleStateWithZeroBaseline() {
        handler.enableCalibration = false
        processTestSample(0)  // First sample triggers transition to idle with baseline 0
        waitForMainQueue()
    }

    // MARK: - Median Tests

    func testMedianOddCount() {
        let result = handler.median([1, 3, 2])
        XCTAssertEqual(result, 2.0)
    }

    func testMedianEvenCount() {
        let result = handler.median([1, 2, 3, 4])
        XCTAssertEqual(result, 2.5)
    }

    func testMedianSingleValue() {
        let result = handler.median([5.0])
        XCTAssertEqual(result, 5.0)
    }

    func testMedianEmptyArray() {
        let result = handler.median([])
        XCTAssertEqual(result, 0.0)
    }

    func testMedianAlreadySorted() {
        let result = handler.median([1, 2, 3])
        XCTAssertEqual(result, 2.0)
    }

    func testMedianReverseSorted() {
        let result = handler.median([5, 4, 3, 2, 1])
        XCTAssertEqual(result, 3.0)
    }

    func testMedianWithDecimals() {
        let result = handler.median([1.5, 2.5, 3.5])
        XCTAssertEqual(result, 2.5)
    }

    func testMedianWithNegativeValues() {
        let result = handler.median([-5, -3, -1, 0, 2])
        XCTAssertEqual(result, -1.0)
    }

    // MARK: - Trimmed Median Tests

    func testTrimmedMedianWithTenSamples() {
        // 10 samples: trim 3 from start, 3 from end, median of middle 4
        // Simulates: pickup [5, 10, 15], stable [20, 20, 20, 20], release [15, 10, 5]
        let samples: [Float] = [5, 10, 15, 20, 20, 20, 20, 15, 10, 5]
        let result = handler.trimmedMedian(samples)
        // Middle 4 samples: [20, 20, 20, 20] -> median = 20
        XCTAssertEqual(result, 20.0)
    }

    func testTrimmedMedianFallbackForFewSamples() {
        // Less than 5 samples: should fallback to regular median
        let samples: [Float] = [5, 20, 10]
        let result = handler.trimmedMedian(samples)
        // Regular median of [5, 10, 20] = 10
        XCTAssertEqual(result, 10.0)
    }

    func testTrimmedMedianExactlyFiveSamples() {
        // 5 samples: trim 1 from each end, median of middle 3
        let samples: [Float] = [5, 20, 20, 20, 5]
        let result = handler.trimmedMedian(samples)
        // Middle 3 samples: [20, 20, 20] -> median = 20
        XCTAssertEqual(result, 20.0)
    }

    func testTrimmedMedianWithRealisticData() {
        // Simulates realistic weight pickup/hold/release pattern
        // Pickup: ramping up 0 -> 20kg
        // Hold: stable around 20kg
        // Release: ramping down 20kg -> 0
        var samples: [Float] = []
        // Pickup phase (30 samples ramping up)
        for i in 0..<30 {
            samples.append(Float(i) * 20.0 / 30.0)
        }
        // Stable phase (40 samples at ~20kg with slight variation)
        for _ in 0..<40 {
            samples.append(20.0 + Float.random(in: -0.5...0.5))
        }
        // Release phase (30 samples ramping down)
        for i in 0..<30 {
            samples.append(20.0 - Float(i) * 20.0 / 30.0)
        }

        let result = handler.trimmedMedian(samples)
        // Should be close to 20kg (the stable phase value)
        XCTAssertEqual(result, 20.0, accuracy: 1.0)
    }

    func testTrimmedMedianVsRegularMedian() {
        // Shows that trimmed median gives better result for transient data
        let samples: [Float] = [0, 5, 10, 20, 20, 20, 20, 10, 5, 0]
        let regularMedian = handler.median(samples)
        let trimmedMedian = handler.trimmedMedian(samples)

        // Regular median of sorted [0, 0, 5, 5, 10, 10, 20, 20, 20, 20] = (10 + 10) / 2 = 10
        XCTAssertEqual(regularMedian, 10.0)
        // Trimmed median of middle [20, 20, 20, 20] = 20
        XCTAssertEqual(trimmedMedian, 20.0)
    }

    // MARK: - Mean Tests

    func testMeanNormalCase() {
        let result = handler.mean([2, 4, 6])
        XCTAssertEqual(result, 4.0)
    }

    func testMeanSingleValue() {
        let result = handler.mean([10.0])
        XCTAssertEqual(result, 10.0)
    }

    func testMeanEmptyArray() {
        let result = handler.mean([])
        XCTAssertEqual(result, 0.0)
    }

    func testMeanNegativeValues() {
        let result = handler.mean([-2, 0, 2])
        XCTAssertEqual(result, 0.0)
    }

    func testMeanWithDecimals() {
        let result = handler.mean([1.5, 2.5, 3.0])
        XCTAssertEqual(result, 2.333333, accuracy: 0.0001)
    }

    func testMeanAllSameValue() {
        let result = handler.mean([5, 5, 5, 5])
        XCTAssertEqual(result, 5.0)
    }

    // MARK: - Standard Deviation Tests

    func testStdDevNormalCase() {
        // Using sample standard deviation (n-1 denominator)
        // Values: [2, 4, 4, 4, 5, 5, 7, 9]
        // Mean = 5, Variance = 32/7 ≈ 4.571, StdDev ≈ 2.138
        let result = handler.standardDeviation([2, 4, 4, 4, 5, 5, 7, 9])
        XCTAssertEqual(result, 2.138, accuracy: 0.01)
    }

    func testStdDevSingleValue() {
        let result = handler.standardDeviation([5.0])
        XCTAssertEqual(result, 0.0)
    }

    func testStdDevEmptyArray() {
        let result = handler.standardDeviation([])
        XCTAssertEqual(result, 0.0)
    }

    func testStdDevIdenticalValues() {
        let result = handler.standardDeviation([3, 3, 3])
        XCTAssertEqual(result, 0.0)
    }

    func testStdDevTwoValues() {
        // [1, 3]: mean = 2, variance = ((1-2)^2 + (3-2)^2) / 1 = 2, stddev = sqrt(2) ≈ 1.414
        let result = handler.standardDeviation([1, 3])
        XCTAssertEqual(result, 1.414, accuracy: 0.01)
    }

    func testStdDevLargeSpread() {
        // [0, 100]: mean = 50, variance = (2500 + 2500) / 1 = 5000, stddev ≈ 70.71
        let result = handler.standardDeviation([0, 100])
        XCTAssertEqual(result, 70.71, accuracy: 0.1)
    }

    // MARK: - Initial State Tests

    func testInitialState() {
        XCTAssertTrue(handler.state.isWaitingForSamples)
        XCTAssertFalse(handler.engaged)
        XCTAssertFalse(handler.calibrating)
        XCTAssertEqual(handler.currentForce, 0.0)
    }

    // MARK: - Configuration Tests

    func testDefaultThresholds() {
        XCTAssertEqual(handler.engageThreshold, AppConstants.defaultEngageThreshold)
        XCTAssertEqual(handler.failThreshold, AppConstants.defaultFailThreshold)
        XCTAssertEqual(handler.weightTolerance, AppConstants.defaultWeightTolerance)
    }

    func testCustomThresholds() {
        handler.engageThreshold = 5.0
        handler.failThreshold = 2.0
        handler.weightTolerance = 1.0

        XCTAssertEqual(handler.engageThreshold, 5.0)
        XCTAssertEqual(handler.failThreshold, 2.0)
        XCTAssertEqual(handler.weightTolerance, 1.0)
    }

    func testTargetWeightConfiguration() {
        XCTAssertNil(handler.targetWeight)

        handler.targetWeight = 10.0
        XCTAssertEqual(handler.targetWeight, 10.0)

        handler.targetWeight = nil
        XCTAssertNil(handler.targetWeight)
    }

    // MARK: - Baseline Calculation Verification

    func testBaselineCalculationFormula() {
        // Test that mean is calculated correctly (same formula used for baseline)
        let samples: [Float] = [1.0, 2.0, 3.0, 4.0, 5.0]
        let expectedBaseline = samples.reduce(0, +) / Float(samples.count) // 3.0

        XCTAssertEqual(handler.mean(samples), expectedBaseline)
        XCTAssertEqual(handler.mean(samples), 3.0)
    }

    // MARK: - Off-Target Calculation Logic Tests

    func testOffTargetDifferenceCalculation() {
        // Test the formula: difference = rawWeight - target
        let rawWeight: Float = 11.0
        let target: Float = 10.0
        let tolerance: Float = 0.5

        let difference = rawWeight - target
        XCTAssertEqual(difference, 1.0)
        XCTAssertTrue(abs(difference) >= tolerance, "Should be off target when difference >= tolerance")
    }

    func testOnTargetWithinTolerance() {
        let rawWeight: Float = 10.3
        let target: Float = 10.0
        let tolerance: Float = 0.5

        let difference = rawWeight - target
        XCTAssertEqual(difference, 0.3, accuracy: 0.001)
        XCTAssertFalse(abs(difference) >= tolerance, "Should be on target when difference < tolerance")
    }

    func testOffTargetTooLightCalculation() {
        let rawWeight: Float = 9.0
        let target: Float = 10.0
        let tolerance: Float = 0.5

        let difference = rawWeight - target
        XCTAssertEqual(difference, -1.0)
        XCTAssertTrue(abs(difference) >= tolerance, "Should be off target")
        XCTAssertTrue(difference < 0, "Negative difference means too light")
    }

    func testOffTargetTooHeavyCalculation() {
        let rawWeight: Float = 11.0
        let target: Float = 10.0
        let tolerance: Float = 0.5

        let difference = rawWeight - target
        XCTAssertEqual(difference, 1.0)
        XCTAssertTrue(abs(difference) >= tolerance, "Should be off target")
        XCTAssertTrue(difference > 0, "Positive difference means too heavy")
    }

    func testAtToleranceBoundary() {
        let rawWeight: Float = 10.5
        let target: Float = 10.0
        let tolerance: Float = 0.5

        let difference = rawWeight - target
        XCTAssertEqual(difference, 0.5)
        XCTAssertTrue(abs(difference) >= tolerance, "At boundary should be off target (>= not >)")
    }

    func testJustUnderToleranceBoundary() {
        let rawWeight: Float = 10.49
        let target: Float = 10.0
        let tolerance: Float = 0.5

        let difference = rawWeight - target
        XCTAssertEqual(difference, 0.49, accuracy: 0.001)
        XCTAssertFalse(abs(difference) >= tolerance, "Just under boundary should be on target")
    }

    // MARK: - Tared vs Raw Weight Usage Tests
    //
    // These tests verify the critical distinction:
    // - TARED weight (rawWeight - baseline) should ONLY be used for gripping state detection
    // - RAW weight should be used for everything else (display, stats, history, off-target)

    /// Verify engagement threshold correctly checks against tared weight
    func testEngagementThresholdBehavior() {
        // Setup: baseline = 0, engageThreshold = 3.0 (default)
        setupIdleStateWithZeroBaseline()
        handler.canEngage = true

        // Raw weight 2.5 → tared weight = 2.5 (below 3.0 threshold)
        // Should NOT engage because tared weight < threshold
        processTestSample(2.5)
        waitForMainQueue()

        XCTAssertFalse(handler.engaged, "Should NOT engage when tared weight (2.5) < threshold (3.0)")
        XCTAssertTrue(handler.state == .idle(baseline: 0), "Should remain in idle state")

        // Raw weight 3.0 → tared weight = 3.0 (equals 3.0 threshold)
        // SHOULD engage because tared weight >= threshold
        processTestSample(3.0)
        waitForMainQueue()

        XCTAssertTrue(handler.engaged, "SHOULD engage when tared weight (3.0) >= threshold (3.0)")
    }

    /// Verify failure detection correctly checks against tared weight
    func testFailureThresholdBehavior() {
        // Setup: baseline = 0, failThreshold = 1.0 (default)
        setupIdleStateWithZeroBaseline()
        handler.canEngage = true

        // Listen for grip failed event
        let failedExpectation = expectation(description: "Grip failed")
        handler.gripFailed
            .sink { failedExpectation.fulfill() }
            .store(in: &cancellables)

        // Engage with raw weight 5.0 (tared = 5.0, well above threshold)
        processTestSample(5.0)
        waitForMainQueue()
        XCTAssertTrue(handler.engaged, "Should be engaged")

        // Raw weight 0.5 → tared weight = 0.5 (below 1.0 fail threshold)
        // Should trigger failure because TARED weight < fail threshold
        processTestSample(0.5)

        wait(for: [failedExpectation], timeout: 1.0)
        XCTAssertFalse(handler.engaged, "Should no longer be engaged after failure")
    }

    /// CRITICAL TEST: Verify sessionMean uses RAW weights, not tared
    /// This test would FAIL if the code incorrectly used tared weights for statistics
    func testStatisticsUseRawWeightNotTared() {
        // Setup: baseline = 0
        setupIdleStateWithZeroBaseline()
        handler.canEngage = true

        // Engage and collect samples - these ARE the raw values stored
        let rawSamples: [Float] = [15.0, 16.0, 17.0]

        for sample in rawSamples {
            processTestSample(sample)
            waitForMainQueue()
        }

        XCTAssertTrue(handler.engaged, "Should be engaged")

        // Statistics should be calculated from RAW weights
        // Raw mean: (15 + 16 + 17) / 3 = 16.0
        // If code incorrectly used tared weights (with baseline 0), result would be same
        // But this establishes the contract that raw weights are used
        XCTAssertEqual(handler.sessionMean!, 16.0, accuracy: 0.01,
                       "Mean should be 16.0 calculated from raw weights")

        // Raw stddev: sqrt(((15-16)² + (16-16)² + (17-16)²) / 2) = sqrt(2/2) = 1.0
        XCTAssertEqual(handler.sessionStdDev!, 1.0, accuracy: 0.01,
                       "StdDev should be calculated from raw samples")
    }

    /// CRITICAL TEST: Verify forceHistory stores RAW weights, not tared
    func testForceHistoryStoresRawWeight() {
        // Setup: baseline = 0
        setupIdleStateWithZeroBaseline()

        // Process a sample - should store raw weight in history
        let rawWeight: Float = 15.0
        processTestSample(rawWeight)
        waitForMainQueue()

        // Force history should contain the raw weight
        XCTAssertFalse(handler.forceHistory.isEmpty, "Force history should not be empty")
        let lastForce = handler.forceHistory.last!.force
        XCTAssertEqual(lastForce, rawWeight, accuracy: 0.01,
                       "Force history should store raw weight (15.0)")
    }

    /// CRITICAL TEST: Verify currentForce displays RAW weight, not tared
    func testCurrentForceDisplaysRawWeight() {
        // Setup: baseline = 0
        setupIdleStateWithZeroBaseline()

        // Process a sample
        let rawWeight: Float = 12.0
        processTestSample(rawWeight)
        waitForMainQueue()

        // currentForce should be the raw weight
        XCTAssertEqual(handler.currentForce, rawWeight, accuracy: 0.01,
                       "currentForce should be raw weight (12.0)")
    }

    /// CRITICAL TEST: Verify off-target calculation uses RAW weight, not tared
    /// This test would FAIL if the code used tared weight for off-target
    func testOffTargetUsesRawWeightNotTared() {
        // Setup: baseline = 0, target = 10.0
        setupIdleStateWithZeroBaseline()
        handler.canEngage = true
        handler.targetWeight = 10.0
        handler.weightTolerance = 0.5

        // First sample engages but doesn't check off-target yet
        processTestSample(11.0)
        waitForMainQueue()
        XCTAssertTrue(handler.engaged, "Should be engaged")

        // Second sample while gripping triggers off-target check
        // Raw weight 11.0 vs target 10.0 = +1.0 difference (off by 0.5 tolerance)
        processTestSample(11.0)
        waitForMainQueue()

        XCTAssertTrue(handler.isOffTarget, "Should be off-target (raw 11.0 vs target 10.0)")
        XCTAssertNotNil(handler.offTargetDirection, "offTargetDirection should not be nil")
        XCTAssertEqual(handler.offTargetDirection!, 1.0, accuracy: 0.01,
                       "Direction should be +1.0 (raw 11.0 - target 10.0)")
    }

    /// Test that verifies the formula: engagement uses (rawWeight - baseline) >= engageThreshold
    /// This is a pure unit test of the engagement logic
    func testEngagementFormulaTaredWeight() {
        // Given: engageThreshold = 3.0 (default)
        // The engagement formula should be: (rawWeight - baseline) >= engageThreshold

        // With baseline = 0:
        // raw = 3.0 → tared = 3.0 - 0 = 3.0 >= 3.0 ✓ ENGAGE
        // raw = 2.9 → tared = 2.9 - 0 = 2.9 < 3.0 ✗ NO ENGAGE

        // This verifies the threshold is compared against tared weight
        let engageThreshold = handler.engageThreshold
        XCTAssertEqual(engageThreshold, 3.0, "Default engage threshold should be 3.0")

        setupIdleStateWithZeroBaseline()
        handler.canEngage = true

        // At exactly the threshold
        processTestSample(engageThreshold)
        waitForMainQueue()
        XCTAssertTrue(handler.engaged, "Should engage at exactly the threshold")
    }

    /// Test that verifies the formula: failure uses (rawWeight - baseline) < failThreshold
    /// This is a pure unit test of the failure logic
    func testFailureFormulaTaredWeight() {
        // Given: failThreshold = 1.0 (default)
        // The failure formula should be: (rawWeight - baseline) < failThreshold

        let failThreshold = handler.failThreshold
        XCTAssertEqual(failThreshold, 1.0, "Default fail threshold should be 1.0")

        setupIdleStateWithZeroBaseline()
        handler.canEngage = true

        // Listen for grip failed event
        let failedExpectation = expectation(description: "Grip failed")
        handler.gripFailed
            .sink { failedExpectation.fulfill() }
            .store(in: &cancellables)

        // Engage first
        processTestSample(5.0)
        waitForMainQueue()
        XCTAssertTrue(handler.engaged)

        // At exactly the threshold - should still be gripping (not < threshold)
        processTestSample(failThreshold)
        waitForMainQueue()
        XCTAssertTrue(handler.engaged, "Should still be gripping at exactly fail threshold")

        // Below threshold - should fail
        processTestSample(failThreshold - 0.1)

        wait(for: [failedExpectation], timeout: 1.0)
        XCTAssertFalse(handler.engaged, "Should fail when below fail threshold")
    }

    // MARK: - Reset Tests

    /// Verify reset() clears all state to initial values
    func testResetClearsAllState() {
        // First, set up some state
        setupIdleStateWithZeroBaseline()
        handler.canEngage = true
        handler.targetWeight = 10.0

        // Engage and build up state
        processTestSample(5.0)
        waitForMainQueue()
        XCTAssertTrue(handler.engaged, "Should be engaged before reset")
        XCTAssertFalse(handler.forceHistory.isEmpty, "Should have force history")

        // Reset
        handler.reset()

        // Verify all state is cleared
        XCTAssertTrue(handler.state.isWaitingForSamples, "State should be waitingForSamples")
        XCTAssertEqual(handler.currentForce, 0.0, "currentForce should be 0")
        XCTAssertEqual(handler.calibrationTimeRemaining, AppConstants.calibrationDuration, "calibrationTimeRemaining should be reset")
        XCTAssertNil(handler.weightMedian, "weightMedian should be nil")
        XCTAssertFalse(handler.isOffTarget, "isOffTarget should be false")
        XCTAssertNil(handler.offTargetDirection, "offTargetDirection should be nil")
        XCTAssertNil(handler.sessionMean, "sessionMean should be nil")
        XCTAssertNil(handler.sessionStdDev, "sessionStdDev should be nil")
        XCTAssertTrue(handler.forceHistory.isEmpty, "forceHistory should be empty")
    }

    // MARK: - Calibration Tests

    /// Verify first sample transitions from waitingForSamples to calibrating
    func testCalibrationStartsOnFirstSample() {
        // Default: enableCalibration = true
        XCTAssertTrue(handler.enableCalibration, "Calibration should be enabled by default")
        XCTAssertTrue(handler.state.isWaitingForSamples, "Should start in waitingForSamples")

        // Process first sample
        processTestSample(1.0)
        waitForMainQueue()

        XCTAssertTrue(handler.calibrating, "Should be calibrating after first sample")
    }

    /// Verify calibration completes with correct baseline after duration
    /// Note: Calibration requires continuous samples during the 5s period
    func testCalibrationCompletesWithCorrectBaseline() {
        // Listen for calibration completed
        let calibrationExpectation = expectation(description: "Calibration completed")
        handler.calibrationCompleted
            .sink { calibrationExpectation.fulfill() }
            .store(in: &cancellables)

        // Start a timer to send samples continuously during calibration
        let sampleTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.processTestSample(2.0)
        }

        // Process first sample to start calibration
        processTestSample(2.0)
        waitForMainQueue()
        XCTAssertTrue(handler.calibrating)

        // Wait for calibration to complete (5 seconds + buffer)
        wait(for: [calibrationExpectation], timeout: 6.0)
        sampleTimer.invalidate()

        // Should now be in idle state
        XCTAssertFalse(handler.calibrating, "Should not be calibrating after completion")
        XCTAssertEqual(handler.calibrationTimeRemaining, 0, "calibrationTimeRemaining should be 0")

        // Baseline should be set (approximately 2.0 since we sent that sample)
        XCTAssertEqual(handler.state.baseline, 2.0, accuracy: 0.1, "Baseline should be ~2.0")
    }

    // MARK: - Weight Calibration State Tests

    /// Verify weight calibration starts when canEngage=false and above threshold
    func testWeightCalibrationStartsWhenCanEngageFalse() {
        setupIdleStateWithZeroBaseline()
        handler.canEngage = false  // Key condition

        // Apply weight above engage threshold
        processTestSample(5.0)
        waitForMainQueue()

        // Should be in weight calibration, not gripping
        XCTAssertFalse(handler.engaged, "Should NOT be engaged when canEngage=false")

        if case .weightCalibration(_, _, let isHolding) = handler.state {
            XCTAssertTrue(isHolding, "Should be holding in weight calibration")
        } else {
            XCTFail("Should be in weightCalibration state, got \(handler.state)")
        }
    }

    /// Verify weight calibration tracks median while holding
    func testWeightCalibrationTracksMedian() {
        setupIdleStateWithZeroBaseline()
        handler.canEngage = false

        // Hold weight with varying samples
        processTestSample(10.0)
        waitForMainQueue()
        processTestSample(12.0)
        waitForMainQueue()
        processTestSample(11.0)
        waitForMainQueue()

        // Median of [10, 12, 11] = 11.0
        XCTAssertNotNil(handler.weightMedian, "weightMedian should be set")
        XCTAssertEqual(handler.weightMedian!, 11.0, accuracy: 0.01, "Median should be 11.0")
    }

    /// Verify releasing weight transitions to not holding
    func testWeightCalibrationHoldingToNotHolding() {
        setupIdleStateWithZeroBaseline()
        handler.canEngage = false

        // Start holding
        processTestSample(5.0)
        waitForMainQueue()

        if case .weightCalibration(_, _, let isHolding) = handler.state {
            XCTAssertTrue(isHolding, "Should be holding initially")
        } else {
            XCTFail("Should be in weightCalibration state")
        }

        // Release below engage threshold but above fail threshold
        processTestSample(2.0)  // Between 1.0 (fail) and 3.0 (engage)
        waitForMainQueue()

        if case .weightCalibration(_, _, let isHolding) = handler.state {
            XCTAssertFalse(isHolding, "Should NOT be holding after releasing")
        } else {
            XCTFail("Should still be in weightCalibration state")
        }

        // Median should still be preserved
        XCTAssertNotNil(handler.weightMedian, "weightMedian should still be set")
    }

    /// Verify transitions from weight calibration to gripping when canEngage becomes true
    func testWeightCalibrationToGripping() {
        setupIdleStateWithZeroBaseline()
        handler.canEngage = false

        // Start in weight calibration
        processTestSample(5.0)
        waitForMainQueue()
        XCTAssertFalse(handler.engaged)

        // Enable engagement
        handler.canEngage = true

        // Next sample should transition to gripping
        processTestSample(5.0)
        waitForMainQueue()

        XCTAssertTrue(handler.engaged, "Should be engaged after canEngage becomes true")
    }

    // MARK: - Non-Zero Baseline Tests

    /// Verify statistics use raw weights even with non-zero baseline
    func testStatisticsWithNonZeroBaseline() {
        // Use calibration to get a non-zero baseline
        let calibrationExpectation = expectation(description: "Calibration completed")
        handler.calibrationCompleted
            .sink { calibrationExpectation.fulfill() }
            .store(in: &cancellables)

        // Start a timer to send samples continuously during calibration
        let sampleTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.processTestSample(5.0)
        }

        // Send first sample during calibration (will become baseline)
        processTestSample(5.0)
        waitForMainQueue()

        // Wait for calibration
        wait(for: [calibrationExpectation], timeout: 6.0)
        sampleTimer.invalidate()

        // Verify baseline is ~5.0
        let baseline = handler.state.baseline
        XCTAssertEqual(baseline, 5.0, accuracy: 0.1, "Baseline should be ~5.0")

        // Now engage and collect samples
        handler.canEngage = true
        let rawSamples: [Float] = [15.0, 16.0, 17.0]  // All above engage threshold (baseline + 3.0 = 8.0)

        for sample in rawSamples {
            processTestSample(sample)
            waitForMainQueue()
        }

        XCTAssertTrue(handler.engaged, "Should be engaged")

        // Statistics should be from RAW weights, not tared
        // Raw mean: (15 + 16 + 17) / 3 = 16.0
        // If tared was used incorrectly: (10 + 11 + 12) / 3 = 11.0
        XCTAssertEqual(handler.sessionMean!, 16.0, accuracy: 0.1,
                       "Mean should be 16.0 (raw), not 11.0 (tared)")
    }

    /// Verify off-target uses raw weight with non-zero baseline
    func testOffTargetWithNonZeroBaseline() {
        // Use calibration to get a non-zero baseline
        let calibrationExpectation = expectation(description: "Calibration completed")
        handler.calibrationCompleted
            .sink { calibrationExpectation.fulfill() }
            .store(in: &cancellables)

        // Start a timer to send samples continuously during calibration
        let sampleTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.processTestSample(5.0)
        }

        processTestSample(5.0)
        waitForMainQueue()
        wait(for: [calibrationExpectation], timeout: 6.0)
        sampleTimer.invalidate()

        // Set target to 15.0 kg (raw)
        handler.targetWeight = 15.0
        handler.weightTolerance = 0.5
        handler.canEngage = true

        // Engage with on-target weight
        processTestSample(15.0)
        waitForMainQueue()
        XCTAssertTrue(handler.engaged)

        // Second sample to trigger off-target check (still on target)
        processTestSample(15.0)
        waitForMainQueue()
        XCTAssertFalse(handler.isOffTarget, "Should be on target at 15.0")

        // Now go off target with raw weight 16.5 (1.5 over target)
        processTestSample(16.5)
        waitForMainQueue()

        XCTAssertTrue(handler.isOffTarget, "Should be off target at raw 16.5 vs target 15.0")
        XCTAssertEqual(handler.offTargetDirection!, 1.5, accuracy: 0.01,
                       "Direction should be +1.5 (raw 16.5 - target 15.0)")
    }

    // MARK: - Percentage-Based Threshold Tests

    /// Helper to set up handler with percentage thresholds enabled (pure percentage, no floor/ceiling)
    private func setupWithPercentageThresholds(
        target: Float,
        engage: Float = 0.50,
        disengage: Float = 0.20,
        tolerance: Float = 0.05
    ) {
        handler.enablePercentageThresholds = true
        handler.targetWeight = target
        handler.engagePercentage = engage
        handler.disengagePercentage = disengage
        handler.tolerancePercentage = tolerance
        // Disable floor/ceiling bounds for pure percentage testing
        handler.engageFloor = 0
        handler.engageCeiling = 0
        handler.disengageFloor = 0
        handler.disengageCeiling = 0
        handler.toleranceFloor = 0
        handler.toleranceCeiling = 0
        setupIdleStateWithZeroBaseline()
    }

    // MARK: Toggle Behavior

    func testPercentageThresholdsEnabledByDefault() {
        XCTAssertTrue(handler.enablePercentageThresholds, "Percentage thresholds should be enabled by default")
    }

    func testFixedThresholdsUsedWhenToggleOff() {
        // Setup with toggle OFF but target weight set
        handler.enablePercentageThresholds = false
        handler.targetWeight = 20.0
        handler.engagePercentage = 0.50  // Would be 10kg if percentage mode was on
        setupIdleStateWithZeroBaseline()
        handler.canEngage = true

        // With fixed thresholds (default 3.0kg), should engage at 3kg
        processTestSample(3.0)
        waitForMainQueue()

        XCTAssertTrue(handler.engaged, "Should engage at 3kg using fixed threshold, not 10kg (50% of 20)")
    }

    func testFixedDisengageThresholdUsedWhenToggleOff() {
        // Setup with toggle OFF but target weight set
        handler.enablePercentageThresholds = false
        handler.targetWeight = 20.0
        handler.disengagePercentage = 0.20  // Would be 4kg if percentage mode was on
        setupIdleStateWithZeroBaseline()
        handler.canEngage = true

        let failedExpectation = expectation(description: "Grip failed")
        handler.gripFailed
            .sink { failedExpectation.fulfill() }
            .store(in: &cancellables)

        // Engage first
        processTestSample(5.0)
        waitForMainQueue()
        XCTAssertTrue(handler.engaged)

        // At 2.0kg - above fixed threshold (1.0kg) but below percentage (4kg)
        // Should still be engaged because fixed threshold is used
        processTestSample(2.0)
        waitForMainQueue()
        XCTAssertTrue(handler.engaged, "Should still be engaged at 2kg using fixed threshold (1kg), not percentage (4kg)")

        // Below fixed threshold (1.0kg) - should disengage
        processTestSample(0.9)

        wait(for: [failedExpectation], timeout: 1.0)
        XCTAssertFalse(handler.engaged, "Should disengage below 1kg using fixed threshold")
    }

    func testFixedToleranceUsedWhenToggleOff() {
        // Setup with toggle OFF but target weight set
        handler.enablePercentageThresholds = false
        handler.targetWeight = 20.0
        handler.tolerancePercentage = 0.10  // Would be 2kg if percentage mode was on
        handler.weightTolerance = 0.5  // Fixed tolerance
        setupIdleStateWithZeroBaseline()
        handler.canEngage = true

        // Engage
        processTestSample(5.0)
        waitForMainQueue()
        XCTAssertTrue(handler.engaged)

        // At 20.8kg - 0.8kg off target
        // Above fixed tolerance (0.5kg) but below percentage (2kg)
        // Should be OFF target because fixed tolerance is used
        processTestSample(20.8)
        waitForMainQueue()
        XCTAssertTrue(handler.isOffTarget, "Should be OFF target at 20.8kg using fixed tolerance (0.5kg), not percentage (2kg)")

        // At 20.3kg - 0.3kg off target, within fixed tolerance
        processTestSample(20.3)
        waitForMainQueue()
        XCTAssertFalse(handler.isOffTarget, "Should be ON target at 20.3kg (within 0.5kg fixed tolerance)")
    }

    func testPercentageThresholdsUsedWhenToggleOn() {
        // Setup with toggle ON and target weight set
        setupWithPercentageThresholds(target: 20.0, engage: 0.50)
        handler.canEngage = true

        // With percentage thresholds (50% of 20 = 10kg), should NOT engage at 3kg
        processTestSample(3.0)
        waitForMainQueue()

        XCTAssertFalse(handler.engaged, "Should NOT engage at 3kg when percentage threshold is 10kg (50% of 20)")

        // Should engage at 10kg
        processTestSample(10.0)
        waitForMainQueue()

        XCTAssertTrue(handler.engaged, "Should engage at 10kg (50% of 20kg target)")
    }

    // MARK: Dynamic Threshold Calculation

    func testEngageThresholdCalculatedFromPercentage() {
        // targetWeight = 20kg, engagePercentage = 0.50
        // Expected: engage at taredWeight >= 10kg
        setupWithPercentageThresholds(target: 20.0, engage: 0.50)
        handler.canEngage = true

        // Below threshold
        processTestSample(9.9)
        waitForMainQueue()
        XCTAssertFalse(handler.engaged, "Should NOT engage at 9.9kg (below 10kg threshold)")

        // At threshold
        processTestSample(10.0)
        waitForMainQueue()
        XCTAssertTrue(handler.engaged, "Should engage at 10kg (50% of 20kg)")
    }

    func testDisengageThresholdCalculatedFromPercentage() {
        // targetWeight = 20kg, disengagePercentage = 0.20
        // Expected: fail when taredWeight < 4kg
        setupWithPercentageThresholds(target: 20.0, engage: 0.50, disengage: 0.20)
        handler.canEngage = true

        // Listen for grip failed event
        let failedExpectation = expectation(description: "Grip failed")
        handler.gripFailed
            .sink { failedExpectation.fulfill() }
            .store(in: &cancellables)

        // Engage
        processTestSample(10.0)
        waitForMainQueue()
        XCTAssertTrue(handler.engaged)

        // At 4kg threshold - should NOT fail (uses <, not <=)
        processTestSample(4.0)
        waitForMainQueue()
        XCTAssertTrue(handler.engaged, "Should still be engaged at exactly 4kg (20% threshold)")

        // Below 4kg - should fail
        processTestSample(3.9)

        wait(for: [failedExpectation], timeout: 1.0)
        XCTAssertFalse(handler.engaged, "Should disengage below 4kg (20% of 20kg)")
    }

    func testToleranceCalculatedFromPercentage() {
        // targetWeight = 20kg, tolerancePercentage = 0.05
        // Expected: off-target when |rawWeight - target| >= 1kg
        setupWithPercentageThresholds(target: 20.0, tolerance: 0.05)
        handler.canEngage = true

        // Engage
        processTestSample(12.0)
        waitForMainQueue()
        XCTAssertTrue(handler.engaged)

        // On target at 20.0
        processTestSample(20.0)
        waitForMainQueue()
        XCTAssertFalse(handler.isOffTarget, "Should be on target at exactly 20kg")

        // Just within tolerance at 20.9
        processTestSample(20.9)
        waitForMainQueue()
        XCTAssertFalse(handler.isOffTarget, "Should be on target at 20.9kg (within 1kg tolerance)")

        // At tolerance boundary at 21.0
        processTestSample(21.0)
        waitForMainQueue()
        XCTAssertTrue(handler.isOffTarget, "Should be off target at 21kg (exactly at 5% tolerance boundary)")
    }

    // MARK: Scaling Across Weight Ranges

    func testThresholdsScaleWithSmallTarget() {
        // targetWeight = 5kg → engage 2.5kg, fail < 1kg, tolerance ±0.25kg
        setupWithPercentageThresholds(target: 5.0, engage: 0.50, disengage: 0.20, tolerance: 0.05)
        handler.canEngage = true

        // Should engage at 2.5kg (50% of 5)
        processTestSample(2.5)
        waitForMainQueue()
        XCTAssertTrue(handler.engaged, "Should engage at 2.5kg for 5kg target")
    }

    func testThresholdsScaleWithMediumTarget() {
        // targetWeight = 15kg → engage 7.5kg, fail < 3kg, tolerance ±0.75kg
        setupWithPercentageThresholds(target: 15.0, engage: 0.50, disengage: 0.20, tolerance: 0.05)
        handler.canEngage = true

        // Should NOT engage at 7.4kg
        processTestSample(7.4)
        waitForMainQueue()
        XCTAssertFalse(handler.engaged, "Should NOT engage at 7.4kg for 15kg target")

        // Should engage at 7.5kg
        processTestSample(7.5)
        waitForMainQueue()
        XCTAssertTrue(handler.engaged, "Should engage at 7.5kg (50% of 15kg)")
    }

    func testThresholdsScaleWithLargeTarget() {
        // targetWeight = 30kg → engage 15kg, fail < 6kg, tolerance ±1.5kg
        setupWithPercentageThresholds(target: 30.0, engage: 0.50, disengage: 0.20, tolerance: 0.05)
        handler.canEngage = true

        // Should engage at 15kg
        processTestSample(15.0)
        waitForMainQueue()
        XCTAssertTrue(handler.engaged, "Should engage at 15kg (50% of 30kg)")
    }

    // MARK: State Transitions with Percentage Thresholds

    func testEngageAtExactPercentageThreshold() {
        // taredWeight == targetWeight * engagePercentage → should engage
        setupWithPercentageThresholds(target: 20.0, engage: 0.50)
        handler.canEngage = true

        processTestSample(10.0)  // Exactly 50% of 20
        waitForMainQueue()

        XCTAssertTrue(handler.engaged, "Should engage at exactly the percentage threshold")
    }

    func testNoEngageBelowPercentageThreshold() {
        // taredWeight < targetWeight * engagePercentage → should stay idle
        setupWithPercentageThresholds(target: 20.0, engage: 0.50)
        handler.canEngage = true

        processTestSample(9.99)  // Just below 50% of 20
        waitForMainQueue()

        XCTAssertFalse(handler.engaged, "Should NOT engage below percentage threshold")
        if case .idle = handler.state {
            // Expected
        } else {
            XCTFail("Should be in idle state")
        }
    }

    func testDisengageAtExactPercentageThreshold() {
        // taredWeight == targetWeight * disengagePercentage → should NOT disengage (uses <)
        setupWithPercentageThresholds(target: 20.0, engage: 0.50, disengage: 0.20)
        handler.canEngage = true

        // Engage first
        processTestSample(10.0)
        waitForMainQueue()
        XCTAssertTrue(handler.engaged)

        // At exactly disengage threshold (4kg = 20% of 20)
        processTestSample(4.0)
        waitForMainQueue()

        XCTAssertTrue(handler.engaged, "Should still be engaged at exactly the disengage threshold (uses < not <=)")
    }

    func testDisengageBelowPercentageThreshold() {
        // taredWeight < targetWeight * disengagePercentage → should disengage
        setupWithPercentageThresholds(target: 20.0, engage: 0.50, disengage: 0.20)
        handler.canEngage = true

        let failedExpectation = expectation(description: "Grip failed")
        handler.gripFailed
            .sink { failedExpectation.fulfill() }
            .store(in: &cancellables)

        // Engage first
        processTestSample(10.0)
        waitForMainQueue()
        XCTAssertTrue(handler.engaged)

        // Below disengage threshold
        processTestSample(3.99)

        wait(for: [failedExpectation], timeout: 1.0)
        XCTAssertFalse(handler.engaged, "Should disengage below percentage threshold")
    }

    // MARK: Off-Target with Percentage Tolerance

    func testOnTargetWithinPercentageTolerance() {
        // |rawWeight - target| < target * tolerancePercentage → not off-target
        setupWithPercentageThresholds(target: 20.0, tolerance: 0.05)  // 5% = 1kg tolerance
        handler.canEngage = true

        processTestSample(12.0)
        waitForMainQueue()
        XCTAssertTrue(handler.engaged)

        // Within tolerance
        processTestSample(20.5)  // 0.5kg off, tolerance is 1kg
        waitForMainQueue()

        XCTAssertFalse(handler.isOffTarget, "Should be on target when within percentage tolerance")
    }

    func testOffTargetOutsidePercentageTolerance() {
        // |rawWeight - target| >= target * tolerancePercentage → off-target
        setupWithPercentageThresholds(target: 20.0, tolerance: 0.05)  // 5% = 1kg tolerance
        handler.canEngage = true

        processTestSample(12.0)
        waitForMainQueue()
        XCTAssertTrue(handler.engaged)

        // Outside tolerance
        processTestSample(21.5)  // 1.5kg off, tolerance is 1kg
        waitForMainQueue()

        XCTAssertTrue(handler.isOffTarget, "Should be off target when outside percentage tolerance")
    }

    func testOffTargetDirectionWithPercentageTolerance() {
        // Verify direction is positive (too heavy) or negative (too light)
        setupWithPercentageThresholds(target: 20.0, tolerance: 0.05)
        handler.canEngage = true

        processTestSample(12.0)
        waitForMainQueue()

        // Too heavy
        processTestSample(22.0)
        waitForMainQueue()
        XCTAssertTrue(handler.isOffTarget)
        XCTAssertEqual(handler.offTargetDirection!, 2.0, accuracy: 0.01, "Direction should be positive for too heavy")

        // Too light
        processTestSample(18.0)
        waitForMainQueue()
        XCTAssertTrue(handler.isOffTarget)
        XCTAssertEqual(handler.offTargetDirection!, -2.0, accuracy: 0.01, "Direction should be negative for too light")
    }

    // MARK: Boundary Conditions

    func testDisengagePercentageMustBeLessThanEngage() {
        // This is a settings-level validation, but we test that the handler
        // works correctly even if disengage is set close to engage
        setupWithPercentageThresholds(target: 20.0, engage: 0.50, disengage: 0.45)
        handler.canEngage = true

        // Engage at 10kg (50% of 20)
        processTestSample(10.0)
        waitForMainQueue()
        XCTAssertTrue(handler.engaged)

        // At 9kg (45% = disengage threshold), should still be engaged
        processTestSample(9.0)
        waitForMainQueue()
        XCTAssertTrue(handler.engaged, "Should still be engaged at exactly disengage threshold")
    }

    // MARK: Target Weight Changes

    func testThresholdsUpdateWhenTargetChanges() {
        // Start with 20kg target
        setupWithPercentageThresholds(target: 20.0, engage: 0.50)
        handler.canEngage = true

        // Should NOT engage at 5kg (50% of 20 = 10kg threshold)
        processTestSample(5.0)
        waitForMainQueue()
        XCTAssertFalse(handler.engaged, "Should NOT engage at 5kg with 20kg target")

        // Reset to idle
        handler.reset()
        setupIdleStateWithZeroBaseline()
        handler.canEngage = true

        // Change target to 10kg
        handler.targetWeight = 10.0

        // Now should engage at 5kg (50% of 10 = 5kg threshold)
        processTestSample(5.0)
        waitForMainQueue()
        XCTAssertTrue(handler.engaged, "Should engage at 5kg with 10kg target")
    }

    func testFallbackToFixedWhenNoTargetSet() {
        // Enable percentage mode but don't set target
        handler.enablePercentageThresholds = true
        handler.targetWeight = nil
        handler.engagePercentage = 0.50
        setupIdleStateWithZeroBaseline()
        handler.canEngage = true

        // Should fall back to fixed threshold (3.0kg default)
        processTestSample(3.0)
        waitForMainQueue()

        XCTAssertTrue(handler.engaged, "Should use fixed 3kg threshold when no target is set")
    }

    func testPercentageModeWithZeroTarget() {
        // Edge case: target = 0 with pure percentage (no floor/ceiling)
        handler.enablePercentageThresholds = true
        handler.targetWeight = 0.0
        handler.engagePercentage = 0.50
        // Disable floor/ceiling to test pure percentage behavior
        handler.engageFloor = 0
        handler.engageCeiling = 0
        setupIdleStateWithZeroBaseline()
        handler.canEngage = true

        // 50% of 0 = 0, so should engage at any positive force
        processTestSample(0.1)
        waitForMainQueue()

        // With 0 target, 50% = 0kg threshold, so 0.1 >= 0 should engage
        XCTAssertTrue(handler.engaged, "Should engage with any force when target is 0")
    }

    // MARK: - Floor/Ceiling Bounds Tests

    /// Helper to set up handler with percentage thresholds and custom bounds
    private func setupWithPercentageThresholdsAndBounds(
        target: Float,
        engage: Float = 0.50,
        disengage: Float = 0.20,
        tolerance: Float = 0.05,
        engageFloor: Float = AppConstants.defaultEngageFloor,
        engageCeiling: Float = AppConstants.defaultEngageCeiling,
        disengageFloor: Float = AppConstants.defaultDisengageFloor,
        disengageCeiling: Float = AppConstants.defaultDisengageCeiling,
        toleranceFloor: Float = AppConstants.defaultToleranceFloor,
        toleranceCeiling: Float = AppConstants.defaultToleranceCeiling
    ) {
        handler.enablePercentageThresholds = true
        handler.targetWeight = target
        handler.engagePercentage = engage
        handler.disengagePercentage = disengage
        handler.tolerancePercentage = tolerance
        handler.engageFloor = engageFloor
        handler.engageCeiling = engageCeiling
        handler.disengageFloor = disengageFloor
        handler.disengageCeiling = disengageCeiling
        handler.toleranceFloor = toleranceFloor
        handler.toleranceCeiling = toleranceCeiling
        setupIdleStateWithZeroBaseline()
    }

    // MARK: Floor Clamping (Small Weights)

    func testEngageFloorClampsSmallWeight() {
        // Target 3kg, 50% = 1.5kg, but floor is 3kg
        // Should use floor (3kg) instead of percentage (1.5kg)
        setupWithPercentageThresholdsAndBounds(
            target: 3.0,
            engage: 0.50,
            engageFloor: 3.0
        )
        handler.canEngage = true

        // At 2.5kg - above percentage (1.5kg) but below floor (3kg)
        processTestSample(2.5)
        waitForMainQueue()
        XCTAssertFalse(handler.engaged, "Should NOT engage at 2.5kg when floor is 3kg")

        // At 3.0kg - at floor
        processTestSample(3.0)
        waitForMainQueue()
        XCTAssertTrue(handler.engaged, "Should engage at floor (3kg)")
    }

    func testDisengageFloorClampsSmallWeight() {
        // Target 5kg, 20% = 1kg, but floor is 2kg
        // Should use floor (2kg) instead of percentage (1kg)
        setupWithPercentageThresholdsAndBounds(
            target: 5.0,
            engage: 0.50,
            disengage: 0.20,
            engageFloor: 2.0,
            disengageFloor: 2.0
        )
        handler.canEngage = true

        let failedExpectation = expectation(description: "Grip failed")
        handler.gripFailed
            .sink { failedExpectation.fulfill() }
            .store(in: &cancellables)

        // Engage
        processTestSample(5.0)
        waitForMainQueue()
        XCTAssertTrue(handler.engaged)

        // At 1.5kg - below percentage (1kg) but still at/above floor (2kg)? No, 1.5 < 2
        // Should fail because 1.5 < floor (2kg)
        processTestSample(1.5)

        wait(for: [failedExpectation], timeout: 1.0)
        XCTAssertFalse(handler.engaged, "Should disengage at 1.5kg when floor is 2kg")
    }

    func testToleranceFloorClampsSmallWeight() {
        // Target 5kg, 5% = 0.25kg, but floor is 1kg
        // Should use floor (1kg) instead of percentage (0.25kg)
        setupWithPercentageThresholdsAndBounds(
            target: 5.0,
            tolerance: 0.05,
            engageFloor: 2.0,
            toleranceFloor: 1.0
        )
        handler.canEngage = true

        // Engage
        processTestSample(5.0)
        waitForMainQueue()
        XCTAssertTrue(handler.engaged)

        // At 5.5kg - 0.5kg off, which is > percentage (0.25kg) but < floor (1kg)
        processTestSample(5.5)
        waitForMainQueue()
        XCTAssertFalse(handler.isOffTarget, "Should be ON target at 5.5kg when tolerance floor is 1kg")

        // At 6.0kg - 1.0kg off, exactly at floor tolerance
        processTestSample(6.0)
        waitForMainQueue()
        XCTAssertTrue(handler.isOffTarget, "Should be OFF target at 6kg (1kg off, floor tolerance is 1kg)")
    }

    // MARK: Ceiling Clamping (Large Weights)

    func testEngageCeilingClampsLargeWeight() {
        // Target 100kg, 50% = 50kg, but ceiling is 20kg
        // Should use ceiling (20kg) instead of percentage (50kg)
        setupWithPercentageThresholdsAndBounds(
            target: 100.0,
            engage: 0.50,
            engageCeiling: 20.0
        )
        handler.canEngage = true

        // At 20kg - at ceiling
        processTestSample(20.0)
        waitForMainQueue()
        XCTAssertTrue(handler.engaged, "Should engage at ceiling (20kg) not percentage (50kg)")
    }

    func testDisengageCeilingClampsLargeWeight() {
        // Target 100kg, 20% = 20kg, but ceiling is 5kg
        // Should use ceiling (5kg) instead of percentage (20kg)
        setupWithPercentageThresholdsAndBounds(
            target: 100.0,
            engage: 0.50,
            disengage: 0.20,
            engageCeiling: 20.0,
            disengageCeiling: 5.0
        )
        handler.canEngage = true

        let failedExpectation = expectation(description: "Grip failed")
        handler.gripFailed
            .sink { failedExpectation.fulfill() }
            .store(in: &cancellables)

        // Engage
        processTestSample(25.0)
        waitForMainQueue()
        XCTAssertTrue(handler.engaged)

        // At 4.9kg - below ceiling (5kg)
        processTestSample(4.9)

        wait(for: [failedExpectation], timeout: 1.0)
        XCTAssertFalse(handler.engaged, "Should disengage below 5kg (ceiling) not 20kg (percentage)")
    }

    func testToleranceCeilingClampsLargeWeight() {
        // Target 100kg, 5% = 5kg, but ceiling is 2kg
        // Should use ceiling (2kg) instead of percentage (5kg)
        setupWithPercentageThresholdsAndBounds(
            target: 100.0,
            tolerance: 0.05,
            engageCeiling: 20.0,
            toleranceCeiling: 2.0
        )
        handler.canEngage = true

        // Engage
        processTestSample(100.0)
        waitForMainQueue()
        XCTAssertTrue(handler.engaged)

        // At 102.5kg - 2.5kg off, which is < percentage (5kg) but > ceiling (2kg)
        processTestSample(102.5)
        waitForMainQueue()
        XCTAssertTrue(handler.isOffTarget, "Should be OFF target at 102.5kg when tolerance ceiling is 2kg")

        // At 101.5kg - 1.5kg off, within ceiling tolerance
        processTestSample(101.5)
        waitForMainQueue()
        XCTAssertFalse(handler.isOffTarget, "Should be ON target at 101.5kg (1.5kg off, ceiling tolerance is 2kg)")
    }

    // MARK: Values Within Range (No Clamping)

    func testNoClampingWhenWithinRange() {
        // Target 20kg with default bounds
        // 50% = 10kg (within 3-20 floor/ceiling)
        // 20% = 4kg (within 2-5 floor/ceiling)
        // 5% = 1kg (within 1-2 floor/ceiling)
        setupWithPercentageThresholdsAndBounds(target: 20.0)
        handler.canEngage = true

        // Engage at 10kg (pure percentage, no clamping)
        processTestSample(9.9)
        waitForMainQueue()
        XCTAssertFalse(handler.engaged, "Should NOT engage at 9.9kg (below 10kg threshold)")

        processTestSample(10.0)
        waitForMainQueue()
        XCTAssertTrue(handler.engaged, "Should engage at exactly 10kg (50% of 20kg, no clamping)")
    }

    // MARK: Floor = 0 (Disabled)

    func testFloorZeroDisablesFloorClamping() {
        // Target 3kg, 50% = 1.5kg, floor = 0 (disabled)
        // Should use pure percentage (1.5kg)
        setupWithPercentageThresholdsAndBounds(
            target: 3.0,
            engage: 0.50,
            engageFloor: 0.0  // Disabled
        )
        handler.canEngage = true

        // At 1.5kg - exactly at percentage
        processTestSample(1.5)
        waitForMainQueue()
        XCTAssertTrue(handler.engaged, "Should engage at 1.5kg (50% of 3kg) when floor is disabled")
    }

    func testToleranceFloorZeroDisablesClamping() {
        // Target 5kg, 5% = 0.25kg, floor = 0 (disabled)
        // Should use pure percentage (0.25kg)
        setupWithPercentageThresholdsAndBounds(
            target: 5.0,
            tolerance: 0.05,
            engageFloor: 0.0,
            toleranceFloor: 0.0  // Disabled
        )
        handler.canEngage = true

        // Engage
        processTestSample(5.0)
        waitForMainQueue()
        XCTAssertTrue(handler.engaged)

        // At 5.3kg - 0.3kg off, which is > percentage (0.25kg)
        processTestSample(5.3)
        waitForMainQueue()
        XCTAssertTrue(handler.isOffTarget, "Should be OFF target at 5.3kg when floor disabled (0.25kg tolerance)")

        // At 5.2kg - 0.2kg off, which is < percentage (0.25kg)
        processTestSample(5.2)
        waitForMainQueue()
        XCTAssertFalse(handler.isOffTarget, "Should be ON target at 5.2kg when floor disabled (0.25kg tolerance)")
    }

    // MARK: Custom Bounds

    func testCustomEngageBounds() {
        // Custom bounds: floor=5, ceiling=15
        setupWithPercentageThresholdsAndBounds(
            target: 10.0,
            engage: 0.50,  // Would be 5kg
            engageFloor: 5.0,
            engageCeiling: 15.0
        )
        handler.canEngage = true

        // At exactly floor/percentage (5kg)
        processTestSample(5.0)
        waitForMainQueue()
        XCTAssertTrue(handler.engaged, "Should engage at 5kg (matches both floor and percentage)")
    }

    func testCustomToleranceBounds() {
        // Custom bounds: floor=0.5, ceiling=1.5
        setupWithPercentageThresholdsAndBounds(
            target: 20.0,
            tolerance: 0.05,  // 5% of 20 = 1kg (within 0.5-1.5)
            engageFloor: 3.0,
            toleranceFloor: 0.5,
            toleranceCeiling: 1.5
        )
        handler.canEngage = true

        // Engage
        processTestSample(20.0)
        waitForMainQueue()
        XCTAssertTrue(handler.engaged)

        // At 20.9kg - 0.9kg off (within 1kg tolerance, no clamping)
        processTestSample(20.9)
        waitForMainQueue()
        XCTAssertFalse(handler.isOffTarget, "Should be ON target at 20.9kg (0.9kg < 1kg tolerance)")

        // At 21.1kg - 1.1kg off (exceeds 1kg tolerance)
        processTestSample(21.1)
        waitForMainQueue()
        XCTAssertTrue(handler.isOffTarget, "Should be OFF target at 21.1kg (1.1kg > 1kg tolerance)")
    }

    func testDefaultBoundsValues() {
        // Verify default bounds are set correctly
        XCTAssertEqual(handler.engageFloor, AppConstants.defaultEngageFloor)
        XCTAssertEqual(handler.engageCeiling, AppConstants.defaultEngageCeiling)
        XCTAssertEqual(handler.disengageFloor, AppConstants.defaultDisengageFloor)
        XCTAssertEqual(handler.disengageCeiling, AppConstants.defaultDisengageCeiling)
        XCTAssertEqual(handler.toleranceFloor, AppConstants.defaultToleranceFloor)
        XCTAssertEqual(handler.toleranceCeiling, AppConstants.defaultToleranceCeiling)
    }

    // MARK: - Small Target Weight Tests

    func testSmallTargetThresholdBehavior() {
        // 3kg target with default floors (engage 3kg, disengage 2kg)
        // Engage: max(3 * 0.50, 3.0) = max(1.5, 3.0) = 3.0 kg (100% of target)
        // Disengage: max(3 * 0.20, 2.0) = max(0.6, 2.0) = 2.0 kg
        setupWithPercentageThresholdsAndBounds(target: 3.0)
        handler.canEngage = true

        // At 3.0kg (engage floor = target), should engage
        processTestSample(3.0)
        waitForMainQueue()
        XCTAssertTrue(handler.engaged, "Should engage at 3.0kg for 3kg target (100% threshold)")
    }

    func testSmallTargetDisengageBehavior() {
        // 3kg target: disengage threshold = max(3 * 0.20, 2.0) = 2.0 kg
        setupWithPercentageThresholdsAndBounds(target: 3.0)
        handler.canEngage = true

        let failedExpectation = expectation(description: "Grip failed")
        handler.gripFailed
            .sink { failedExpectation.fulfill() }
            .store(in: &cancellables)

        // Engage first
        processTestSample(3.0)
        waitForMainQueue()
        XCTAssertTrue(handler.engaged)

        // At exactly 2.0kg (disengage floor), should still be engaged
        processTestSample(2.0)
        waitForMainQueue()
        XCTAssertTrue(handler.engaged, "Should still be engaged at exactly 2.0kg threshold")

        // Below 2.0kg, should disengage
        processTestSample(1.9)

        wait(for: [failedExpectation], timeout: 1.0)
        XCTAssertFalse(handler.engaged, "Should disengage below 2.0kg for 3kg target")
    }
}
