import SwiftUI

/// Compact status bar showing force reading and connection state
struct StatusBarView: View {
    let state: StatusBarState
    let useLbs: Bool
    let theme: ForceBarTheme
    let expanded: Bool
    let deviceShortName: String
    let reconnecting: Bool
    let onUnitToggle: () -> Void
    let onSettingsTap: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    init(
        force: Double,
        engaged: Bool,
        calibrating: Bool,
        waitingForSamples: Bool,
        calibrationTimeRemaining: TimeInterval,
        weightMedian: Double?,
        targetWeight: Double? = nil,
        isOffTarget: Bool = false,
        offTargetDirection: Double? = nil,
        sessionMean: Double? = nil,
        sessionStdDev: Double? = nil,
        useLbs: Bool,
        theme: ForceBarTheme = .system,
        expanded: Bool = false,
        deviceShortName: String = "device",
        reconnecting: Bool = false,
        onUnitToggle: @escaping () -> Void,
        onSettingsTap: @escaping () -> Void
    ) {
        self.state = StatusBarState(
            force: force,
            engaged: engaged,
            calibrating: calibrating,
            waitingForSamples: waitingForSamples,
            calibrationTimeRemaining: calibrationTimeRemaining,
            weightMedian: weightMedian,
            targetWeight: targetWeight,
            isOffTarget: isOffTarget,
            offTargetDirection: offTargetDirection,
            sessionMean: sessionMean,
            sessionStdDev: sessionStdDev
        )
        self.useLbs = useLbs
        self.theme = theme
        self.expanded = expanded
        self.deviceShortName = deviceShortName
        self.reconnecting = reconnecting
        self.onUnitToggle = onUnitToggle
        self.onSettingsTap = onSettingsTap
    }

    private var isDarkMode: Bool {
        switch theme {
        case .dark: return true
        case .light: return false
        case .system: return colorScheme == .dark
        }
    }

    private var backgroundColor: Color {
        isDarkMode ? .black : Color(.systemBackground)
    }

    private var secondaryTextColor: Color {
        isDarkMode ? .gray : .secondary
    }

    var body: some View {
        VStack(spacing: expanded ? 8 : 4) {
            if expanded {
                expandedLayout
            } else {
                compactLayout
            }
            calibrationMessage
        }
        .padding(.horizontal)
        .padding(.vertical, expanded ? 20 : 10)
        .background(backgroundColor)
    }

    // MARK: - View Components

    /// Compact layout: single horizontal row
    @ViewBuilder
    private var compactLayout: some View {
        HStack(spacing: 8) {
            forceDisplay
            Spacer()
            statisticsDisplay
            weightDisplay
            stateBadge
            settingsButton
        }
    }

    /// Expanded layout: giant centered force with secondary info
    @ViewBuilder
    private var expandedLayout: some View {
        // Top row: measured weight on left, badge and settings on right
        HStack {
            measuredWeightDisplay
            Spacer()
            stateBadge
            settingsButton
        }

        // Center: giant force number
        expandedForceDisplay
            .frame(maxWidth: .infinity)

        // Bottom row: stats on left, target on right
        HStack {
            statisticsDisplay
            Spacer()
            targetWeightDisplay
        }
    }

    /// Measured weight only (for expanded layout top left)
    @ViewBuilder
    private var measuredWeightDisplay: some View {
        if state.showWeight, let median = state.weightMedian {
            Text("⚖ \(WeightFormatter.format(median, useLbs: useLbs))")
                .font(.caption)
                .foregroundColor(secondaryTextColor)
        }
    }

    /// Target weight only (for expanded layout bottom right)
    @ViewBuilder
    private var targetWeightDisplay: some View {
        if let target = state.targetWeight {
            HStack(spacing: 4) {
                Text("Target: \(WeightFormatter.format(target, useLbs: useLbs))")
                    .font(.caption)
                    .foregroundColor(state.isOffTarget ? .red : secondaryTextColor)

                // Show difference when off target
                if state.isOffTarget, let diff = state.formattedDifference(useLbs: useLbs) {
                    Text("(\(diff))")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.red)
                }
            }
        }
    }

    /// Giant force display for expanded mode
    private var expandedForceDisplay: some View {
        Text(WeightFormatter.format(state.force, useLbs: useLbs))
            .font(.system(size: 48, weight: .bold, design: .rounded))
            .foregroundColor(state.forceColor(baseline: state.weightMedian ?? 0, isDarkMode: isDarkMode))
            .onTapGesture { onUnitToggle() }
    }

    @ViewBuilder
    private var statisticsDisplay: some View {
        if let mean = state.sessionMean {
            HStack(spacing: 6) {
                // Mean display
                HStack(spacing: 2) {
                    Text("x̄")
                        .font(.caption2)
                    Text(WeightFormatter.format(mean, useLbs: useLbs))
                        .font(.caption)
                        .fontWeight(.medium)
                }

                // Standard deviation display
                if let stdDev = state.sessionStdDev, stdDev > 0 {
                    HStack(spacing: 2) {
                        Text("σ")
                            .font(.caption2)
                        Text(WeightFormatter.format(stdDev, useLbs: useLbs, includeUnit: false))
                            .font(.caption)
                    }
                }
            }
            .foregroundColor(secondaryTextColor)
        }
    }

    /// Compact force display
    private var forceDisplay: some View {
        Text(WeightFormatter.format(state.force, useLbs: useLbs))
            .font(.subheadline)
            .fontWeight(.semibold)
            .foregroundColor(state.forceColor(baseline: state.weightMedian ?? 0, isDarkMode: isDarkMode))
            .onTapGesture { onUnitToggle() }
    }

    @ViewBuilder
    private var weightDisplay: some View {
        if state.showWeight, let median = state.weightMedian {
            HStack(spacing: 4) {
                Text("⚖ \(WeightFormatter.format(median, useLbs: useLbs))")
                    .font(.caption)
                    .foregroundColor(secondaryTextColor)

                // Show target weight if set
                if let target = state.targetWeight {
                    Text("→ \(WeightFormatter.format(target, useLbs: useLbs))")
                        .font(.caption)
                        .foregroundColor(secondaryTextColor.opacity(0.7))
                }
            }
        } else if state.engaged {
            // During gripping, show target weight and off-target indicator
            if let target = state.targetWeight {
                HStack(spacing: 4) {
                    Text("Target: \(WeightFormatter.format(target, useLbs: useLbs))")
                        .font(.caption)
                        .foregroundColor(state.isOffTarget ? .red : secondaryTextColor)

                    // Show difference when off target
                    if state.isOffTarget, let diff = state.formattedDifference(useLbs: useLbs) {
                        Text("(\(diff))")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.red)
                    }
                }
            }
        }
    }

    private var stateBadge: some View {
        Text(reconnecting ? "RECONNECTING..." : state.stateText)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(reconnecting ? .orange : state.stateColor)
            .foregroundColor(.white)
            .cornerRadius(4)
    }

    private var settingsButton: some View {
        Button(action: onSettingsTap) {
            Image(systemName: "gearshape")
                .font(.subheadline)
                .foregroundColor(secondaryTextColor)
        }
    }

    @ViewBuilder
    private var calibrationMessage: some View {
        if state.calibrating {
            Text("Don't touch \(deviceShortName)")
                .font(.caption)
                .foregroundColor(.orange)
                .fontWeight(.medium)
        }
    }
}

#Preview("Idle with weight") {
    StatusBarView(
        force: 2.1,
        engaged: false,
        calibrating: false,
        waitingForSamples: false,
        calibrationTimeRemaining: 0,
        weightMedian: 20.0,
        targetWeight: 20.0,
        useLbs: false,
        onUnitToggle: {},
        onSettingsTap: {}
    )
}

#Preview("Gripping on target") {
    StatusBarView(
        force: 25.3,
        engaged: true,
        calibrating: false,
        waitingForSamples: false,
        calibrationTimeRemaining: 0,
        weightMedian: nil,
        targetWeight: 20.0,
        isOffTarget: false,
        useLbs: false,
        onUnitToggle: {},
        onSettingsTap: {}
    )
}

#Preview("Gripping off target (heavy)") {
    StatusBarView(
        force: 25.3,
        engaged: true,
        calibrating: false,
        waitingForSamples: false,
        calibrationTimeRemaining: 0,
        weightMedian: nil,
        targetWeight: 20.0,
        isOffTarget: true,
        offTargetDirection: 0.7,
        useLbs: false,
        onUnitToggle: {},
        onSettingsTap: {}
    )
}

#Preview("Gripping off target (light)") {
    StatusBarView(
        force: 25.3,
        engaged: true,
        calibrating: false,
        waitingForSamples: false,
        calibrationTimeRemaining: 0,
        weightMedian: nil,
        targetWeight: 20.0,
        isOffTarget: true,
        offTargetDirection: -0.6,
        useLbs: false,
        onUnitToggle: {},
        onSettingsTap: {}
    )
}

#Preview("Calibrating") {
    StatusBarView(
        force: 0.0,
        engaged: false,
        calibrating: true,
        waitingForSamples: false,
        calibrationTimeRemaining: 3.5,
        weightMedian: nil,
        useLbs: false,
        onUnitToggle: {},
        onSettingsTap: {}
    )
}
