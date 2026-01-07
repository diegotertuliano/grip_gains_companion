import Foundation
import Combine

/// Tracks rep data across a set session
class RepTracker: ObservableObject {
    // MARK: - Published State

    @Published private(set) var currentSetReps: [RepResult] = []
    @Published private(set) var lastRepResult: RepResult?
    @Published private(set) var setStatistics: SetStatistics?

    // MARK: - Publishers

    /// Publisher for when a rep is completed
    let repCompleted = PassthroughSubject<RepResult, Never>()

    /// Publisher for when a set summary should be shown
    let showSetSummary = PassthroughSubject<SetStatistics, Never>()

    // MARK: - Session Context

    private var currentGripper: String?
    private var currentSide: String?

    // MARK: - Public Methods

    /// Record a completed rep
    func recordRep(
        duration: TimeInterval,
        samples: [Float],
        targetWeight: Float?
    ) {
        let rep = RepResult(
            timestamp: Date(),
            duration: duration,
            samples: samples,
            targetWeight: targetWeight
        )

        currentSetReps.append(rep)
        lastRepResult = rep
        repCompleted.send(rep)
    }

    /// Trigger set summary (called when "Save to Database" detected)
    func completeSet() {
        guard !currentSetReps.isEmpty else { return }
        let stats = SetStatistics(reps: currentSetReps)
        setStatistics = stats
        showSetSummary.send(stats)
    }

    /// Clear rep history for a new set
    func resetForNewSet() {
        currentSetReps = []
        lastRepResult = nil
        setStatistics = nil
    }

    /// Update session context (for detecting exercise changes)
    func updateSessionContext(gripper: String?, side: String?) {
        // If exercise changed, reset rep history
        if gripper != currentGripper || side != currentSide {
            resetForNewSet()
        }
        currentGripper = gripper
        currentSide = side
    }
}
