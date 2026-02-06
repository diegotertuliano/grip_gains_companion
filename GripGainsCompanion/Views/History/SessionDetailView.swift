import SwiftUI
import SwiftData
import UIKit

/// Detail view for a single session showing all reps
struct SessionDetailView: View {
    let session: SessionLog
    @AppStorage("useLbs") private var useLbs = false

    private var sortedReps: [RepLog] {
        let reps = session.reps ?? []
        return reps.sorted { $0.timestamp < $1.timestamp }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                // Session Info Header
                sessionHeader

                Divider()
                    .padding(.horizontal)

                // Rep List
                ForEach(Array(sortedReps.enumerated()), id: \.element.id) { index, rep in
                    HistoryRepSection(rep: rep, index: index + 1, useLbs: useLbs)

                    if index < sortedReps.count - 1 {
                        Divider()
                            .padding(.horizontal)
                    }
                }
            }
            .padding(.vertical)
        }
        .navigationTitle(session.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    shareCSV()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
    }

    private func shareCSV() {
        let url = CSVExporter.exportSession(session, useLbs: useLbs)
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)

        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            var topVC = rootVC
            while let presented = topVC.presentedViewController {
                topVC = presented
            }

            if let popover = activityVC.popoverPresentationController {
                popover.sourceView = topVC.view
                popover.sourceRect = CGRect(x: topVC.view.bounds.midX, y: 50, width: 0, height: 0)
            }

            topVC.present(activityVC, animated: true)
        }
    }

    private var sessionHeader: some View {
        VStack(spacing: 8) {
            Text(session.timestamp, format: .dateTime.month().day().hour().minute())
                .font(.caption)

            HStack {
                Text(session.gripperType)
                Spacer()
                Text(session.side)
            }

            HStack {
                Text("\(session.totalReps) reps")
                Spacer()
                Text(String(format: "%.1fs", session.totalDuration))
            }
        }
        .font(.subheadline)
        .foregroundColor(.secondary)
        .padding(.horizontal)
    }

}

/// Wrapper view that fetches a session by ID for navigation
struct SessionDetailWrapper: View {
    let sessionId: UUID
    @Query private var sessions: [SessionLog]

    init(sessionId: UUID) {
        self.sessionId = sessionId
        // Filter to find the specific session by ID
        self._sessions = Query(filter: #Predicate<SessionLog> { $0.id == sessionId })
    }

    var body: some View {
        if let session = sessions.first {
            SessionDetailView(session: session)
        } else {
            ContentUnavailableView(
                "Session Not Found",
                systemImage: "questionmark.circle",
                description: Text("This session may have been deleted.")
            )
        }
    }
}
