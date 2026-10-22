import SwiftUI

/// Compact battery indicator for the connected device
struct BatteryBadge: View {
    let level: Int
    var color: Color = .secondary
    var font: Font = .caption2
    var showsBackground: Bool = false

    private var symbolName: String {
        switch level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbolName)
            Text("\(level)%")
                .monospacedDigit()
        }
        .font(font)
        .foregroundStyle(level <= 20 ? Color.red : color)
        .padding(.horizontal, showsBackground ? 5 : 0)
        .padding(.vertical, showsBackground ? 2 : 0)
        .background {
            if showsBackground {
                Capsule().fill(.ultraThinMaterial)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Device battery \(level) percent")
    }
}

#Preview {
    VStack(spacing: 12) {
        BatteryBadge(level: 92)
        BatteryBadge(level: 55)
        BatteryBadge(level: 12)
        BatteryBadge(level: 76, showsBackground: true)
    }
    .padding()
}
