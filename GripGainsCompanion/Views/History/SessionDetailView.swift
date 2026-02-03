import SwiftUI
import SwiftData

/// Detail view for a single session showing all reps
struct SessionDetailView: View {
    let session: SessionLog
    @AppStorage("useLbs") private var useLbs = false

    private var sortedReps: [RepLog] {
        (session.reps ?? []).sorted { $0.timestamp < $1.timestamp }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
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
                ShareLink(item: CSVExporter.exportSession(session, useLbs: useLbs)) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
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
