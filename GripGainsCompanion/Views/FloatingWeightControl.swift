import SwiftUI

/// Floating control for manually selecting target weight
/// Shows GG target weight (reference), adjustable weight with +/-, SET and Start buttons
struct FloatingWeightControl: View {
    let ggTargetWeight: Double?  // Current target from gripgains (reference)
    let suggestedWeight: Double?  // Suggested weight from median (adjustable)
    let useLbs: Bool
    let canDecrement: Bool
    let canIncrement: Bool
    let onIncrement: () -> Void
    let onDecrement: () -> Void
    let onSet: () -> Void
    let onReset: () -> Void  // Reset suggested weight to GG target
    let onStart: () -> Void  // Start the session

    /// Can set if we have a suggested weight that differs from current GG target
    private var canSet: Bool {
        guard let suggested = suggestedWeight else { return false }
        guard let gg = ggTargetWeight else { return true }  // Can set if no GG target yet
        // Compare with small tolerance for floating point
        return abs(suggested - gg) > 0.001
    }

    /// Can reset if suggested weight differs from GG target
    private var canReset: Bool {
        canSet  // Same logic - can reset when they differ
    }

    var body: some View {
        VStack(spacing: 8) {
            // GG target weight (reference) - tap to reset suggested weight
            if let gg = ggTargetWeight {
                Text("GG: \(WeightFormatter.format(gg, useLbs: useLbs, decimals: 2))")
                    .font(.caption)
                    .foregroundColor(canReset ? .blue : .secondary)
                    .onTapGesture {
                        if canReset { onReset() }
                    }
            }

            // Adjustable weight with +/- buttons
            HStack(spacing: 12) {
                Button(action: onDecrement) {
                    Image(systemName: "minus.circle.fill")
                        .font(.title2)
                        .foregroundColor(canDecrement ? .primary : .gray.opacity(0.5))
                }
                .disabled(!canDecrement)

                if let w = suggestedWeight {
                    Text(WeightFormatter.format(w, useLbs: useLbs, decimals: 2))
                        .font(.headline)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                } else {
                    Text("--")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }

                Button(action: onIncrement) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundColor(canIncrement ? .primary : .gray.opacity(0.5))
                }
                .disabled(!canIncrement)
            }

            // SET and Start buttons
            HStack(spacing: 12) {
                Button(action: onSet) {
                    Text("SET")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 6)
                        .background(canSet ? Color.blue : Color.gray)
                        .cornerRadius(8)
                }
                .disabled(!canSet)

                Button(action: onStart) {
                    Text("Start")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(Color(red: 99/255, green: 102/255, blue: 241/255))  // #6366f1 indigo
                        .cornerRadius(8)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

#Preview("With both weights") {
    FloatingWeightControl(
        ggTargetWeight: 20.0,
        suggestedWeight: 22.5,
        useLbs: false,
        canDecrement: true,
        canIncrement: true,
        onIncrement: {},
        onDecrement: {},
        onSet: {},
        onReset: {},
        onStart: {}
    )
    .padding()
    .background(Color.black)
}

#Preview("At minimum") {
    FloatingWeightControl(
        ggTargetWeight: 20.0,
        suggestedWeight: 5.0,
        useLbs: false,
        canDecrement: false,
        canIncrement: true,
        onIncrement: {},
        onDecrement: {},
        onSet: {},
        onReset: {},
        onStart: {}
    )
    .padding()
    .background(Color.black)
}

#Preview("No GG weight") {
    FloatingWeightControl(
        ggTargetWeight: nil,
        suggestedWeight: 20.0,
        useLbs: false,
        canDecrement: true,
        canIncrement: true,
        onIncrement: {},
        onDecrement: {},
        onSet: {},
        onReset: {},
        onStart: {}
    )
    .padding()
    .background(Color.black)
}
