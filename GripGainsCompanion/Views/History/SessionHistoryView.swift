import SwiftUI
import SwiftData

/// Main history view showing all logged sessions
struct SessionHistoryView: View {
    @EnvironmentObject private var persistenceService: SessionPersistenceService
    @Query(sort: \SessionLog.timestamp, order: .reverse) private var sessions: [SessionLog]
    @AppStorage("useLbs") private var useLbs = false
    @State private var selectedGripper: String?

    /// Unique gripper types from all sessions
    private var gripperTypes: [String] {
        Array(Set(sessions.map { $0.gripperType })).sorted()
    }

    /// Filtered sessions based on selected gripper
    private var filteredSessions: [SessionLog] {
        if let gripper = selectedGripper {
            return sessions.filter { $0.gripperType == gripper }
        }
        return sessions
    }

    /// Sessions grouped by day
    private var groupedSessions: [(String, [SessionLog])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filteredSessions) { session -> Date in
            calendar.startOfDay(for: session.timestamp)
        }
        return grouped
            .sorted { $0.key > $1.key }
            .map { (formatDayHeader($0.key), $0.value.sorted { $0.timestamp > $1.timestamp }) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if sessions.isEmpty {
                    ContentUnavailableView(
                        "No Sessions",
                        systemImage: "hand.raised.slash",
                        description: Text("Complete some grip training to see your history here.")
                    )
                } else {
                    VStack(spacing: 0) {
                        // Gripper filter
                        if gripperTypes.count > 1 {
                            gripperPicker
                        }
                        sessionsList
                    }
                }
            }
            .navigationTitle("History")
            .toolbar {
                if !sessions.isEmpty {
                    ToolbarItem(placement: .navigationBarLeading) {
                        ShareLink(item: CSVExporter.exportAllSessions(filteredSessions, useLbs: useLbs)) {
                            Label("Export All", systemImage: "square.and.arrow.up")
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        EditButton()
                    }
                }
            }
        }
    }

    private var gripperPicker: some View {
        Picker("Gripper", selection: $selectedGripper) {
            Text("All").tag(nil as String?)
            ForEach(gripperTypes, id: \.self) { gripper in
                Text(gripper).tag(gripper as String?)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var sessionsList: some View {
        List {
            ForEach(groupedSessions, id: \.0) { dayHeader, daySessions in
                Section(header: Text(dayHeader)) {
                    ForEach(daySessions) { session in
                        NavigationLink(destination: SessionDetailView(session: session)) {
                            SessionRowView(session: session, useLbs: useLbs)
                        }
                    }
                    .onDelete { offsets in
                        deleteSessions(daySessions, at: offsets)
                    }
                }
            }
        }
    }

    private func formatDayHeader(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return formatter.string(from: date)
        }
    }

    private func deleteSessions(_ daySessions: [SessionLog], at offsets: IndexSet) {
        for index in offsets {
            persistenceService.deleteSession(daySessions[index])
        }
    }
}

/// Row view for a single session in the list
struct SessionRowView: View {
    let session: SessionLog
    let useLbs: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.timestamp, format: .dateTime.hour().minute())
                .font(.caption)
                .foregroundColor(.secondary)
            Text("\(session.gripperType) \(session.side)")
                .font(.headline)
            HStack {
                Text("\(session.totalReps) reps")
                Spacer()
                Text(String(format: "%.1fs", session.totalDuration))
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    let container = try! ModelContainer(for: SessionLog.self, RepLog.self, configurations: .init(isStoredInMemoryOnly: true))
    return SessionHistoryView()
        .modelContainer(container)
        .environmentObject(SessionPersistenceService(modelContainer: container))
}
