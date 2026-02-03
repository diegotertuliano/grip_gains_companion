import SwiftUI

/// Displays a single rep from history with force graph and statistics
struct HistoryRepSection: View {
    let rep: RepLog
    let index: Int
    let useLbs: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Rep Header
            HStack {
                Text("Rep \(index)")
                    .font(.headline)
                Spacer()
                Text(rep.timestamp, style: .time)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)

            // Force Graph (reuse RepForceGraphView from SetReviewSheet)
            RepForceGraphView(
                samples: rep.samples,
                duration: rep.duration,
                targetWeight: rep.targetWeight,
                useLbs: useLbs,
                filterStartIndex: rep.filterStartIndex,
                filterEndIndex: rep.filterEndIndex
            )
            .frame(height: 180)
            .padding(.horizontal)

            // Rep Stats
            VStack(spacing: 6) {
                statRow("Duration", value: String(format: "%.1fs", rep.duration))
                statRow("Median", value: WeightFormatter.format(rep.median, useLbs: useLbs))
                statRow("Average", value: WeightFormatter.format(rep.mean, useLbs: useLbs))
                statRow("Standard Deviation", value: String(format: "%.2f", useLbs ? rep.stdDev * AppConstants.kgToLbs : rep.stdDev))

                if let absDev = rep.absoluteDeviation, let pctDev = rep.deviationPercentage {
                    statRow("Difference from Target", value: formatDeviation(absolute: absDev, percentage: pctDev))
                }

                // Percentile grid
                percentilesGrid
            }
            .padding(.horizontal)
        }
    }

    // MARK: - Helpers

    private func statRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
        }
        .font(.subheadline)
    }

    private var percentilesGrid: some View {
        let percentiles: [(String, Double)] = [
            ("P1", rep.p1),
            ("P5", rep.p5),
            ("P10", rep.p10),
            ("P25", rep.q1),
            ("P75", rep.q3),
            ("P90", rep.p90),
            ("P95", rep.p95),
            ("P99", rep.p99)
        ]

        return VStack(spacing: 2) {
            Text("Percentiles")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 0) {
                ForEach(percentiles, id: \.0) { label, _ in
                    Text(label)
                        .frame(maxWidth: .infinity)
                }
            }
            .foregroundColor(.secondary)

            HStack(spacing: 0) {
                ForEach(percentiles, id: \.0) { _, value in
                    Text(WeightFormatter.format(value, useLbs: useLbs, includeUnit: false))
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .font(.caption)
    }

    private func formatDeviation(absolute: Double, percentage: Double) -> String {
        let displayAbs = useLbs ? absolute * AppConstants.kgToLbs : absolute
        let unit = useLbs ? "lbs" : "kg"
        return String(format: "%+.2f %@ (%+.1f%%)", displayAbs, unit, percentage)
    }
}
