import SwiftUI
import Charts

/// Sheet for reviewing set statistics with scrollable rep details
struct SetReviewSheet: View {
    let stats: SetStatistics
    let useLbs: Bool
    let onDismiss: () -> Void

    @State private var copiedRepIndex: Int? = nil
    @State private var copiedAll: Bool = false
    @State private var isGeneratingShareImage: Bool = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Set Summary Section (only if there's data)
                    if stats.hasSummaryData {
                        summarySection

                        Divider()
                            .padding(.horizontal)
                    }

                    // All Reps
                    ForEach(Array(stats.reps.enumerated()), id: \.offset) { index, rep in
                        repSection(index: index, rep: rep)

                        if index < stats.reps.count - 1 {
                            Divider()
                                .padding(.horizontal)
                        }
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Set Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        shareFullSet()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(isGeneratingShareImage)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Summary Section

    private var summarySection: some View {
        VStack(spacing: 8) {
            if let absDev = stats.meanAbsoluteDeviation, let pctDev = stats.meanDeviation {
                statRow("Avg. difference of Median from Target", value: formatDeviation(absolute: absDev, percentage: pctDev), bold: true)
            }
            if let stdDev = stats.medianStdDev {
                statRow("Standard Deviation", value: String(format: "%.2f", useLbs ? stdDev * AppConstants.kgToLbs : stdDev))
            }
            if let target = stats.targetWeight {
                statRow("Target", value: WeightFormatter.format(target, useLbs: useLbs))
            }

            Button {
                copyAllForceDataToClipboard()
            } label: {
                HStack {
                    Image(systemName: copiedAll ? "checkmark" : "doc.on.doc")
                    Text("Copy All Reps Force Data")
                }
                .foregroundColor(copiedAll ? .green : .accentColor)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal)
    }

    // MARK: - Rep Section

    private func repSection(index: Int, rep: RepResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Rep Header with Share and Copy Buttons
            HStack {
                Text("Rep \(index + 1)")
                    .font(.headline)
                Spacer()
                Button {
                    shareRep(index: index, rep: rep)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
                .disabled(isGeneratingShareImage)
                Button {
                    copyForceDataToClipboard(rep: rep, index: index)
                } label: {
                    Image(systemName: copiedRepIndex == index ? "checkmark" : "doc.on.doc")
                        .font(.body)
                        .foregroundColor(copiedRepIndex == index ? .green : .secondary)
                }
            }
            .padding(.horizontal)

            // Force Graph
            let filter = rep.filterResult
            RepForceGraphView(
                samples: rep.samples,
                duration: rep.duration,
                targetWeight: rep.targetWeight,
                useLbs: useLbs,
                filterStartIndex: filter.startIndex,
                filterEndIndex: filter.endIndex
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
                    statRow("Difference of Median from Target", value: formatDeviation(absolute: absDev, percentage: pctDev))
                }

                // Percentile grid
                percentilesGrid(rep: rep)
            }
            .padding(.horizontal)
        }
    }

    // MARK: - Helpers

    private func statRow(_ label: String, value: String, bold: Bool = false) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .fontWeight(bold ? .medium : .regular)
        }
        .font(.subheadline)
    }

    /// Compact horizontal grid showing percentile distribution
    private func percentilesGrid(rep: RepResult) -> some View {
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

    /// Format deviation as "+0.04 kg (+1.0%)"
    private func formatDeviation(absolute: Double, percentage: Double) -> String {
        let displayAbs = useLbs ? absolute * AppConstants.kgToLbs : absolute
        let unit = useLbs ? "lbs" : "kg"
        return String(format: "%+.2f %@ (%+.1f%%)", displayAbs, unit, percentage)
    }

    /// Copy force data to clipboard as tab-separated values
    private func copyForceDataToClipboard(rep: RepResult, index: Int) {
        var lines: [String] = []
        for (i, force) in rep.samples.enumerated() {
            let time = rep.duration * Double(i) / Double(max(1, rep.samples.count - 1))
            lines.append(String(format: "%.2f\t%.1f", time, force))
        }
        UIPasteboard.general.string = lines.joined(separator: "\n")

        // Show confirmation for this rep
        copiedRepIndex = index
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedRepIndex == index {
                copiedRepIndex = nil
            }
        }
    }

    /// Copy all reps' force data to clipboard as tab-separated values
    private func copyAllForceDataToClipboard() {
        var allLines: [String] = []
        for rep in stats.reps {
            var repLines: [String] = []
            for (i, force) in rep.samples.enumerated() {
                let time = rep.duration * Double(i) / Double(max(1, rep.samples.count - 1))
                repLines.append(String(format: "%.2f\t%.1f", time, force))
            }
            allLines.append(repLines.joined(separator: "\n"))
        }
        UIPasteboard.general.string = allLines.joined(separator: "\n\n")

        copiedAll = true
        copiedRepIndex = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copiedAll = false
        }
    }

    // MARK: - Share Methods

    @MainActor
    private func shareFullSet() {
        isGeneratingShareImage = true

        let shareView = ShareableSetSummaryView(stats: stats, useLbs: useLbs)

        if let image = ImageShareUtility.renderToImage(
            shareView,
            width: ShareableSetSummaryView.exportWidth
        ) {
            ImageShareUtility.shareImage(image)
        }

        isGeneratingShareImage = false
    }

    @MainActor
    private func shareRep(index: Int, rep: RepResult) {
        isGeneratingShareImage = true

        let shareView = ShareableRepView(
            rep: rep,
            repNumber: index + 1,
            useLbs: useLbs
        )

        if let image = ImageShareUtility.renderToImage(
            shareView,
            width: ShareableRepView.exportWidth
        ) {
            ImageShareUtility.shareImage(image)
        }

        isGeneratingShareImage = false
    }
}

// MARK: - Rep Force Graph

/// Force graph for a single rep using sample indices as x-axis
struct RepForceGraphView: View {
    let samples: [Double]
    let duration: TimeInterval
    let targetWeight: Double?
    let useLbs: Bool
    let filterStartIndex: Int
    let filterEndIndex: Int

    private func displayForce(_ force: Double) -> Double {
        Double(useLbs ? force * AppConstants.kgToLbs : force)
    }

    /// Convert sample index to elapsed time
    private func elapsedTime(for index: Int) -> Double {
        guard samples.count > 1 else { return 0 }
        return duration * Double(index) / Double(samples.count - 1)
    }

    var body: some View {
        Chart {
            // Raw samples (entire line, gray, thin) - shows removed portions
            ForEach(Array(samples.enumerated()), id: \.offset) { index, force in
                LineMark(
                    x: .value("Time", elapsedTime(for: index)),
                    y: .value("Force", displayForce(force)),
                    series: .value("Series", "raw")
                )
                .foregroundStyle(Color.gray.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1))
            }

            // Filtered samples (kept portion, blue, thick)
            ForEach(Array(samples.enumerated()), id: \.offset) { index, force in
                if index >= filterStartIndex && index <= filterEndIndex {
                    LineMark(
                        x: .value("Time", elapsedTime(for: index)),
                        y: .value("Force", displayForce(force)),
                        series: .value("Series", "filtered")
                    )
                    .foregroundStyle(Color.blue)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
            }

            // Target weight line (if set)
            if let target = targetWeight {
                RuleMark(y: .value("Target", displayForce(target)))
                    .foregroundStyle(Color.green.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 3]))
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let seconds = value.as(Double.self) {
                        Text(String(format: "%.0fs", seconds))
                            .font(.caption2)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let force = value.as(Double.self) {
                        Text("\(Int(force))")
                            .font(.caption2)
                    }
                }
            }
        }
        .chartYScale(domain: yAxisDomain)
    }

    private var yAxisDomain: ClosedRange<Double> {
        let forces = samples.map { displayForce($0) }
        var lower = forces.min() ?? 0
        var upper = forces.max() ?? 10

        if let target = targetWeight {
            let targetDisplay = displayForce(target)
            lower = min(lower, targetDisplay)
            upper = max(upper, targetDisplay)
        }

        let range = upper - lower
        let padding = max(range * 0.15, 2.0)
        return max(0, lower - padding)...(upper + padding)
    }
}

// MARK: - Previews

#Preview("Set Summary") {
    SetReviewSheet(
        stats: SetStatistics(reps: [
            RepResult(timestamp: Date(), duration: 7.0, samples: Array(repeating: 20.2, count: 70), targetWeight: 20.0),
            RepResult(timestamp: Date(), duration: 6.5, samples: Array(repeating: 19.8, count: 65), targetWeight: 20.0),
            RepResult(timestamp: Date(), duration: 7.2, samples: Array(repeating: 20.0, count: 72), targetWeight: 20.0)
        ]),
        useLbs: false,
        onDismiss: {}
    )
}
