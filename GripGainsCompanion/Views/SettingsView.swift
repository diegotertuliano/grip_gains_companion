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
    @AppStorage("showGripStats") private var showGripStats = true
    @AppStorage("showStatusBar") private var showStatusBar = true
    @AppStorage("expandedForceBar") private var expandedForceBar = false
    @AppStorage("showForceGraph") private var showForceGraph = false
    @AppStorage("forceGraphWindow") private var forceGraphWindow = 10  // seconds, 0 = entire session
    @AppStorage("fullScreen") private var fullScreen = true
    @AppStorage("forceBarTheme") private var forceBarTheme = ForceBarTheme.system.rawValue
    @AppStorage("enableTargetWeight") private var enableTargetWeight = true
    @AppStorage("useManualTarget") private var useManualTarget = false
    @AppStorage("manualTargetWeight") private var manualTargetWeight: Double = 20.0
    @AppStorage("weightTolerance") private var weightTolerance: Double = Double(AppConstants.defaultWeightTolerance)

    // State for wheel pickers
    @State private var targetWholeNumber: Int = 20
    @State private var targetDecimal: Int = 0  // 0, 5, 10, 15... 95
    @AppStorage("useKeyboardInput") private var useKeyboardInput: Bool = false
    @AppStorage("enableCalibration") private var enableCalibration = true
    @AppStorage("engageThreshold") private var engageThreshold: Double = 3.0  // stored in kg
    @AppStorage("failThreshold") private var failThreshold: Double = 1.0      // stored in kg
    @State private var manualTargetText: String = "20.00"
    @FocusState private var isTextFieldFocused: Bool

    // Decimal options (0.05 increments)
    private let decimalOptions = Array(stride(from: 0, through: 95, by: 5))

    var body: some View {
        NavigationStack {
            List {
                // Target Weight section (only shown when device is connected)
                if isDeviceConnected {
                    Section("Target Weight") {
                    Toggle("Enable Target Weight", isOn: $enableTargetWeight)

                    if enableTargetWeight {
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
                    }  // if enableTargetWeight
                    }  // Section
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

                // Grip Detection section (only shown when device is connected)
                if isDeviceConnected {
                    Section("Grip Detection") {
                        Toggle("Tare on Startup", isOn: $enableCalibration)
                        Text("Zeros the scale when Tindeq connects to detect grip and fail states. Does not affect hardware tare or displayed force.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        HStack {
                            Text("Engage Threshold")
                            Spacer()
                            Text(formatThreshold(engageThreshold))
                                .foregroundColor(.secondary)
                            Stepper("",
                                value: Binding(
                                    get: { useLbs ? engageThreshold * Double(AppConstants.kgToLbs) : engageThreshold },
                                    set: { newValue in
                                        engageThreshold = useLbs ? newValue / Double(AppConstants.kgToLbs) : newValue
                                        // Ensure fail threshold stays below engage threshold
                                        if failThreshold >= engageThreshold {
                                            failThreshold = max(Double(AppConstants.minGripThreshold), engageThreshold - 0.5)
                                        }
                                    }
                                ),
                                in: useLbs ? 1.0...22.0 : 0.5...Double(AppConstants.maxEngageThreshold),
                                step: useLbs ? 1.0 : 0.5
                            )
                            .labelsHidden()
                        }

                        HStack {
                            Text("Fail Threshold")
                            Spacer()
                            Text(formatThreshold(failThreshold))
                                .foregroundColor(.secondary)
                            Stepper("",
                                value: Binding(
                                    get: { useLbs ? failThreshold * Double(AppConstants.kgToLbs) : failThreshold },
                                    set: { newValue in
                                        let newKg = useLbs ? newValue / Double(AppConstants.kgToLbs) : newValue
                                        // Clamp to be less than engage threshold
                                        failThreshold = min(newKg, engageThreshold - 0.5)
                                    }
                                ),
                                in: useLbs ? 1.0...11.0 : 0.5...Double(AppConstants.maxFailThreshold),
                                step: useLbs ? 1.0 : 0.5
                            )
                            .labelsHidden()
                        }
                    }
                }

                // Display section
                Section("Display") {
                    Toggle("Show Force Bar", isOn: $showStatusBar)
                    Toggle("Expanded Force Bar", isOn: $expandedForceBar)
                    Toggle("Force Graph", isOn: $showForceGraph)
                    if showForceGraph {
                        Picker("Graph Window", selection: $forceGraphWindow) {
                            Text("5s").tag(5)
                            Text("10s").tag(10)
                            Text("30s").tag(30)
                            Text("All").tag(0)
                        }
                        .pickerStyle(.segmented)
                    }
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
                    Toggle("Grip Statistics", isOn: $showGripStats)
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
                let displayValue = useLbs ? manualTargetWeight * Double(AppConstants.kgToLbs) : manualTargetWeight
                manualTargetText = String(format: "%.2f", displayValue)
            }
            .onChange(of: useLbs) { _, _ in
                // Re-initialize inputs when unit changes to show correct value in new unit
                initializeWheelPickers()
                let displayValue = useLbs ? manualTargetWeight * Double(AppConstants.kgToLbs) : manualTargetWeight
                manualTargetText = String(format: "%.2f", displayValue)
            }
        }
    }

    // MARK: - Helper Methods

    /// Initialize wheel picker values from stored manualTargetWeight (stored in kg, displayed in user's unit)
    private func initializeWheelPickers() {
        let displayValue = useLbs ? manualTargetWeight * Double(AppConstants.kgToLbs) : manualTargetWeight
        let whole = Int(displayValue)
        let decimal = Int(round((displayValue - Double(whole)) * 100))
        // Round to nearest 5
        let roundedDecimal = (decimal / 5) * 5
        targetWholeNumber = whole
        targetDecimal = min(95, max(0, roundedDecimal))
    }

    /// Sync wheel picker values back to manualTargetWeight (stored in kg)
    private func syncTargetWeight() {
        let displayValue = Double(targetWholeNumber) + Double(targetDecimal) / 100.0
        manualTargetWeight = useLbs ? displayValue / Double(AppConstants.kgToLbs) : displayValue
    }

    /// Parse text field input and update manualTargetWeight (stored in kg)
    private func parseManualTarget() {
        // Handle both . and , as decimal separator
        let cleaned = manualTargetText.replacingOccurrences(of: ",", with: ".")
        if let value = Double(cleaned), value >= 0 {
            manualTargetWeight = useLbs ? value / Double(AppConstants.kgToLbs) : value
        }
        // Reset text to formatted value (in display units)
        let displayValue = useLbs ? manualTargetWeight * Double(AppConstants.kgToLbs) : manualTargetWeight
        manualTargetText = String(format: "%.2f", displayValue)
    }

    /// Format threshold value in user's preferred unit
    private func formatThreshold(_ valueInKg: Double) -> String {
        if useLbs {
            let lbs = valueInKg * Double(AppConstants.kgToLbs)
            return String(format: "%.1f lbs", lbs)
        } else {
            return String(format: "%.1f kg", valueInKg)
        }
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
