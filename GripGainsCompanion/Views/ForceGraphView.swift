import SwiftUI
import Charts

/// Real-time force graph showing recent force history
struct ForceGraphView: View {
    let forceHistory: [(timestamp: Date, force: Double)]
    let useLbs: Bool
    let windowSeconds: Int  // 0 = entire session
    let targetWeight: Double?
    let tolerance: Double?  // Optional tolerance in same units as targetWeight (kg)

    @Environment(\.colorScheme) private var colorScheme

    private var isDarkMode: Bool {
        colorScheme == .dark
    }

    /// Convert force to display units
    private func displayForce(_ force: Double) -> Double {
        Double(useLbs ? force * AppConstants.kgToLbs : force)
    }

    var body: some View {
        if windowSeconds > 0 {
            TimelineView(.periodic(from: .now, by: 1.0 / 60)) { timeline in
                chartContent(now: timeline.date)
            }
        } else {
            chartContent(now: Date())
        }
    }

    private func chartContent(now: Date) -> some View {
        let windowStart: Date
        let xMax: Double

        if windowSeconds > 0 {
            windowStart = now.addingTimeInterval(-Double(windowSeconds))
            xMax = Double(windowSeconds)
        } else {
            windowStart = forceHistory.first?.timestamp ?? now
            let last = forceHistory.last?.timestamp ?? now
            xMax = max(last.timeIntervalSince(windowStart), 0.001)
        }

        let filterStart = windowSeconds > 0
            ? windowStart.addingTimeInterval(-1)
            : windowStart
        let filtered = windowSeconds > 0
            ? forceHistory.filter { $0.timestamp >= filterStart }
            : forceHistory

        // Stretch denominator to cover device-clock drift so no sample exceeds x=1.0
        let maxRaw = filtered.last.map { $0.timestamp.timeIntervalSince(windowStart) } ?? xMax
        let actualXMax = max(maxRaw, 0.001)

        // Normalize X values to 0...1
        let visible: [(x: Double, force: Double)] = filtered.map {
            let raw = $0.timestamp.timeIntervalSince(windowStart)
            return (x: actualXMax > 0 ? raw / actualXMax : 0, force: $0.force)
        }

        return Chart {
            // Tolerance band — explicit 0...1 X span
            if let target = targetWeight, let tol = tolerance {
                RectangleMark(
                    xStart: .value("Start", 0.0),
                    xEnd: .value("End", 1.0),
                    yStart: .value("Lower", displayForce(target - tol)),
                    yEnd: .value("Upper", displayForce(target + tol))
                )
                .foregroundStyle(Color.gray.opacity(0.4))
            }

            // Target line — explicit 0...1 X span
            if let target = targetWeight {
                RuleMark(
                    xStart: .value("Start", 0.0),
                    xEnd: .value("End", 1.0),
                    y: .value("Target", displayForce(target))
                )
                .foregroundStyle(Color.green.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 3]))
            }

            // Force line
            ForEach(Array(visible.enumerated()), id: \.offset) { _, sample in
                LineMark(
                    x: .value("Time", sample.x),
                    y: .value("Force", displayForce(sample.force))
                )
                .foregroundStyle(Color.blue)
                .lineStyle(StrokeStyle(lineWidth: 2))
            }
        }
        .chartXAxis(.hidden)
        .chartXScale(domain: 0.0...1.0)
        .chartPlotStyle { plotArea in
            plotArea.clipped()
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
        .chartYScale(domain: yAxisDomain(for: visible))
        .frame(height: 100)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(isDarkMode ? Color.black : Color(.systemBackground))
    }

    /// Calculate Y-axis domain based on visible data and target
    private func yAxisDomain(for visible: [(x: Double, force: Double)]) -> ClosedRange<Double> {
        let forces = visible.map { displayForce($0.force) }
        var lower = forces.min() ?? 0
        var upper = forces.max() ?? 10

        // Include target weight and tolerance band in range
        if let target = targetWeight {
            let targetDisplay = displayForce(target)
            let tolDisplay = tolerance != nil ? displayForce(tolerance!) : 0
            lower = min(lower, targetDisplay - tolDisplay)
            upper = max(upper, targetDisplay + tolDisplay)
        }

        let minRange = displayForce(2)

        if let target = targetWeight {
            // Center on target with ±1, expanding symmetrically if data exceeds
            let targetDisplay = displayForce(target)
            let halfRange = max(targetDisplay - lower, upper - targetDisplay, minRange / 2)
            lower = targetDisplay - halfRange
            upper = targetDisplay + halfRange
        } else {
            // No target: enforce minimum range centered on data
            let currentRange = upper - lower
            if currentRange < minRange {
                let expand = (minRange - currentRange) / 2
                lower -= expand
                upper += expand
            }
        }

        lower = max(0, lower)
        if upper <= lower { upper = lower + minRange }

        return lower...upper
    }
}

#Preview("With data") {
    let now = Date()
    let history: [(timestamp: Date, force: Double)] = (0..<100).map { i in
        (timestamp: now.addingTimeInterval(Double(i) * 0.1 - 10),
         force: 20 + Double.random(in: -2...2))
    }
    return ForceGraphView(
        forceHistory: history,
        useLbs: false,
        windowSeconds: 10,
        targetWeight: 20,
        tolerance: 0.5
    )
}

#Preview("Empty") {
    ForceGraphView(
        forceHistory: [],
        useLbs: false,
        windowSeconds: 10,
        targetWeight: nil,
        tolerance: nil
    )
}

#Preview("Partial window") {
    let now = Date()
    let history: [(timestamp: Date, force: Double)] = (0..<30).map { i in
        (timestamp: now.addingTimeInterval(Double(i) * 0.1 - 3),
         force: 15 + Double.random(in: -1...1))
    }
    return ForceGraphView(
        forceHistory: history,
        useLbs: false,
        windowSeconds: 10,
        targetWeight: 15,
        tolerance: 0.5
    )
}
