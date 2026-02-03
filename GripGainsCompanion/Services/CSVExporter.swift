import Foundation

/// Exports session data to CSV format for sharing
enum CSVExporter {
    /// CSV header row
    private static let header = "session_id,session_timestamp,gripper,side,rep_number,rep_timestamp,duration_sec,target_weight_kg,median_kg,mean_kg,std_dev,p1,p5,p10,p25,p75,p90,p95,p99,samples"

    /// Export a single session to a CSV file URL
    static func exportSession(_ session: SessionLog, useLbs: Bool = false) -> URL {
        let rows = generateRows(for: session)
        return writeToFile(rows: rows, filename: sanitizeFilename(session.displayTitle))
    }

    /// Export all sessions to a CSV file URL
    static func exportAllSessions(_ sessions: [SessionLog], useLbs: Bool = false) -> URL {
        var allRows: [String] = []
        for session in sessions {
            allRows.append(contentsOf: generateRows(for: session))
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let filename = "grip_history_\(formatter.string(from: Date()))"
        return writeToFile(rows: allRows, filename: filename)
    }

    /// Generate CSV rows for a session
    private static func generateRows(for session: SessionLog) -> [String] {
        let sortedReps = (session.reps ?? []).sorted { $0.timestamp < $1.timestamp }
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]

        return sortedReps.enumerated().map { index, rep in
            let sessionTimestamp = isoFormatter.string(from: session.timestamp)
            let repTimestamp = isoFormatter.string(from: rep.timestamp)
            let samples = rep.samples.map { String(format: "%.2f", $0) }.joined(separator: ";")

            return [
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
        }
    }

    /// Write rows to a temporary CSV file
    private static func writeToFile(rows: [String], filename: String) -> URL {
        let content = [header] + rows
        let csvString = content.joined(separator: "\n")

        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("\(filename).csv")

        try? csvString.write(to: fileURL, atomically: true, encoding: .utf8)

        return fileURL
    }

    /// Escape a string for CSV (wrap in quotes if contains comma, quote, or newline)
    private static func escapeCSV(_ string: String) -> String {
        if string.contains(",") || string.contains("\"") || string.contains("\n") {
            let escaped = string.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return string
    }

    /// Sanitize a string for use as a filename
    private static func sanitizeFilename(_ string: String) -> String {
        let invalidChars = CharacterSet(charactersIn: ":/\\?%*|\"<>")
        return string
            .components(separatedBy: invalidChars)
            .joined(separator: "_")
            .replacingOccurrences(of: " ", with: "_")
    }
}
