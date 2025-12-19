import SwiftUI
import Combine

// MARK: - Auto Select Weight Modifier

struct AutoSelectWeightModifier: ViewModifier {
    let autoSelectWeight: Bool
    let autoSelectFromManual: Bool
    let manualTargetWeight: Double
    let webCoordinator: WebViewCoordinator

    func body(content: Content) -> some View {
        content
            .onChange(of: autoSelectFromManual) { _, useManual in
                if autoSelectWeight, useManual {
                    webCoordinator.setTargetWeight(Float(manualTargetWeight))
                }
            }
            .onChange(of: manualTargetWeight) { _, _ in
                if autoSelectWeight, autoSelectFromManual {
                    webCoordinator.setTargetWeight(Float(manualTargetWeight))
                }
            }
    }
}

// MARK: - Stats Change Modifier

struct StatsChangeModifier: ViewModifier {
    let sessionMean: Float?
    let sessionStdDev: Float?
    let engaged: Bool
    @Binding var displayedMean: Float?
    @Binding var displayedStdDev: Float?
    @Binding var statsHideTimer: Timer?

    func body(content: Content) -> some View {
        content
            .onChange(of: sessionMean) { _, newValue in
                if let mean = newValue { displayedMean = mean }
            }
            .onChange(of: sessionStdDev) { _, newValue in
                if let stdDev = newValue { displayedStdDev = stdDev }
            }
            .onChange(of: engaged) { oldValue, newValue in
                if oldValue && !newValue {
                    statsHideTimer?.invalidate()
                    statsHideTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: false) { _ in
                        DispatchQueue.main.async {
                            displayedMean = nil
                            displayedStdDev = nil
                        }
                    }
                } else if !oldValue && newValue {
                    statsHideTimer?.invalidate()
                    statsHideTimer = nil
                }
            }
    }
}

/// Main view that orchestrates all components
struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var bluetoothManager = BluetoothManager()
    @StateObject private var progressorHandler = ProgressorHandler()
    @StateObject private var activityManager = ActivityManager()

    @State private var isFailButtonEnabled = false
    @State private var isConnected = false
    @State private var skippedDevice = false
    @State private var showSettings = false
    @State private var cancellables = Set<AnyCancellable>()
    @State private var scrapedTargetWeight: Float?
    @State private var scrapedTargetDuration: Int?
    @State private var scrapedRemainingTime: Int?
    @AppStorage("useLbs") private var useLbs = false
    @AppStorage("enableHaptics") private var enableHaptics = true
    @AppStorage("enableTargetSound") private var enableTargetSound = true
    @AppStorage("showStatusBar") private var showStatusBar = true
    @AppStorage("expandedForceBar") private var expandedForceBar = false
    @AppStorage("showForceGraph") private var showForceGraph = false
    @AppStorage("forceGraphWindow") private var forceGraphWindow = 10
    @AppStorage("fullScreen") private var fullScreen = true
    @AppStorage("forceBarTheme") private var forceBarTheme = ForceBarTheme.system.rawValue
    @AppStorage("settingsButtonX") private var settingsButtonX: Double = -1
    @AppStorage("settingsButtonY") private var settingsButtonY: Double = -1
    @AppStorage("enableTargetWeight") private var enableTargetWeight = true
    @AppStorage("useManualTarget") private var useManualTarget = false
    @AppStorage("manualTargetWeight") private var manualTargetWeight: Double = 20.0
    @AppStorage("showGripStats") private var showGripStats = true
    @AppStorage("weightTolerance") private var weightTolerance: Double = Double(AppConstants.defaultWeightTolerance)
    @AppStorage("enableCalibration") private var enableCalibration = true
    @AppStorage("engageThreshold") private var engageThreshold: Double = 3.0
    @AppStorage("failThreshold") private var failThreshold: Double = 1.0
    @AppStorage("backgroundTimeSync") private var backgroundTimeSync = true
    @AppStorage("enableLiveActivity") private var enableLiveActivity = false
    @AppStorage("autoSelectWeight") private var autoSelectWeight = false
    @AppStorage("autoSelectFromManual") private var autoSelectFromManual = false
    @State private var dragOffset: CGSize = .zero
    @State private var displayedMean: Float?
    @State private var displayedStdDev: Float?
    @State private var statsHideTimer: Timer?
    @State private var buttonStateTimer: Timer?
    @State private var backgroundedAt: Date?
    @State private var wasGrippingAtBackground: Bool = false

    // Weight picker state
    @State private var availableWeights: [Float] = []
    @State private var availableWeightsIsLbs: Bool = false
    @State private var suggestedWeightKg: Float? = nil  // Suggested weight in kg
    @State private var weightControlDragOffset: CGSize = .zero
    @AppStorage("weightControlX") private var weightControlX: Double = -1
    @AppStorage("weightControlY") private var weightControlY: Double = -1

    // Session info (for detecting exercise changes)
    @State private var scrapedGripper: String? = nil
    @State private var scrapedSide: String? = nil
    @State private var isSettingsVisible: Bool = true  // Whether advanced-settings-header is visible in web UI

    private let webCoordinator = WebViewCoordinator()

    private var preferredScheme: ColorScheme? {
        switch ForceBarTheme(rawValue: forceBarTheme) ?? .system {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }

    var body: some View {
        Group {
            if isConnected || skippedDevice {
                mainView
            } else {
                ZStack {
                    DeviceScannerView(
                        bluetoothManager: bluetoothManager,
                        onDeviceSelected: { device in
                            bluetoothManager.connect(to: device)
                        },
                        onSkipDevice: {
                            skippedDevice = true
                        }
                    )

                    // Hidden WebView to preload WebKit processes and cache page
                    TimerWebView(coordinator: webCoordinator)
                        .frame(width: 0, height: 0)
                        .opacity(0)
                }
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            setupSubscriptions()
        }
        .onChange(of: bluetoothManager.connectionState) { _, newState in
            isConnected = (newState == .connected)

            if newState == .connected && enableHaptics {
                HapticManager.success()
            }

            if newState == .disconnected {
                progressorHandler.reset()
            }
        }
        .onChange(of: isFailButtonEnabled) { _, newValue in
            progressorHandler.canEngage = newValue
            // Scrape weight options when fail button becomes enabled (page is ready)
            if newValue && autoSelectWeight && availableWeights.isEmpty {
                webCoordinator.scrapeWeightOptions()
            }
        }
        .onChange(of: autoSelectWeight) { _, enabled in
            // Scrape weight options when feature is enabled
            if enabled && availableWeights.isEmpty {
                webCoordinator.scrapeWeightOptions()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .inactive:
                // Start Live Activity only when actively gripping (not during prep)
                wasGrippingAtBackground = progressorHandler.engaged
                if enableLiveActivity, progressorHandler.engaged, let remaining = scrapedRemainingTime {
                    let elapsed = progressorHandler.gripElapsedSeconds
                    activityManager.startActivity(elapsedSeconds: elapsed, remainingSeconds: remaining)
                }
            case .background:
                if backgroundTimeSync {
                    backgroundedAt = Date()
                    webCoordinator.recordBackgroundStart()
                }
            case .active:
                // Only add background time if we were gripping when we went to background
                // This prevents prep time from being added to grip elapsed
                if backgroundTimeSync, wasGrippingAtBackground, let backgroundedAt = backgroundedAt {
                    let elapsedMs = Date().timeIntervalSince(backgroundedAt) * 1000
                    webCoordinator.addBackgroundTime(milliseconds: elapsedMs)
                }
                self.backgroundedAt = nil
                // End Live Activity when returning to foreground
                activityManager.endActivity()
            default:
                break
            }
        }
        .statusBarHidden(fullScreen)
    }

    // MARK: - Main View

    private var mainContent: some View {
        VStack(spacing: 0) {
            if isConnected && showStatusBar {
                statusBarView
            }
            if isConnected && showForceGraph {
                forceGraphView
            }
            TimerWebView(coordinator: webCoordinator)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private var forceGraphView: some View {
        ForceGraphView(
            forceHistory: progressorHandler.forceHistory,
            useLbs: useLbs,
            windowSeconds: forceGraphWindow,
            targetWeight: effectiveTargetWeight,
            tolerance: Float(weightTolerance)
        )
    }

    private var settingsSheet: some View {
        SettingsView(
            deviceName: bluetoothManager.connectedDeviceName,
            isDeviceConnected: isConnected,
            useLbs: $useLbs,
            webCoordinator: webCoordinator,
            onDisconnect: {
                showSettings = false
                bluetoothManager.disconnect()
            },
            onConnectDevice: {
                showSettings = false
                skippedDevice = false
            },
            onRecalibrate: {
                showSettings = false
                progressorHandler.recalibrate()
                webCoordinator.refreshButtonState()
            },
            scrapedTargetWeight: scrapedTargetWeight
        )
    }

    private var mainView: some View {
        mainViewWithOverlays
            .modifier(AutoSelectWeightModifier(
                autoSelectWeight: autoSelectWeight,
                autoSelectFromManual: autoSelectFromManual,
                manualTargetWeight: manualTargetWeight,
                webCoordinator: webCoordinator
            ))
            .modifier(StatsChangeModifier(
                sessionMean: progressorHandler.sessionMean,
                sessionStdDev: progressorHandler.sessionStdDev,
                engaged: progressorHandler.engaged,
                displayedMean: $displayedMean,
                displayedStdDev: $displayedStdDev,
                statsHideTimer: $statsHideTimer
            ))
            .preferredColorScheme(preferredScheme)
    }

    private var mainViewWithOverlays: some View {
        mainViewWithHandlers
            .overlay { settingsButtonOverlay }
            .overlay { floatingWeightControlOverlay }
            .sheet(isPresented: $showSettings) { settingsSheet }
    }

    private var mainViewWithHandlers: some View {
        mainContent
            .onChange(of: useManualTarget) { _, _ in updateTargetWeight() }
            .onChange(of: manualTargetWeight) { _, _ in updateTargetWeight() }
            .onChange(of: scrapedTargetWeight) { _, newValue in
                updateTargetWeight()
                // Initialize suggested weight to GG target
                if let target = newValue {
                    suggestedWeightKg = target
                }
            }
            .onChange(of: progressorHandler.weightMedian) { _, newMedian in
                // Update suggested weight when measurement is taken
                if autoSelectWeight, let median = newMedian {
                    suggestedWeightKg = median
                }
            }
            .onChange(of: progressorHandler.engaged) { oldValue, newValue in
                if oldValue && !newValue && autoSelectWeight {
                    webCoordinator.scrapeWeightOptions()
                }
            }
            .onChange(of: scrapedGripper) { _, _ in
                // Exercise changed, re-scrape weight options for correct increments
                webCoordinator.scrapeWeightOptions()
            }
            .onChange(of: scrapedSide) { _, _ in
                // Side changed, re-scrape weight options for correct increments
                webCoordinator.scrapeWeightOptions()
            }
            .onChange(of: weightTolerance) { _, newValue in
                progressorHandler.weightTolerance = Float(newValue)
            }
            .onChange(of: enableCalibration) { _, newValue in
                progressorHandler.enableCalibration = newValue
            }
            .onChange(of: engageThreshold) { _, newValue in
                progressorHandler.engageThreshold = Float(newValue)
            }
            .onChange(of: failThreshold) { _, newValue in
                progressorHandler.failThreshold = Float(newValue)
            }
    }

    // MARK: - Target Weight

    /// The effective target weight to use (manual or scraped), or nil if disabled
    private var effectiveTargetWeight: Float? {
        guard enableTargetWeight else { return nil }
        // When auto-select is enabled, always use scraped value (what's in web UI)
        if autoSelectWeight {
            return scrapedTargetWeight
        }
        if useManualTarget {
            return Float(manualTargetWeight)
        }
        return scrapedTargetWeight
    }

    // MARK: - Statistics Display

    /// The mean to display (respects showGripStats setting)
    private var effectiveSessionMean: Float? {
        showGripStats ? displayedMean : nil
    }

    /// The std dev to display (respects showGripStats setting)
    private var effectiveSessionStdDev: Float? {
        showGripStats ? displayedStdDev : nil
    }

    // MARK: - Settings Button Overlay

    @ViewBuilder
    private var settingsButtonOverlay: some View {
        if (!isConnected || !showStatusBar) && !showSettings {
            GeometryReader { geometry in
                let buttonSize: CGFloat = 44
                let defaultX = geometry.size.width - buttonSize - 16
                let defaultY: CGFloat = 8
                let currentX = settingsButtonX < 0 ? defaultX : settingsButtonX
                let currentY = settingsButtonY < 0 ? defaultY : settingsButtonY

                Image(systemName: "gearshape.fill")
                    .font(.title2)
                    .foregroundColor(.secondary)
                    .frame(width: buttonSize, height: buttonSize)
                    .background(.ultraThinMaterial, in: Circle())
                    .position(
                        x: currentX + buttonSize / 2 + dragOffset.width,
                        y: currentY + buttonSize / 2 + dragOffset.height
                    )
                    .onTapGesture {
                        showSettings = true
                    }
                    .gesture(
                        DragGesture(minimumDistance: 10)
                            .onChanged { value in
                                dragOffset = value.translation
                            }
                            .onEnded { value in
                                let newX = currentX + value.translation.width
                                let newY = currentY + value.translation.height
                                settingsButtonX = max(0, min(newX, geometry.size.width - buttonSize))
                                settingsButtonY = max(0, min(newY, geometry.size.height - buttonSize))
                                dragOffset = .zero
                            }
                    )
            }
        }
    }

    // MARK: - Floating Weight Control Overlay

    @ViewBuilder
    private var floatingWeightControlOverlay: some View {
        // Show when feature enabled, connected, we have a suggested weight, and advanced-settings-header is visible
        if autoSelectWeight && (isConnected || skippedDevice) && suggestedWeightKg != nil && isSettingsVisible {
            GeometryReader { geometry in
                let controlWidth: CGFloat = 160
                let controlHeight: CGFloat = 100
                let defaultX = (geometry.size.width - controlWidth) / 2
                let defaultY = geometry.size.height - controlHeight - 100
                let currentX = weightControlX < 0 ? defaultX : weightControlX
                let currentY = weightControlY < 0 ? defaultY : weightControlY

                FloatingWeightControl(
                    ggTargetWeight: scrapedTargetWeight,
                    suggestedWeight: suggestedWeightKg,
                    useLbs: useLbs,
                    canDecrement: canDecrementSuggestedWeight,
                    canIncrement: canIncrementSuggestedWeight,
                    onIncrement: { incrementSuggestedWeight() },
                    onDecrement: { decrementSuggestedWeight() },
                    onSet: { setSuggestedWeightInWebUI() }
                )
                .position(
                    x: currentX + controlWidth / 2 + weightControlDragOffset.width,
                    y: currentY + controlHeight / 2 + weightControlDragOffset.height
                )
                .gesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { value in
                            weightControlDragOffset = value.translation
                        }
                        .onEnded { value in
                            let newX = currentX + value.translation.width
                            let newY = currentY + value.translation.height
                            weightControlX = max(0, min(newX, geometry.size.width - controlWidth))
                            weightControlY = max(0, min(newY, geometry.size.height - controlHeight))
                            weightControlDragOffset = .zero
                        }
                )
            }
        }
    }

    // MARK: - Status Bar

    private var statusBarView: some View {
        let theme = ForceBarTheme(rawValue: forceBarTheme) ?? .system
        return StatusBarView(
            force: progressorHandler.currentForce,
            engaged: progressorHandler.engaged,
            calibrating: progressorHandler.calibrating,
            waitingForSamples: progressorHandler.waitingForSamples,
            calibrationTimeRemaining: progressorHandler.calibrationTimeRemaining,
            weightMedian: progressorHandler.weightMedian,
            targetWeight: effectiveTargetWeight,
            isOffTarget: progressorHandler.isOffTarget,
            offTargetDirection: progressorHandler.offTargetDirection,
            sessionMean: effectiveSessionMean,
            sessionStdDev: effectiveSessionStdDev,
            useLbs: useLbs,
            theme: theme,
            expanded: expandedForceBar,
            onUnitToggle: { useLbs.toggle() },
            onSettingsTap: { showSettings = true }
        )
    }

    /// Update the handler's target weight based on current settings
    private func updateTargetWeight() {
        progressorHandler.targetWeight = effectiveTargetWeight
    }

    // MARK: - Weight Picker Functions

    /// Step size from scraped weights (difference between first two options)
    private var weightStepSize: Float {
        guard availableWeights.count >= 2 else { return 0.5 }
        let stepInDisplayUnit = availableWeights[1] - availableWeights[0]
        return availableWeightsIsLbs ? stepInDisplayUnit / AppConstants.kgToLbs : stepInDisplayUnit
    }

    /// Whether we can decrement the suggested weight
    private var canDecrementSuggestedWeight: Bool {
        guard let kg = suggestedWeightKg else { return false }
        return kg - weightStepSize > 0
    }

    /// Whether we can increment the suggested weight
    private var canIncrementSuggestedWeight: Bool {
        suggestedWeightKg != nil
    }

    private func incrementSuggestedWeight() {
        guard let kg = suggestedWeightKg else { return }
        suggestedWeightKg = kg + weightStepSize
    }

    private func decrementSuggestedWeight() {
        guard let kg = suggestedWeightKg else { return }
        let newKg = kg - weightStepSize
        if newKg > 0 {
            suggestedWeightKg = newKg
        }
    }

    private func setSuggestedWeightInWebUI() {
        guard let weightKg = suggestedWeightKg else { return }
        webCoordinator.setTargetWeight(weightKg)
    }

    // MARK: - Combine Subscriptions

    private func setupSubscriptions() {
        // WebView button state
        webCoordinator.onButtonStateChanged = { enabled in
            isFailButtonEnabled = enabled
        }

        // WebView target weight scraping
        webCoordinator.onTargetWeightChanged = { weight in
            scrapedTargetWeight = weight
            // If we can scrape target weight, the picker screen is visible - scrape options too
            if weight != nil && autoSelectWeight && availableWeights.isEmpty {
                webCoordinator.scrapeWeightOptions()
            }
        }

        // WebView target duration scraping
        webCoordinator.onTargetDurationChanged = { duration in
            Log.app.info("Target duration scraped: \(String(describing: duration))")
            scrapedTargetDuration = duration
        }

        // WebView remaining time scraping
        webCoordinator.onRemainingTimeChanged = { remaining in
            scrapedRemainingTime = remaining
        }

        // WebView weight options scraping
        webCoordinator.onWeightOptionsChanged = { weights, isLbs in
            availableWeights = weights.sorted()
            availableWeightsIsLbs = isLbs
        }

        // WebView session info (gripper type, side)
        webCoordinator.onSessionInfoChanged = { gripper, side in
            scrapedGripper = gripper
            scrapedSide = side
        }

        // WebView advanced-settings-header visibility
        webCoordinator.onSettingsVisibleChanged = { visible in
            isSettingsVisible = visible
        }

        // BLE force samples -> Handler
        bluetoothManager.onForceSample = { force in
            progressorHandler.processSample(force)
        }

        // Handler grip failed -> Click fail button and end Live Activity
        let activityMgr = activityManager
        progressorHandler.gripFailed
            .receive(on: DispatchQueue.main)
            .sink { [webCoordinator, activityMgr] in
                webCoordinator.clickFailButton()
                activityMgr.endActivity()
                if UserDefaults.standard.object(forKey: "enableHaptics") as? Bool ?? true {
                    HapticManager.warning()
                }
            }
            .store(in: &cancellables)

        // Handler calibration complete
        progressorHandler.calibrationCompleted
            .receive(on: DispatchQueue.main)
            .sink {
                Log.app.info("Calibration complete")
                if UserDefaults.standard.object(forKey: "enableHaptics") as? Bool ?? true {
                    HapticManager.light()
                }
            }
            .store(in: &cancellables)

        // Handler off-target changed -> Feedback
        progressorHandler.offTargetChanged
            .receive(on: DispatchQueue.main)
            .sink { isOffTarget, direction in
                guard isOffTarget else { return }

                // Haptic feedback
                if UserDefaults.standard.object(forKey: "enableHaptics") as? Bool ?? true {
                    HapticManager.warning()
                }

                // Sound feedback
                if UserDefaults.standard.object(forKey: "enableTargetSound") as? Bool ?? true {
                    if let dir = direction {
                        if dir > 0 {
                            SoundManager.playHighTone()  // Too heavy
                        } else {
                            SoundManager.playLowTone()   // Too light
                        }
                    } else {
                        SoundManager.playWarningTone()
                    }
                }
            }
            .store(in: &cancellables)

        // Initialize target weight and tolerance
        updateTargetWeight()
        progressorHandler.weightTolerance = Float(weightTolerance)

        // Initialize grip detection settings
        progressorHandler.enableCalibration = enableCalibration
        progressorHandler.engageThreshold = Float(engageThreshold)
        progressorHandler.failThreshold = Float(failThreshold)

        // Periodic button state polling as backup (only in idle state)
        buttonStateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            if !progressorHandler.calibrating && !progressorHandler.waitingForSamples && !progressorHandler.engaged {
                webCoordinator.refreshButtonState()
            }
        }
    }
}

#Preview {
    ContentView()
}
