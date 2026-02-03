import Foundation
import SwiftData

/// Represents a grip training session, automatically created when gripper or side changes
@Model
final class SessionLog {
    // MARK: - Primary Key
    var id: UUID = UUID()

    // MARK: - Session Metadata
    var timestamp: Date = Date()
    var gripperType: String = ""
    var side: String = ""
    var isDeleted: Bool = false

    // MARK: - Relationships (must be optional for CloudKit)
    @Relationship(deleteRule: .cascade, inverse: \RepLog.session)
    var reps: [RepLog]? = []

    // MARK: - Computed Properties

    var displayTitle: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return "\(gripperType) \(side) - \(formatter.string(from: timestamp))"
    }

    var totalReps: Int {
        reps?.count ?? 0
    }

    var totalDuration: TimeInterval {
        reps?.reduce(0) { $0 + $1.duration } ?? 0
    }

    // MARK: - Initializer

    init(gripperType: String, side: String, timestamp: Date = Date()) {
        self.id = UUID()
        self.timestamp = timestamp
        self.gripperType = gripperType
        self.side = side
    }
}
