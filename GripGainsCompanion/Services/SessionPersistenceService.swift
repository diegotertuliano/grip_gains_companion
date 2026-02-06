import Foundation
import SwiftData
import Combine

/// Manages persistence of grip training sessions and reps using SwiftData
@MainActor
final class SessionPersistenceService: ObservableObject {
    private let modelContainer: ModelContainer
    private var modelContext: ModelContext { modelContainer.mainContext }

    /// Current active session (nil until first rep with valid gripper/side)
    @Published private(set) var currentSession: SessionLog?

    /// Whether the current session has been persisted to the database
    private var isSessionPersisted = false

    /// Tracking session context
    private var currentGripper: String?
    private var currentSide: String?

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        purgeDeletedSessions()
    }

    // MARK: - Session Management

    /// Update session context - creates new session if gripper or side changes
    func updateSessionContext(gripper: String?, side: String?) {
        // Only proceed if we have valid gripper and side
        guard let gripper = gripper, let side = side,
              !gripper.isEmpty, !side.isEmpty else {
            return
        }

        // Check if session context changed
        if gripper != currentGripper || side != currentSide {
            // Handle previous session - save to iCloud if it has reps
            if currentSession != nil && isSessionPersisted {
                saveCurrentSessionToICloud()
            }

            // Create new session (not persisted until first rep)
            let session = SessionLog(gripperType: gripper, side: side)
            currentSession = session
            isSessionPersisted = false

            currentGripper = gripper
            currentSide = side
        }
    }

    // MARK: - Rep Persistence

    /// Save a rep to the current session
    func saveRep(from repResult: RepResult) {
        guard let session = currentSession else {
            // No active session - cannot save rep
            return
        }

        // Persist session on first rep
        if !isSessionPersisted {
            modelContext.insert(session)
            isSessionPersisted = true
        }

        let repLog = RepLog(from: repResult, session: session)
        modelContext.insert(repLog)

        do {
            try modelContext.save()
        } catch {
            print("Failed to save rep: \(error)")
        }
    }

    // MARK: - Query Methods

    /// Fetch all sessions ordered by timestamp (most recent first), excluding soft-deleted
    func fetchAllSessions() throws -> [SessionLog] {
        let predicate = #Predicate<SessionLog> { !$0.isDeleted }
        var descriptor = FetchDescriptor<SessionLog>(predicate: predicate)
        descriptor.sortBy = [SortDescriptor(\.timestamp, order: .reverse)]
        return try modelContext.fetch(descriptor)
    }

    /// Fetch sessions filtered by gripper type, excluding soft-deleted
    func fetchSessions(gripperType: String) throws -> [SessionLog] {
        let predicate = #Predicate<SessionLog> { session in
            session.gripperType == gripperType && !session.isDeleted
        }
        var descriptor = FetchDescriptor<SessionLog>(predicate: predicate)
        descriptor.sortBy = [SortDescriptor(\.timestamp, order: .reverse)]
        return try modelContext.fetch(descriptor)
    }

    /// Soft-delete a session (marks as deleted, will be purged on next launch)
    func deleteSession(_ session: SessionLog) {
        session.isDeleted = true
        try? modelContext.save()

        // Regenerate CSV with remaining sessions
        regenerateICloudCSV()
    }

    /// Soft-delete multiple sessions
    func deleteSessions(_ sessions: [SessionLog]) {
        for session in sessions {
            session.isDeleted = true
        }
        try? modelContext.save()

        // Regenerate CSV with remaining sessions
        regenerateICloudCSV()
    }

    /// Reset current session (called when user explicitly ends session)
    func endCurrentSession() {
        // Save to iCloud if session was persisted (has reps)
        if isSessionPersisted {
            saveCurrentSessionToICloud()
        }
        currentSession = nil
        isSessionPersisted = false
        currentGripper = nil
        currentSide = nil
    }

    // MARK: - Cleanup

    /// Permanently delete soft-deleted sessions (called on app launch)
    private func purgeDeletedSessions() {
        let deletedPredicate = #Predicate<SessionLog> { $0.isDeleted }
        let deletedDescriptor = FetchDescriptor<SessionLog>(predicate: deletedPredicate)
        if let toDelete = try? modelContext.fetch(deletedDescriptor) {
            for session in toDelete {
                modelContext.delete(session)
            }
        }

        try? modelContext.save()
    }

    // MARK: - iCloud Documents

    private var isICloudEnabled: Bool {
        UserDefaults.standard.bool(forKey: "enableICloudSync")
    }

    /// Save current session CSV to iCloud Documents if it has reps
    private func saveCurrentSessionToICloud() {
        guard isICloudEnabled,
              let session = currentSession,
              let reps = session.reps,
              !reps.isEmpty else {
            return
        }
        regenerateICloudCSV()
    }

    /// Regenerate the single CSV file with all sessions
    private func regenerateICloudCSV() {
        guard isICloudEnabled else { return }

        do {
            let allSessions = try fetchAllSessions()
            ICloudDocumentsManager.saveAllSessions(allSessions)
        } catch {
            print("Failed to fetch sessions for iCloud CSV: \(error)")
        }
    }
}
