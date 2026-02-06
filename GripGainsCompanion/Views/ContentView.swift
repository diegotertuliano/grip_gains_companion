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
                    webCoordinator.setTargetWeight(manualTargetWeight)
                }
            }
            .onChange(of: manualTargetWeight) { _, _ in
                if autoSelectWeight, autoSelectFromManual {
                    webCoordinator.setTargetWeight(manualTargetWeight)
                }
            }
    }
}

// MARK: - Stats Change Modifier

struct StatsChangeModifier: ViewModifier {
    let sessionMean: Double?
    let sessionStdDev: Double?
    let engaged: Bool
    @Binding var displayedMean: Double?
    @Binding var displayedStdDev: Double?
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

// MARK: - Percentage Threshold Sync Modifier

struct PercentageThresholdSyncModifier: ViewModifier {
    let enablePercentageThresholds: Bool
    let engagePercentage: Double
    let disengagePercentage: Double
    let tolerancePercentage: Double
    let progressorHandler: ProgressorHandler

    func body(content: Content) -> some View {
        content
            .onChange(of: enablePercentageThresholds) { _, newValue in
                progressorHandler.enablePercentageThresholds = newValue
            }
            .onChange(of: engagePercentage) { _, newValue in
                progressorHandler.engagePercentage = newValue
            }
            .onChange(of: disengagePercentage) { _, newValue in
                progressorHandler.disengagePercentage = newValue
            }
            .onChange(of: tolerancePercentage) { _, newValue in
                progressorHandler.tolerancePercentage = newValue
            }
    }
}

// MARK: - Engage Bounds Sync Modifier

struct EngageBoundsSyncModifier: ViewModifier {
    let engageFloor: Double
    let engageCeiling: Double
    let progressorHandler: ProgressorHandler

    func body(content: Content) -> some View {
        content
            .onChange(of: engageFloor) { _, newValue in
                progressorHandler.engageFloor = newValue
            }
            .onChange(of: engageCeiling) { _, newValue in
                progressorHandler.engageCeiling = newValue
            }
    }
}

// MARK: - Disengage Bounds Sync Modifier

struct DisengageBoundsSyncModifier: ViewModifier {
    let disengageFloor: Double
    let disengageCeiling: Double
    let progressorHandler: ProgressorHandler

    func body(content: Content) -> some View {
        content
            .onChange(of: disengageFloor) { _, newValue in
                progressorHandler.disengageFloor = newValue
            }
            .onChange(of: disengageCeiling) { _, newValue in
                progressorHandler.disengageCeiling = newValue
            }
    }
}

// MARK: - Tolerance Bounds Sync Modifier

struct ToleranceBoundsSyncModifier: ViewModifier {
    let toleranceFloor: Double
    let toleranceCeiling: Double
    let progressorHandler: ProgressorHandler

    func body(content: Content) -> some View {
        content
            .onChange(of: toleranceFloor) { _, newValue in
                progressorHandler.toleranceFloor = newValue
            }
            .onChange(of: toleranceCeiling) { _, newValue in
                progressorHandler.toleranceCeiling = newValue
            }
    }
}

/// Main view that orchestrates all components
struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var persistenceService: SessionPersistenceService
    @StateObject private var bluetoothManager = BluetoothManager()
    @StateObject private var progressorHandler = ProgressorHandler()
    @StateObject private var activityManager = ActivityManager()

    @State private var isFailButtonEnabled = false
    @State private var isConnected = false
    @State private var skippedDevice = false
    @State private var showSettings = false
    @State private var cancellables = Set<AnyCancellable>()
    @State private var scrapedTargetWeight: Double?
    @State private var scrapedTargetDuration: Int?
    @State private var scrapedRemainingTime: Int?
    @AppStorage("useLbs") private var useLbs = false
    @AppStorage("enableHaptics") private var enableHaptics = AppConstants.defaultEnableHaptics
    @AppStorage("enableTargetSound") private var enableTargetSound = AppConstants.defaultEnableTargetSound
    @AppStorage("showStatusBar") private var showStatusBar = AppConstants.defaultShowStatusBar
    @AppStorage("expandedForceBar") private var expandedForceBar = AppConstants.defaultExpandedForceBar
    @AppStorage("showForceGraph") private var showForceGraph = AppConstants.defaultShowForceGraph
    @AppStorage("forceGraphWindow") private var forceGraphWindow = AppConstants.defaultForceGraphWindow
    @AppStorage("fullScreen") private var fullScreen = AppConstants.defaultFullScreen
    @AppStorage("forceBarTheme") private var forceBarTheme = ForceBarTheme.system.rawValue
    @AppStorage("settingsButtonX") private var settingsButtonX: Double = -1
    @AppStorage("settingsButtonY") private var settingsButtonY: Double = -1
    @AppStorage("enableTargetWeight") private var enableTargetWeight = AppConstants.defaultEnableTargetWeight
    @AppStorage("useManualTarget") private var useManualTarget = AppConstants.defaultUseManualTarget
    @AppStorage("manualTargetWeight") private var manualTargetWeight: Double = AppConstants.defaultManualTargetWeight
    @AppStorage("showGripStats") private var showGripStats = AppConstants.defaultShowGripStats
    @AppStorage("weightTolerance") private var weightTolerance: Double = Double(AppConstants.defaultWeightTolerance)
    @AppStorage("enableCalibration") private var enableCalibration = AppConstants.defaultEnableCalibration
    @AppStorage("engageThreshold") private var engageThreshold: Double = Double(AppConstants.defaultEngageThreshold)
    @AppStorage("failThreshold") private var failThreshold: Double = Double(AppConstants.defaultFailThreshold)
    @AppStorage("enablePercentageThresholds") private var enablePercentageThresholds = AppConstants.defaultEnablePercentageThresholds
    @AppStorage("engagePercentage") private var engagePercentage: Double = Double(AppConstants.defaultEngagePercentage)
    @AppStorage("disengagePercentage") private var disengagePercentage: Double = Double(AppConstants.defaultDisengagePercentage)
    @AppStorage("tolerancePercentage") private var tolerancePercentage: Double = Double(AppConstants.defaultTolerancePercentage)
    @AppStorage("engageFloor") private var engageFloor: Double = Double(AppConstants.defaultEngageFloor)
    @AppStorage("engageCeiling") private var engageCeiling: Double = Double(AppConstants.defaultEngageCeiling)
    @AppStorage("disengageFloor") private var disengageFloor: Double = Double(AppConstants.defaultDisengageFloor)
    @AppStorage("disengageCeiling") private var disengageCeiling: Double = Double(AppConstants.defaultDisengageCeiling)
    @AppStorage("toleranceFloor") private var toleranceFloor: Double = Double(AppConstants.defaultToleranceFloor)
    @AppStorage("toleranceCeiling") private var toleranceCeiling: Double = Double(AppConstants.defaultToleranceCeiling)
    @AppStorage("backgroundTimeSync") private var backgroundTimeSync = AppConstants.defaultBackgroundTimeSync
    @AppStorage("enableLiveActivity") private var enableLiveActivity = AppConstants.defaultEnableLiveActivity
    @AppStorage("autoSelectWeight") private var autoSelectWeight = AppConstants.defaultAutoSelectWeight
    @AppStorage("autoSelectFromManual") private var autoSelectFromManual = AppConstants.defaultAutoSelectFromManual
    @AppStorage("enableEndSessionOnEarlyFail") private var enableEndSessionOnEarlyFail = AppConstants.defaultEnableEndSessionOnEarlyFail
    @AppStorage("earlyFailThresholdPercent") private var earlyFailThresholdPercent: Double = AppConstants.defaultEarlyFailThresholdPercent
    @State private var dragOffset: CGSize = .zero
    @State private var displayedMean: Double?
    @State private var displayedStdDev: Double?
    @State private var statsHideTimer: Timer?
    @State private var buttonStateTimer: Timer?
    @State private var backgroundedAt: Date?
    @State private var wasGrippingAtBackground: Bool = false

    // Weight picker state
    @State private var availableWeights: [Double] = []
    @State private var availableWeightsIsLbs: Bool = false
    @State private var suggestedWeightKg: Double? = nil  // Suggested weight in kg
    @State private var weightControlDragOffset: CGSize = .zero
    @AppStorage("weightControlX") private var weightControlX: Double = -1
    @AppStorage("weightControlY") private var weightControlY: Double = -1

    // Session info (for detecting exercise changes)
    @State private var scrapedGripper: String? = nil
    @State private var scrapedSide: String? = nil
    @State private var isSettingsVisible: Bool = true  // Whether advanced-settings-header is visible in web UI

    // Rep/Set Statistics
    @StateObject private var repTracker = RepTracker()
    @State private var showSetReview: Bool = false

    @StateObject private var webCoordinator = WebViewCoordinator()

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
                // Start disconnect timer if connected and not gripping
                if bluetoothManager.connectionState == .connected && !progressorHandler.engaged {
                    bluetoothManager.startBackgroundDisconnectTimer()
                }
            case .active:
                // Cancel background disconnect timer when returning to foreground
                bluetoothManager.cancelBackgroundDisconnectTimer()
                // If disconnected, start scanning to auto-reconnect (if lastConnectedDeviceId is set)
                if bluetoothManager.connectionState == .disconnected {
                    bluetoothManager.startScanning()
                }
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
            tolerance: weightTolerance
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
            scrapedTargetWeight: scrapedTargetWeight,
            deviceShortName: bluetoothManager.selectedDeviceType.shortName
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
            .sheet(isPresented: $showSettings) {
                settingsSheet
            }
            .sheet(isPresented: $showSetReview) { setReviewSheet }
    }

    // MARK: - Set Review Sheet

    private var setReviewSheet: some View {
        Group {
            if let stats = repTracker.setStatistics {
                SetReviewSheet(
                    stats: stats,
                    useLbs: useLbs,
                    onDismiss: {
                        showSetReview = false
                        repTracker.resetForNewSet()
                    }
                )
            }
        }
    }

    private var mainContentWithTargetHandlers: some View {
        mainContent
            .onChange(of: useManualTarget) { _, enabled in
                updateTargetWeight()
                // Reset auto-select to measured when manual target is disabled
                if !enabled && autoSelectFromManual {
                    autoSelectFromManual = false
                }
            }
            .onChange(of: manualTargetWeight) { _, newValue in
                updateTargetWeight()
                // Update floating control when manual target changes
                if autoSelectWeight && autoSelectFromManual {
                    suggestedWeightKg = newValue
                }
            }
            .onChange(of: autoSelectFromManual) { _, useManual in
                if useManual {
                    // Enable manual target when manual mode is selected
                    if !useManualTarget {
                        useManualTarget = true
                    }
                    // Initialize floating control from manual target
                    if autoSelectWeight {
                        suggestedWeightKg = manualTargetWeight
                    }
                } else {
                    // Disable manual target when measured mode is selected
                    if useManualTarget {
                        useManualTarget = false
                    }
                }
            }
            .onChange(of: scrapedTargetWeight) { _, newValue in
                updateTargetWeight()
                // Initialize suggested weight to GG target (only when feature enabled)
                if autoSelectWeight, let target = newValue {
                    suggestedWeightKg = target
                }
            }
    }

    private var mainViewWithHandlers: some View {
        mainContentWithTargetHandlers
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
                if autoSelectWeight {
                    webCoordinator.scrapeWeightOptions()
                }
            }
            .onChange(of: scrapedSide) { _, _ in
                // Side changed, re-scrape weight options for correct increments
                if autoSelectWeight {
                    webCoordinator.scrapeWeightOptions()
                }
            }
            .onChange(of: weightTolerance) { _, newValue in
                progressorHandler.weightTolerance = newValue
            }
            .onChange(of: enableCalibration) { _, newValue in
                progressorHandler.enableCalibration = newValue
            }
            .onChange(of: engageThreshold) { _, newValue in
                progressorHandler.engageThreshold = newValue
            }
            .onChange(of: failThreshold) { _, newValue in
                progressorHandler.failThreshold = newValue
            }
            .modifier(PercentageThresholdSyncModifier(
                enablePercentageThresholds: enablePercentageThresholds,
                engagePercentage: engagePercentage,
                disengagePercentage: disengagePercentage,
                tolerancePercentage: tolerancePercentage,
                progressorHandler: progressorHandler
            ))
            .modifier(EngageBoundsSyncModifier(
                engageFloor: engageFloor,
                engageCeiling: engageCeiling,
                progressorHandler: progressorHandler
            ))
            .modifier(DisengageBoundsSyncModifier(
                disengageFloor: disengageFloor,
                disengageCeiling: disengageCeiling,
                progressorHandler: progressorHandler
            ))
            .modifier(ToleranceBoundsSyncModifier(
                toleranceFloor: toleranceFloor,
                toleranceCeiling: toleranceCeiling,
                progressorHandler: progressorHandler
            ))
    }

    // MARK: - Target Weight

    /// The effective target weight to use (manual or scraped), or nil if disabled
    private var effectiveTargetWeight: Double? {
        guard enableTargetWeight else { return nil }
        // When auto-select is enabled, always use scraped value (what's in web UI)
        if autoSelectWeight {
            return scrapedTargetWeight
        }
        if useManualTarget {
            return manualTargetWeight
        }
        return scrapedTargetWeight
    }

    // MARK: - Statistics Display

    /// The mean to display (respects showGripStats setting)
    private var effectiveSessionMean: Double? {
        showGripStats ? displayedMean : nil
    }

    /// The std dev to display (respects showGripStats setting)
    private var effectiveSessionStdDev: Double? {
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
        // Show when feature enabled, connected, we have a suggested weight, settings visible, and gripper selected
        if autoSelectWeight && (isConnected || skippedDevice) && suggestedWeightKg != nil && isSettingsVisible && scrapedGripper != nil {
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
                    onSet: { setSuggestedWeightInWebUI() },
                    onReset: { suggestedWeightKg = scrapedTargetWeight },
                    onStart: { webCoordinator.clickStartButton() }
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
            deviceShortName: bluetoothManager.selectedDeviceType.shortName,
            onUnitToggle: { useLbs.toggle() },
            onSettingsTap: { showSettings = true }
        )
    }

    /// Update the handler's target weight based on current settings
    private func updateTargetWeight() {
        progressorHandler.targetWeight = effectiveTargetWeight
    }

    /// Determine if we should end the session instead of failing
    private func shouldEndSessionOnEarlyFail() -> Bool {
        guard enableEndSessionOnEarlyFail,
              let targetDuration = scrapedTargetDuration,
              let remainingTime = scrapedRemainingTime,
              targetDuration > 0 else { return false }

        let elapsedTime = targetDuration - remainingTime
        let thresholdSeconds = Double(targetDuration) * earlyFailThresholdPercent
        return Double(elapsedTime) < thresholdSeconds
    }

    // MARK: - Weight Picker Functions

    /// Step size from scraped weights (difference between first two options)
    private var weightStepSize: Double {
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
        webCoordinator.onSessionInfoChanged = { [repTracker, persistenceService] gripper, side in
            scrapedGripper = gripper
            scrapedSide = side
            repTracker.updateSessionContext(gripper: gripper, side: side)
            Task { @MainActor in
                persistenceService.updateSessionContext(gripper: gripper, side: side)
            }
        }

        // WebView advanced-settings-header visibility
        webCoordinator.onSettingsVisibleChanged = { visible in
            isSettingsVisible = visible
        }

        // WebView save button appeared (end of set)
        webCoordinator.onSaveButtonAppeared = { [repTracker] in
            repTracker.completeSet()
        }

        // BLE force samples -> Handler
        bluetoothManager.onForceSample = { force, timestamp in
            progressorHandler.processSample(force, timestamp: timestamp)
        }

        // Handler grip failed -> Click fail or end session button
        let activityMgr = activityManager
        progressorHandler.gripFailed
            .receive(on: DispatchQueue.main)
            .sink { [webCoordinator, activityMgr] in
                if self.shouldEndSessionOnEarlyFail() {
                    webCoordinator.clickEndSessionButton()
                    Log.app.info("Early fail detected - ending session")
                } else {
                    webCoordinator.clickFailButton()
                }
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

        // Handler grip disengaged -> Record rep
        progressorHandler.gripDisengaged
            .receive(on: DispatchQueue.main)
            .sink { [repTracker, progressorHandler] duration, samples in
                repTracker.recordRep(
                    duration: duration,
                    samples: samples,
                    targetWeight: progressorHandler.targetWeight
                )
            }
            .store(in: &cancellables)

        // Rep completed -> Save to database
        repTracker.repCompleted
            .receive(on: DispatchQueue.main)
            .sink { [persistenceService] rep in
                Task { @MainActor in
                    persistenceService.saveRep(from: rep)
                }
            }
            .store(in: &cancellables)

        // Set summary -> Show review sheet (if enabled)
        repTracker.showSetSummary
            .receive(on: DispatchQueue.main)
            .sink { _ in
                if UserDefaults.standard.object(forKey: "showSetReview") as? Bool ?? false {
                    showSetReview = true
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
        progressorHandler.weightTolerance = weightTolerance

        // Initialize grip detection settings
        progressorHandler.enableCalibration = enableCalibration
        progressorHandler.engageThreshold = engageThreshold
        progressorHandler.failThreshold = failThreshold
        progressorHandler.enablePercentageThresholds = enablePercentageThresholds
        progressorHandler.engagePercentage = engagePercentage
        progressorHandler.disengagePercentage = disengagePercentage
        progressorHandler.tolerancePercentage = tolerancePercentage
        progressorHandler.engageFloor = engageFloor
        progressorHandler.engageCeiling = engageCeiling
        progressorHandler.disengageFloor = disengageFloor
        progressorHandler.disengageCeiling = disengageCeiling
        progressorHandler.toleranceFloor = toleranceFloor
        progressorHandler.toleranceCeiling = toleranceCeiling

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
