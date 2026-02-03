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
            // Handle previous session
            if let session = currentSession {
                if (session.reps ?? []).isEmpty {
                    // Delete empty session - don't persist 0-rep sessions
                    modelContext.delete(session)
                } else {
                    // Save to iCloud if has reps
                    saveCurrentSessionToICloud()
                }
            }

            // Create new session
            let session = SessionLog(gripperType: gripper, side: side)
            modelContext.insert(session)
            currentSession = session

            currentGripper = gripper
            currentSide = side

            try? modelContext.save()
        }
    }

    // MARK: - Rep Persistence

    /// Save a rep to the current session
    func saveRep(from repResult: RepResult) {
        guard let session = currentSession else {
            // No active session - cannot save rep
            return
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
        // Delete empty session, or save to iCloud if has reps
        if let session = currentSession {
            if (session.reps ?? []).isEmpty {
                modelContext.delete(session)
                try? modelContext.save()
            } else {
                saveCurrentSessionToICloud()
            }
        }
        currentSession = nil
        currentGripper = nil
        currentSide = nil
    }

    // MARK: - Cleanup

    /// Permanently delete soft-deleted and empty sessions (called on app launch)
    private func purgeDeletedSessions() {
        // 1. Purge soft-deleted sessions
        let deletedPredicate = #Predicate<SessionLog> { $0.isDeleted }
        let deletedDescriptor = FetchDescriptor<SessionLog>(predicate: deletedPredicate)
        if let toDelete = try? modelContext.fetch(deletedDescriptor) {
            for session in toDelete {
                modelContext.delete(session)
            }
        }

        // 2. Purge empty (0-rep) sessions - exclude current session
        let allDescriptor = FetchDescriptor<SessionLog>()
        if let allSessions = try? modelContext.fetch(allDescriptor) {
            for session in allSessions where session != currentSession {
                if (session.reps ?? []).isEmpty {
                    modelContext.delete(session)
                }
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
