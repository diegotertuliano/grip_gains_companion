import SwiftUI
import Charts

/// Real-time force graph showing recent force history
struct ForceGraphView: View {
    let forceHistory: [(timestamp: Date, force: Float)]
    let useLbs: Bool
    let windowSeconds: Int  // 0 = entire session
    let targetWeight: Float?

    @Environment(\.colorScheme) private var colorScheme

    private var isDarkMode: Bool {
        colorScheme == .dark
    }

    /// Filter history to the selected time window
    private var visibleHistory: [(timestamp: Date, force: Float)] {
        guard windowSeconds > 0 else {
            return forceHistory  // Entire session
        }
        let cutoff = Date().addingTimeInterval(-Double(windowSeconds))
        return forceHistory.filter { $0.timestamp >= cutoff }
    }

    /// Convert force to display units
    private func displayForce(_ force: Float) -> Double {
        Double(useLbs ? force * AppConstants.kgToLbs : force)
    }

    var body: some View {
        Chart {
            // Force line
            ForEach(Array(visibleHistory.enumerated()), id: \.offset) { _, sample in
                LineMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("Force", displayForce(sample.force))
                )
                .foregroundStyle(Color.blue)
                .lineStyle(StrokeStyle(lineWidth: 2))
            }

            // Target weight line (if set)
            if let target = targetWeight {
                RuleMark(y: .value("Target", displayForce(target)))
                    .foregroundStyle(Color.green.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 3]))
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine()
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
        .frame(height: 100)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(isDarkMode ? Color.black : Color(.systemBackground))
    }

    /// Calculate Y-axis domain based on visible data and target
    private var yAxisDomain: ClosedRange<Double> {
        let forces = visibleHistory.map { displayForce($0.force) }
        let minForce = forces.min() ?? 0
        let maxForce = forces.max() ?? 10

        var lower = min(minForce, 0)
        var upper = max(maxForce, 10)

        // Include target weight in range if set
        if let target = targetWeight {
            let targetDisplay = displayForce(target)
            lower = min(lower, targetDisplay - 5)
            upper = max(upper, targetDisplay + 5)
        }

        // Add some padding
        let padding = (upper - lower) * 0.1
        return (lower - padding)...(upper + padding)
    }
}

#Preview("With data") {
    let now = Date()
    let history: [(timestamp: Date, force: Float)] = (0..<100).map { i in
        (timestamp: now.addingTimeInterval(Double(i) * 0.1 - 10),
         force: 20 + Float.random(in: -2...2))
    }
    return ForceGraphView(
        forceHistory: history,
        useLbs: false,
        windowSeconds: 10,
        targetWeight: 20
    )
}

#Preview("Empty") {
    ForceGraphView(
        forceHistory: [],
        useLbs: false,
        windowSeconds: 10,
        targetWeight: nil
    )
}
