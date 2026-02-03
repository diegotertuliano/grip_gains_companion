import Foundation

/// Manages saving session CSV to iCloud Documents for user visibility in Files app
enum ICloudDocumentsManager {
    /// Get the iCloud Documents URL (nil if iCloud not available)
    static var iCloudDocumentsURL: URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.com.gripgains.companion")?
            .appendingPathComponent("Documents")
    }

    /// Check if iCloud Documents is available
    static var isAvailable: Bool {
        iCloudDocumentsURL != nil
    }

    /// Save all sessions to a single CSV file in iCloud Documents
    static func saveAllSessions(_ sessions: [SessionLog]) {
        guard let documentsURL = iCloudDocumentsURL else {
            print("iCloud Documents not available")
            return
        }

        // Ensure directory exists
        try? FileManager.default.createDirectory(
            at: documentsURL,
            withIntermediateDirectories: true
        )

        let fileURL = documentsURL.appendingPathComponent("grip_history.csv")

        // Generate CSV content for all sessions
        let csvContent = generateCSV(for: sessions)

        do {
            try csvContent.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            print("Failed to save CSV to iCloud: \(error)")
        }
    }

    // MARK: - Private Helpers

    private static let header = "session_id,session_timestamp,gripper,side,rep_number,rep_timestamp,duration_sec,target_weight_kg,median_kg,mean_kg,std_dev,p1,p5,p10,p25,p75,p90,p95,p99,samples"

    private static func generateCSV(for sessions: [SessionLog]) -> String {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]

        var allRows: [String] = []

        for session in sessions {
            let sortedReps = (session.reps ?? []).sorted { $0.timestamp < $1.timestamp }

            for (index, rep) in sortedReps.enumerated() {
                let sessionTimestamp = isoFormatter.string(from: session.timestamp)
                let repTimestamp = isoFormatter.string(from: rep.timestamp)
                let samples = rep.samples.map { String(format: "%.2f", $0) }.joined(separator: ";")

                let row = [
                    session.id.uuidString,
                    sessionTimestamp,
                    escapeCSV(session.gripperType),
                    escapeCSV(session.side),
                    String(index + 1),
                    repTimestamp,
                    String(format: "%.2f", rep.duration),
                    rep.targetWeight.map { String(format: "%.2f", $0) } ?? "",
                    String(format: "%.2f", rep.median),
                    String(format: "%.2f", rep.mean),
                    String(format: "%.4f", rep.stdDev),
                    String(format: "%.2f", rep.p1),
                    String(format: "%.2f", rep.p5),
                    String(format: "%.2f", rep.p10),
                    String(format: "%.2f", rep.q1),
                    String(format: "%.2f", rep.q3),
                    String(format: "%.2f", rep.p90),
                    String(format: "%.2f", rep.p95),
                    String(format: "%.2f", rep.p99),
                    escapeCSV(samples)
                ].joined(separator: ",")

                allRows.append(row)
            }
        }

        return ([header] + allRows).joined(separator: "\n")
    }

    private static func escapeCSV(_ string: String) -> String {
        if string.contains(",") || string.contains("\"") || string.contains("\n") {
            let escaped = string.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return string
    }
}
