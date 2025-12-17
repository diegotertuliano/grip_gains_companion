import SwiftUI

enum ForceBarTheme: String, CaseIterable {
    case system
    case light
    case dark

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

struct SettingsView: View {
    let deviceName: String?
    let isDeviceConnected: Bool
    @Binding var useLbs: Bool
    let webCoordinator: WebViewCoordinator
    let onDisconnect: () -> Void
    let onConnectDevice: () -> Void

    /// Target weight scraped from website (read-only display)
    let scrapedTargetWeight: Float?

    @Environment(\.dismiss) private var dismiss
    @AppStorage("enableHaptics") private var enableHaptics = true
    @AppStorage("enableTargetSound") private var enableTargetSound = true
    @AppStorage("showStatusBar") private var showStatusBar = true
    @AppStorage("fullScreen") private var fullScreen = true
    @AppStorage("forceBarTheme") private var forceBarTheme = ForceBarTheme.system.rawValue
    @AppStorage("useManualTarget") private var useManualTarget = false
    @AppStorage("manualTargetWeight") private var manualTargetWeight: Double = 20.0
    @AppStorage("weightTolerance") private var weightTolerance: Double = Double(AppConstants.defaultWeightTolerance)

    // State for wheel pickers
    @State private var targetWholeNumber: Int = 20
    @State private var targetDecimal: Int = 0  // 0, 5, 10, 15... 95
    @AppStorage("useKeyboardInput") private var useKeyboardInput: Bool = false
    @State private var manualTargetText: String = "20.00"
    @FocusState private var isTextFieldFocused: Bool

    // Decimal options (0.05 increments)
    private let decimalOptions = Array(stride(from: 0, through: 95, by: 5))

    var body: some View {
        NavigationStack {
            List {
                // Target Weight section
                Section("Target Weight") {
                    Toggle("Use Manual Target", isOn: $useManualTarget)

                    if !useManualTarget {
                        // Display scraped weight from website
                        HStack {
                            Text("From Website")
                            Spacer()
                            if let weight = scrapedTargetWeight {
                                Text(WeightFormatter.format(weight, useLbs: useLbs))
                                    .foregroundColor(.secondary)
                            } else {
                                Text("Not detected")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    if useManualTarget {
                        // Input mode selector - its own row
                        Picker("Input Mode", selection: $useKeyboardInput) {
                            Label("Wheels", systemImage: "dial.medium").tag(false)
                            Label("Keyboard", systemImage: "keyboard").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: useKeyboardInput) { oldValue, newValue in
                            if oldValue && !newValue {
                                // Switching from keyboard to wheels
                                parseManualTarget()
                                initializeWheelPickers()
                            } else if !oldValue && newValue {
                                // Switching from wheels to keyboard
                                manualTargetText = String(format: "%.2f", manualTargetWeight)
                            }
                        }

                        // Manual target input
                        HStack {
                            Text("Manual Target")
                            Spacer()

                            if useKeyboardInput {
                                // Keyboard input mode - plain string for natural typing
                                TextField("", text: $manualTargetText)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 80)
                                    .focused($isTextFieldFocused)
                                    .onChange(of: isTextFieldFocused) { _, focused in
                                        if !focused {
                                            parseManualTarget()
                                        }
                                    }

                                Text(useLbs ? "lbs" : "kg")
                                    .foregroundColor(.secondary)
                            } else {
                                // Wheel picker mode
                                Picker("", selection: $targetWholeNumber) {
                                    ForEach(0..<100, id: \.self) { num in
                                        Text("\(num)").tag(num)
                                    }
                                }
                                .pickerStyle(.wheel)
                                .frame(width: 50, height: 100)
                                .clipped()

                                Text(".")
                                    .font(.title3)

                                Picker("", selection: $targetDecimal) {
                                    ForEach(decimalOptions, id: \.self) { dec in
                                        Text(String(format: "%02d", dec)).tag(dec)
                                    }
                                }
                                .pickerStyle(.wheel)
                                .frame(width: 50, height: 100)
                                .clipped()

                                Text(useLbs ? "lbs" : "kg")
                                    .foregroundColor(.secondary)
                            }
                        }
                        .onChange(of: targetWholeNumber) { _, _ in syncTargetWeight() }
                        .onChange(of: targetDecimal) { _, _ in syncTargetWeight() }
                    }

                    HStack {
                        Text("Tolerance")
                        Spacer()
                        Text("±\(String(format: "%.1f", weightTolerance)) \(useLbs ? "lbs" : "kg")")
                            .foregroundColor(.secondary)
                        Stepper("", value: $weightTolerance, in: 0.1...5.0, step: 0.1)
                            .labelsHidden()
                    }
                }

                // Website section
                Section("Website") {
                    Button {
                        webCoordinator.reloadPage()
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                            Text("Refresh Page")
                        }
                    }

                    Button(role: .destructive) {
                        webCoordinator.clearWebsiteData()
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: "trash")
                            Text("Clear Website Data")
                        }
                    }
                }

                // Display section
                Section("Display") {
                    Toggle("Show Force Bar", isOn: $showStatusBar)
                    Toggle("Full Screen", isOn: $fullScreen)
                    Picker("Force Bar Theme", selection: $forceBarTheme) {
                        ForEach(ForceBarTheme.allCases, id: \.rawValue) { theme in
                            Text(theme.displayName).tag(theme.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                // Feedback section
                Section("Feedback") {
                    Toggle("Haptic Feedback", isOn: $enableHaptics)
                    Toggle("Target Weight Sounds", isOn: $enableTargetSound)
                }

                // Device section
                Section("Device") {
                    if isDeviceConnected {
                        if let name = deviceName {
                            HStack {
                                Text("Connected to")
                                Spacer()
                                Text(name)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Button(role: .destructive) {
                            onDisconnect()
                        } label: {
                            HStack {
                                Image(systemName: "wifi.slash")
                                Text("Disconnect")
                            }
                        }
                    } else {
                        Button {
                            onConnectDevice()
                        } label: {
                            HStack {
                                Image(systemName: "wave.3.right")
                                Text("Connect Device")
                            }
                        }
                    }
                }

                // Units section
                Section("Units") {
                    Picker("Weight", selection: $useLbs) {
                        Text("kg").tag(false)
                        Text("lbs").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                initializeWheelPickers()
                manualTargetText = String(format: "%.2f", manualTargetWeight)
            }
        }
    }

    // MARK: - Helper Methods

    /// Initialize wheel picker values from stored manualTargetWeight
    private func initializeWheelPickers() {
        let whole = Int(manualTargetWeight)
        let decimal = Int(round((manualTargetWeight - Double(whole)) * 100))
        // Round to nearest 5
        let roundedDecimal = (decimal / 5) * 5
        targetWholeNumber = whole
        targetDecimal = min(95, max(0, roundedDecimal))
    }

    /// Sync wheel picker values back to manualTargetWeight
    private func syncTargetWeight() {
        manualTargetWeight = Double(targetWholeNumber) + Double(targetDecimal) / 100.0
    }

    /// Parse text field input and update manualTargetWeight
    private func parseManualTarget() {
        // Handle both . and , as decimal separator
        let cleaned = manualTargetText.replacingOccurrences(of: ",", with: ".")
        if let value = Double(cleaned), value >= 0 {
            manualTargetWeight = value
        }
        // Reset text to formatted value
        manualTargetText = String(format: "%.2f", manualTargetWeight)
    }
}

#Preview("Connected") {
    SettingsView(
        deviceName: "Progressor_123",
        isDeviceConnected: true,
        useLbs: .constant(false),
        webCoordinator: WebViewCoordinator(),
        onDisconnect: {},
        onConnectDevice: {},
        scrapedTargetWeight: 20.0
    )
}

#Preview("No Device") {
    SettingsView(
        deviceName: nil,
        isDeviceConnected: false,
        useLbs: .constant(false),
        webCoordinator: WebViewCoordinator(),
        onDisconnect: {},
        onConnectDevice: {},
        scrapedTargetWeight: nil
    )
}
