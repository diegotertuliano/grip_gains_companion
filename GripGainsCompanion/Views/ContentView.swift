import SwiftUI
import Combine

/// Main view that orchestrates all components
struct ContentView: View {
    @StateObject private var bluetoothManager = BluetoothManager()
    @StateObject private var progressorHandler = ProgressorHandler()

    @State private var isFailButtonEnabled = false
    @State private var isConnected = false
    @State private var skippedDevice = false
    @State private var showSettings = false
    @State private var cancellables = Set<AnyCancellable>()
    @State private var scrapedTargetWeight: Float?
    @AppStorage("useLbs") private var useLbs = false
    @AppStorage("enableHaptics") private var enableHaptics = true
    @AppStorage("enableTargetSound") private var enableTargetSound = true
    @AppStorage("showStatusBar") private var showStatusBar = true
    @AppStorage("fullScreen") private var fullScreen = true
    @AppStorage("forceBarTheme") private var forceBarTheme = ForceBarTheme.system.rawValue
    @AppStorage("settingsButtonX") private var settingsButtonX: Double = -1
    @AppStorage("settingsButtonY") private var settingsButtonY: Double = -1
    @AppStorage("useManualTarget") private var useManualTarget = false
    @AppStorage("manualTargetWeight") private var manualTargetWeight: Double = 20.0
    @AppStorage("weightTolerance") private var weightTolerance: Double = Double(AppConstants.defaultWeightTolerance)
    @State private var dragOffset: CGSize = .zero

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
        }
        .statusBarHidden(fullScreen)
    }

    // MARK: - Main View

    private var mainView: some View {
        VStack(spacing: 0) {
            // Status bar (shown when device is connected and setting enabled)
            if isConnected && showStatusBar {
                StatusBarView(
                    force: progressorHandler.currentForce,
                    engaged: progressorHandler.engaged,
                    calibrating: progressorHandler.calibrating,
                    waitingForSamples: progressorHandler.waitingForSamples,
                    calibrationTimeRemaining: progressorHandler.calibrationTimeRemaining,
                    weightMedian: progressorHandler.weightMedian,
                    targetWeight: effectiveTargetWeight,
                    isOffTarget: progressorHandler.isOffTarget,
                    offTargetDirection: progressorHandler.offTargetDirection,
                    useLbs: useLbs,
                    theme: ForceBarTheme(rawValue: forceBarTheme) ?? .system,
                    onUnitToggle: { useLbs.toggle() },
                    onSettingsTap: { showSettings = true }
                )
            }

            // Web view takes remaining space
            TimerWebView(coordinator: webCoordinator)
                .ignoresSafeArea(edges: .bottom)
        }
        .overlay {
            // Draggable settings button when status bar is hidden (disabled when settings open)
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
                                    // Clamp to screen bounds
                                    settingsButtonX = max(0, min(newX, geometry.size.width - buttonSize))
                                    settingsButtonY = max(0, min(newY, geometry.size.height - buttonSize))
                                    dragOffset = .zero
                                }
                        )
                }
            }
        }
        .sheet(isPresented: $showSettings) {
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
                scrapedTargetWeight: scrapedTargetWeight
            )
        }
        .onChange(of: useManualTarget) { _, _ in updateTargetWeight() }
        .onChange(of: manualTargetWeight) { _, _ in updateTargetWeight() }
        .onChange(of: scrapedTargetWeight) { _, _ in updateTargetWeight() }
        .onChange(of: weightTolerance) { _, newValue in
            progressorHandler.weightTolerance = Float(newValue)
        }
        .preferredColorScheme(preferredScheme)
    }

    // MARK: - Target Weight

    /// The effective target weight to use (manual or scraped)
    private var effectiveTargetWeight: Float? {
        if useManualTarget {
            return Float(manualTargetWeight)
        }
        return scrapedTargetWeight
    }

    /// Update the handler's target weight based on current settings
    private func updateTargetWeight() {
        progressorHandler.targetWeight = effectiveTargetWeight
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
        }

        // BLE force samples -> Handler
        bluetoothManager.onForceSample = { force in
            progressorHandler.processSample(force)
        }

        // Handler grip failed -> Click fail button
        progressorHandler.gripFailed
            .receive(on: DispatchQueue.main)
            .sink { [webCoordinator] in
                webCoordinator.clickFailButton()
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
    }
}

#Preview {
    ContentView()
}
