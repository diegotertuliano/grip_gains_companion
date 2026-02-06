import SwiftUI
import SwiftData

// MARK: - Bounds Picker Row

struct BoundsPickerRow: View {
    let label: String
    @Binding var value: Double
    let options: [Double]  // In kg, includes 0 for "Off"
    let useLbs: Bool

    /// Binding that snaps to nearest picker option (handles floating-point imprecision)
    private var snappedBinding: Binding<Double> {
        Binding(
            get: {
                // Find nearest option to current value (within tolerance)
                let allOptions = [0.0] + options.filter { $0 > 0 }
                return allOptions.min(by: { abs($0 - value) < abs($1 - value) }) ?? value
            },
            set: { value = $0 }
        )
    }

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 30, alignment: .leading)

            Picker("", selection: snappedBinding) {
                Text("Off").tag(0.0)
                ForEach(options.filter { $0 > 0 }, id: \.self) { option in
                    let displayValue = useLbs ? option * Double(AppConstants.kgToLbs) : option
                    let unit = useLbs ? "lbs" : "kg"
                    Text(String(format: "%.1f %@", displayValue, unit)).tag(option)
                }
            }
            .pickerStyle(.wheel)
            .frame(height: 80)

            Button {
                value = 0
            } label: {
                Image(systemName: value == 0 ? "circle" : "xmark.circle.fill")
                    .foregroundColor(value == 0 ? .secondary : .red)
            }
            .buttonStyle(.plain)
            .disabled(value == 0)
        }
    }
}

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

// MARK: - Settings View

struct SettingsView: View {
    let deviceName: String?
    let isDeviceConnected: Bool
    @Binding var useLbs: Bool
    let webCoordinator: WebViewCoordinator
    let onDisconnect: () -> Void
    let onConnectDevice: () -> Void
    let onRecalibrate: () -> Void

    /// Target weight scraped from website (read-only display)
    let scrapedTargetWeight: Double?

    /// Device short name for dynamic text (e.g., "Tindeq", "PitchSix")
    var deviceShortName: String = "device"

    @Environment(\.dismiss) private var dismiss
    @AppStorage("enableHaptics") private var enableHaptics = AppConstants.defaultEnableHaptics
    @AppStorage("enableTargetSound") private var enableTargetSound = AppConstants.defaultEnableTargetSound
    @AppStorage("showGripStats") private var showGripStats = AppConstants.defaultShowGripStats
    @AppStorage("showSetReview") private var showSetReview = AppConstants.defaultShowSetReview
    @AppStorage("showStatusBar") private var showStatusBar = AppConstants.defaultShowStatusBar
    @AppStorage("expandedForceBar") private var expandedForceBar = AppConstants.defaultExpandedForceBar
    @AppStorage("showForceGraph") private var showForceGraph = AppConstants.defaultShowForceGraph
    @AppStorage("forceGraphWindow") private var forceGraphWindow = AppConstants.defaultForceGraphWindow
    @AppStorage("fullScreen") private var fullScreen = AppConstants.defaultFullScreen
    @AppStorage("forceBarTheme") private var forceBarTheme = ForceBarTheme.system.rawValue
    @AppStorage("enableTargetWeight") private var enableTargetWeight = AppConstants.defaultEnableTargetWeight
    @AppStorage("useManualTarget") private var useManualTarget = AppConstants.defaultUseManualTarget
    @AppStorage("manualTargetWeight") private var manualTargetWeight: Double = AppConstants.defaultManualTargetWeight
    @AppStorage("weightTolerance") private var weightTolerance: Double = AppConstants.defaultWeightTolerance

    // State for wheel pickers
    @State private var targetWholeNumber: Int = 20
    @State private var targetDecimal: Int = 0  // 0, 5, 10, 15... 95
    @AppStorage("useKeyboardInput") private var useKeyboardInput = AppConstants.defaultUseKeyboardInput
    @AppStorage("enableCalibration") private var enableCalibration = AppConstants.defaultEnableCalibration
    @AppStorage("backgroundTimeSync") private var backgroundTimeSync = AppConstants.defaultBackgroundTimeSync
    @AppStorage("enableLiveActivity") private var enableLiveActivity = AppConstants.defaultEnableLiveActivity
    @AppStorage("autoSelectWeight") private var autoSelectWeight = AppConstants.defaultAutoSelectWeight
    @AppStorage("autoSelectFromManual") private var autoSelectFromManual = AppConstants.defaultAutoSelectFromManual
    @AppStorage("enableEndSessionOnEarlyFail") private var enableEndSessionOnEarlyFail = AppConstants.defaultEnableEndSessionOnEarlyFail
    @AppStorage("earlyFailThresholdPercent") private var earlyFailThresholdPercent: Double = AppConstants.defaultEarlyFailThresholdPercent
    @AppStorage("enableICloudSync") private var enableICloudSync = AppConstants.defaultEnableICloudSync
    @AppStorage("engageThreshold") private var engageThreshold: Double = AppConstants.defaultEngageThreshold
    @AppStorage("failThreshold") private var failThreshold: Double = AppConstants.defaultFailThreshold
    @AppStorage("enablePercentageThresholds") private var enablePercentageThresholds = AppConstants.defaultEnablePercentageThresholds
    @AppStorage("engagePercentage") private var engagePercentage: Double = AppConstants.defaultEngagePercentage
    @AppStorage("disengagePercentage") private var disengagePercentage: Double = AppConstants.defaultDisengagePercentage
    @AppStorage("tolerancePercentage") private var tolerancePercentage: Double = AppConstants.defaultTolerancePercentage

    // Floor/ceiling bounds for percentage thresholds (stored in kg)
    @AppStorage("engageFloor") private var engageFloor: Double = AppConstants.defaultEngageFloor
    @AppStorage("engageCeiling") private var engageCeiling: Double = AppConstants.defaultEngageCeiling
    @AppStorage("disengageFloor") private var disengageFloor: Double = AppConstants.defaultDisengageFloor
    @AppStorage("disengageCeiling") private var disengageCeiling: Double = AppConstants.defaultDisengageCeiling
    @AppStorage("toleranceFloor") private var toleranceFloor: Double = AppConstants.defaultToleranceFloor
    @AppStorage("toleranceCeiling") private var toleranceCeiling: Double = AppConstants.defaultToleranceCeiling

    // Options for floor/ceiling pickers (in kg)
    private let engageFloorOptions: [Double] = Array(stride(from: 0.0, through: 20.0, by: 0.5))
    private let engageCeilingOptions: [Double] = Array(stride(from: 0.0, through: 100.0, by: 1.0))
    private let disengageFloorOptions: [Double] = Array(stride(from: 0.0, through: 10.0, by: 0.5))
    private let disengageCeilingOptions: [Double] = Array(stride(from: 0.0, through: 50.0, by: 1.0))
    private let toleranceFloorOptions: [Double] = Array(stride(from: 0.0, through: 5.0, by: 0.1))
    private let toleranceCeilingOptions: [Double] = Array(stride(from: 0.0, through: 10.0, by: 0.1))

    @State private var manualTargetText: String = "20.00"
    @State private var showThresholdOptions = false
    @State private var showResetConfirmation = false
    @State private var showHistorySheet = false
    @FocusState private var isTextFieldFocused: Bool

    // Decimal options (0.05 increments)
    private let decimalOptions = Array(stride(from: 0, through: 95, by: 5))

    /// Current effective target weight for percentage calculations (uses manual or scraped based on settings)
    private var effectiveTargetWeight: Double? {
        if useManualTarget {
            return manualTargetWeight
        }
        return scrapedTargetWeight
    }

    var body: some View {
        NavigationStack {
            List {
                // History section
                Section("History") {
                    Button("View Session History") {
                        showHistorySheet = true
                    }
                    Toggle("iCloud Sync", isOn: $enableICloudSync)
                    Text("Syncs session data across devices and saves CSV files to iCloud Drive. Restart app after changing.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Target Weight section (only shown when device is connected)
                if isDeviceConnected {
                    Section("Target Weight") {
                    Toggle("Enable Target Weight", isOn: $enableTargetWeight)

                    if enableTargetWeight {
                    Picker("Source", selection: $useManualTarget) {
                        Text("Auto").tag(false)
                        Text("Manual").tag(true)
                    }
                    .pickerStyle(.segmented)

                    if !useManualTarget {
                        // Auto mode - show detected weight
                        HStack {
                            Text("Target")
                            Spacer()
                            if let weight = scrapedTargetWeight {
                                Text(WeightFormatter.format(weight, useLbs: useLbs))
                                    .foregroundColor(.secondary)
                            } else {
                                Text("Not detected")
                                    .foregroundColor(.secondary)
                            }
                        }
                        Text("Target weight is automatically read from the timer page")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
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
                        Button {
                            onRecalibrate()
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                Text("Recalibrate Tare")
                            }
                        }

                        Toggle("Tare on Startup", isOn: $enableCalibration)
                        Text("Zeros the scale when \(deviceShortName) connects to detect grip and fail states. Does not affect hardware tare or displayed force.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Toggle("Use Percentage Thresholds", isOn: $enablePercentageThresholds)
                        if enablePercentageThresholds {
                            Text("Thresholds scale with target weight from Auto or Manual source above")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Button {
                                withAnimation {
                                    showThresholdOptions.toggle()
                                }
                            } label: {
                                HStack {
                                    Text(showThresholdOptions ? "Hide Options" : "Show Options")
                                    Spacer()
                                    Image(systemName: showThresholdOptions ? "chevron.up" : "chevron.down")
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        if enablePercentageThresholds && showThresholdOptions {
                            // Engage percentage with bounds
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Engage")
                                    Spacer()
                                    Text(formatPercentageThreshold(engagePercentage, label: "engage"))
                                        .foregroundColor(.secondary)
                                    Stepper("", value: $engagePercentage, in: 0.10...0.90, step: 0.05)
                                        .labelsHidden()
                                }
                                .onChange(of: engagePercentage) { _, newValue in
                                    if disengagePercentage >= newValue {
                                        disengagePercentage = max(0.05, newValue - 0.10)
                                    }
                                }

                                BoundsPickerRow(
                                    label: "Min",
                                    value: $engageFloor,
                                    options: engageFloorOptions,
                                    useLbs: useLbs
                                )
                                BoundsPickerRow(
                                    label: "Max",
                                    value: $engageCeiling,
                                    options: engageCeilingOptions,
                                    useLbs: useLbs
                                )
                            }

                            // Disengage percentage with bounds
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Disengage")
                                    Spacer()
                                    Text(formatPercentageThreshold(disengagePercentage, label: "disengage"))
                                        .foregroundColor(.secondary)
                                    Stepper("", value: $disengagePercentage, in: 0.05...0.50, step: 0.05)
                                        .labelsHidden()
                                }
                                .onChange(of: disengagePercentage) { _, newValue in
                                    if newValue >= engagePercentage {
                                        disengagePercentage = max(0.05, engagePercentage - 0.10)
                                    }
                                }

                                BoundsPickerRow(
                                    label: "Min",
                                    value: $disengageFloor,
                                    options: disengageFloorOptions,
                                    useLbs: useLbs
                                )
                                BoundsPickerRow(
                                    label: "Max",
                                    value: $disengageCeiling,
                                    options: disengageCeilingOptions,
                                    useLbs: useLbs
                                )
                            }

                            // Tolerance percentage with bounds
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Tolerance")
                                    Spacer()
                                    Text(formatPercentageThreshold(tolerancePercentage, label: "tolerance"))
                                        .foregroundColor(.secondary)
                                    Stepper("", value: $tolerancePercentage, in: 0.01...0.20, step: 0.01)
                                        .labelsHidden()
                                }

                                BoundsPickerRow(
                                    label: "Min",
                                    value: $toleranceFloor,
                                    options: toleranceFloorOptions,
                                    useLbs: useLbs
                                )
                                BoundsPickerRow(
                                    label: "Max",
                                    value: $toleranceCeiling,
                                    options: toleranceCeilingOptions,
                                    useLbs: useLbs
                                )
                            }

                            Text("Min/Max bound the calculated threshold. Set to Off to disable.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        if !enablePercentageThresholds {
                            // Fixed kg thresholds (original behavior)
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

                            HStack {
                                Text("Tolerance")
                                Spacer()
                                Text("±\(String(format: "%.1f", weightTolerance)) \(useLbs ? "lbs" : "kg")")
                                    .foregroundColor(.secondary)
                                Stepper("", value: $weightTolerance, in: 0.1...5.0, step: 0.1)
                                    .labelsHidden()
                            }
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
                            Text("1s").tag(1)
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
                    Toggle("End-of-Set Summary", isOn: $showSetReview)
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
                                Spacer()
                                Image(systemName: "wifi.slash")
                                Text("Disconnect")
                                Spacer()
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

                // Timer section
                Section("Experimental") {
                    Toggle("Background Timer Sync", isOn: $backgroundTimeSync)
                    Text("Keeps the timer accurate when the app is in background.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if backgroundTimeSync {
                        Toggle("Live Activity", isOn: $enableLiveActivity)
                        Text("Shows elapsed and remaining time in Dynamic Island when backgrounded.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Toggle("Auto-set Target Weight", isOn: $autoSelectWeight)
                    if autoSelectWeight {
                        Picker("Source", selection: $autoSelectFromManual) {
                            Text("Measured").tag(false)
                            Text("Manual").tag(true)
                        }
                        .pickerStyle(.segmented)
                        Text(autoSelectFromManual
                            ? "Uses manual target weight from settings above."
                            : "Uses measured weight when you pick up a weight.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Toggle("Balrog Avoidance", isOn: $enableEndSessionOnEarlyFail)
                    if enableEndSessionOnEarlyFail {
                        HStack {
                            Text("Threshold")
                            Spacer()
                            Text("\(Int(round(earlyFailThresholdPercent * 100)))%")
                                .foregroundColor(.secondary)
                            Stepper("", value: $earlyFailThresholdPercent,
                                    in: AppConstants.minEarlyFailThresholdPercent...AppConstants.maxEarlyFailThresholdPercent,
                                    step: 0.05)
                                .labelsHidden()
                        }
                        Text("Abort session if grip fails before this % of target duration.")
                            .font(.caption)
                            .foregroundColor(.secondary)
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

                // Reset section
                Section {
                    Button(role: .destructive) {
                        showResetConfirmation = true
                    } label: {
                        HStack {
                            Spacer()
                            Image(systemName: "arrow.counterclockwise")
                            Text("Reset to Defaults")
                            Spacer()
                        }
                    }
                    .alert("Reset to Defaults", isPresented: $showResetConfirmation) {
                        Button("Reset", role: .destructive) {
                            resetToDefaults()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This will restore all settings to their recommended values.")
                    }
                } footer: {
                    Text("Restores all settings to their recommended values.")
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
        } // NavigationStack
        .sheet(isPresented: $showHistorySheet) {
            SessionHistorySheet()
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

    /// Reset all settings to their default values
    private func resetToDefaults() {
        // Feedback
        enableHaptics = AppConstants.defaultEnableHaptics
        enableTargetSound = AppConstants.defaultEnableTargetSound
        showGripStats = AppConstants.defaultShowGripStats
        showSetReview = AppConstants.defaultShowSetReview

        // Display
        showStatusBar = AppConstants.defaultShowStatusBar
        expandedForceBar = AppConstants.defaultExpandedForceBar
        showForceGraph = AppConstants.defaultShowForceGraph
        forceGraphWindow = AppConstants.defaultForceGraphWindow

        // Target weight
        enableTargetWeight = AppConstants.defaultEnableTargetWeight
        useManualTarget = AppConstants.defaultUseManualTarget
        manualTargetWeight = AppConstants.defaultManualTargetWeight
        weightTolerance = AppConstants.defaultWeightTolerance

        // Calibration & experimental
        enableCalibration = AppConstants.defaultEnableCalibration
        backgroundTimeSync = AppConstants.defaultBackgroundTimeSync
        enableLiveActivity = AppConstants.defaultEnableLiveActivity
        autoSelectWeight = AppConstants.defaultAutoSelectWeight
        autoSelectFromManual = AppConstants.defaultAutoSelectFromManual
        useKeyboardInput = AppConstants.defaultUseKeyboardInput
        enableEndSessionOnEarlyFail = AppConstants.defaultEnableEndSessionOnEarlyFail
        earlyFailThresholdPercent = AppConstants.defaultEarlyFailThresholdPercent

        // Data
        enableICloudSync = AppConstants.defaultEnableICloudSync

        // Fixed thresholds
        engageThreshold = AppConstants.defaultEngageThreshold
        failThreshold = AppConstants.defaultFailThreshold

        // Percentage thresholds
        enablePercentageThresholds = AppConstants.defaultEnablePercentageThresholds
        engagePercentage = AppConstants.defaultEngagePercentage
        disengagePercentage = AppConstants.defaultDisengagePercentage
        tolerancePercentage = AppConstants.defaultTolerancePercentage

        // Floor/ceiling bounds
        engageFloor = AppConstants.defaultEngageFloor
        engageCeiling = AppConstants.defaultEngageCeiling
        disengageFloor = AppConstants.defaultDisengageFloor
        disengageCeiling = AppConstants.defaultDisengageCeiling
        toleranceFloor = AppConstants.defaultToleranceFloor
        toleranceCeiling = AppConstants.defaultToleranceCeiling

        // Reinitialize wheel pickers to reflect new values
        initializeWheelPickers()
        let displayValue = useLbs ? manualTargetWeight * Double(AppConstants.kgToLbs) : manualTargetWeight
        manualTargetText = String(format: "%.2f", displayValue)
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

    /// Format percentage threshold with calculated kg value (applying floor/ceiling bounds)
    private func formatPercentageThreshold(_ percentage: Double, label: String) -> String {
        let percentText = "\(Int(percentage * 100))%"
        if let target = effectiveTargetWeight {
            let rawKg = Double(target) * percentage

            // Apply floor/ceiling bounds (0 = disabled)
            let clampedKg: Double
            switch label {
            case "engage":
                let floored = engageFloor > 0 ? max(rawKg, engageFloor) : rawKg
                clampedKg = engageCeiling > 0 ? min(floored, engageCeiling) : floored
            case "disengage":
                let floored = disengageFloor > 0 ? max(rawKg, disengageFloor) : rawKg
                clampedKg = disengageCeiling > 0 ? min(floored, disengageCeiling) : floored
            case "tolerance":
                let floored = toleranceFloor > 0 ? max(rawKg, toleranceFloor) : rawKg
                clampedKg = toleranceCeiling > 0 ? min(floored, toleranceCeiling) : floored
            default:
                clampedKg = rawKg
            }

            let displayValue = useLbs ? clampedKg * Double(AppConstants.kgToLbs) : clampedKg
            let unit = useLbs ? "lbs" : "kg"

            if label == "tolerance" {
                return "\(percentText) (±\(String(format: "%.1f", displayValue)) \(unit))"
            }
            return "\(percentText) (\(String(format: "%.1f", displayValue)) \(unit))"
        }
        return percentText
    }

    /// Format floor/ceiling value for display (0 = Off for both)
    private func formatBoundsValue(_ valueInKg: Double, isFloor: Bool = false, isCeiling: Bool = false) -> String {
        if valueInKg == 0 {
            return "Off"
        }
        let displayValue = useLbs ? valueInKg * Double(AppConstants.kgToLbs) : valueInKg
        let unit = useLbs ? "lbs" : "kg"
        return String(format: "%.1f %@", displayValue, unit)
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
        onRecalibrate: {},
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
        onRecalibrate: {},
        scrapedTargetWeight: nil
    )
}
