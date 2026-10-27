import WebKit
import Combine

/// Shared for the app process, including replacement coordinators and WebViews.
/// Tests inject a separate lifetime to model a genuinely new app launch.
final class StartupRecoveryLifetime {
    static let shared = StartupRecoveryLifetime()
    private var claimed = false

    func claim() -> Bool {
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

/// Coordinator for WKWebView that handles JavaScript message callbacks
/// This bridges JavaScript calls back to Swift
class WebViewCoordinator: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    private weak var webView: WKWebView?

    /// Callback when button state changes
    var onButtonStateChanged: ((Bool) -> Void)?

    /// Callback when target weight changes (scraped from website)
    var onTargetWeightChanged: ((Double?) -> Void)?

    /// Callback when target duration changes (scraped from website, in seconds)
    var onTargetDurationChanged: ((Int?) -> Void)?

    /// Callback when remaining time changes (scraped from timer display, in seconds, negative = overtime)
    var onRemainingTimeChanged: ((Int?) -> Void)?
    var onPreparationStateChanged: ((Bool) -> Void)?
    private(set) var isPreparationPhase = false

    func updatePreparationState(_ preparing: Bool) {
        if preparing { cancelStartupRecovery() }
        isPreparationPhase = preparing
        onPreparationStateChanged?(preparing)
    }

    /// Callback when available weight options are scraped (weights in display unit, isLbs indicates unit)
    var onWeightOptionsChanged: (([Double], Bool) -> Void)?

    /// Callback when session info changes (gripper type, side)
    var onSessionInfoChanged: ((String?, String?) -> Void)?

    /// Callback when settings screen visibility changes (false = gripping in progress)
    var onSettingsVisibleChanged: ((Bool) -> Void)?

    /// Callback when "Save to Database" button appears (end of set)
    var onSaveButtonAppeared: (() -> Void)?

    /// Whether gripgains.ca's own (Web Audio) sounds are currently muted
    var websiteAudioMuted = false

    /// Whether to turn off gripgains.ca's "Subtract 2s" switch before each set
    private(set) var disableSubtract2s = false

    private var initialPageURL: URL?
    private var initialNavigation: WKNavigation?
    private var checkingMissingWorkout = false
    private var pageGeneration = 0
    private var pageCommitted = false
    private var pageBackgrounded = false
    private var startupRecoveryCancelled = true
    private let startupRecoveryLifetime: StartupRecoveryLifetime
    private var startupNavigation: WKNavigation?
    private var startupRecoveryScript: WKUserScript?
    private var startupDelay: TimeInterval = 3
    private var startupDeadline: ContinuousClock.Instant?
    private var pageURLObservation: NSKeyValueObservation?

    init(startupRecoveryLifetime: StartupRecoveryLifetime = .shared) {
        self.startupRecoveryLifetime = startupRecoveryLifetime
        super.init()
    }

    func setWebView(_ webView: WKWebView) {
        cancelStartupRecovery()
        self.webView = webView
        pageGeneration += 1
        pageCommitted = false
        initialNavigation = nil
    }

    /// Revalidate the HTML on launch so a deploy can't leave cached HTML pointing at removed
    /// workout chunks (the site sends no Cache-Control, so WebKit may otherwise reuse it).
    /// Offline, `didFailProvisionalNavigation` falls back to the cached copy.
    func loadInitialPage(_ url: URL, missingWorkoutDelay: TimeInterval = 3) {
        guard let webView else { return }
        cancelStartupRecovery()
        initialPageURL = url
        if startupRecoveryLifetime.claim(), !pageBackgrounded, url.path == "/timer" {
            startupRecoveryCancelled = false
            startupDelay = missingWorkoutDelay
            let script = WKUserScript(source: JavaScriptBridge.missingWorkoutCheckScript,
                                      injectionTime: .atDocumentStart, forMainFrameOnly: true)
            startupRecoveryScript = script
            webView.configuration.userContentController.addUserScript(script)
            // Vue login and other route changes do not necessarily start a WKNavigation.
            pageURLObservation = webView.observe(\.url, options: [.new]) { [weak self] _, change in
                guard let self, let url = change.newValue ?? nil, url != self.initialPageURL else { return }
                self.cancelStartupRecovery()
            }
        }
        let navigation = webView.load(URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData))
        initialNavigation = navigation
        if !startupRecoveryCancelled { startupNavigation = navigation }
    }

    /// Cancel on background even if WebKit suspends before delivering visibilitychange.
    /// Returning to the foreground does not rearm recovery for this document.
    func setPageBackgrounded(_ backgrounded: Bool) {
        guard pageBackgrounded != backgrounded else { return }
        pageBackgrounded = backgrounded
        guard backgrounded else { return }
        cancelStartupRecovery()
    }

    private func removeStartupRecoveryScript() {
        guard let script = startupRecoveryScript, let controller = webView?.configuration.userContentController else { return }
        // Snapshot WebKit's bridged collection before mutating it; preserve all other bridges.
        let remaining = controller.userScripts.filter { $0.source != script.source }
        controller.removeAllUserScripts()
        remaining.forEach { controller.addUserScript($0) }
        startupRecoveryScript = nil
    }

    private func cancelStartupRecovery() {
        guard !startupRecoveryCancelled else { return }
        startupRecoveryCancelled = true
        startupNavigation = nil
        startupDeadline = nil
        pageURLObservation = nil
        removeStartupRecoveryScript()
        let generation = pageGeneration
        Task { @MainActor [weak self] in
            guard let self, self.pageGeneration == generation else { return }
            _ = try? await self.webView?.evaluateJavaScript("window.__ggCancelWorkoutRecovery?.();")
        }
    }

    private var canRecoverStartup: Bool {
        !startupRecoveryCancelled && !pageBackgrounded && pageCommitted &&
            startupDeadline.map { ContinuousClock.now < $0 } == true &&
            webView?.url == initialPageURL && UIApplication.shared.applicationState != .background
    }

    /// Reload at most once, after confirming the report still refers to a missing workout
    /// in the current foreground document. A report can outlive the state that produced it.
    private func recoverMissingWorkout(_ message: WKScriptMessage) {
        guard canRecoverStartup, !checkingMissingWorkout,
              message.frameInfo.isMainFrame, let token = message.body as? String,
              let webView, message.webView === webView else { return }
        checkingMissingWorkout = true
        let generation = pageGeneration
        Task { @MainActor [weak self, weak webView] in
            guard let self else { return }
            defer { self.checkingMissingWorkout = false }
            guard let webView, self.webView === webView,
                  self.pageGeneration == generation, self.canRecoverStartup else { return }
            let confirmed = try? await webView.callAsyncJavaScript(
                "return window.__ggConfirmWorkoutRecovery?.(token) === true;",
                arguments: ["token": token], in: nil, contentWorld: .page
            )
            guard confirmed as? Bool == true, self.webView === webView,
                  self.pageGeneration == generation, self.canRecoverStartup else { return }
            self.cancelStartupRecovery()
            webView.reloadFromOrigin()
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        pageGeneration += 1
        pageCommitted = false
        if navigation !== initialNavigation { initialNavigation = nil }
        if navigation !== startupNavigation { cancelStartupRecovery() }
        updatePreparationState(false)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        pageCommitted = true
        initialNavigation = nil
        guard !startupRecoveryCancelled, navigation === startupNavigation else { return }
        // Never install the startup check in a replacement document, even at the same URL.
        removeStartupRecoveryScript()
        let checkAt = ContinuousClock.now.advanced(by: .seconds(startupDelay))
        let deadline = checkAt.advanced(by: .seconds(1))
        startupDeadline = deadline
        let generation = pageGeneration
        Task { @MainActor [weak self, weak webView] in
            guard let self, let webView, self.pageGeneration == generation, self.canRecoverStartup else { return }
            let remaining = ContinuousClock.now.duration(to: checkAt).components
            let milliseconds = max(0, remaining.seconds * 1000 + remaining.attoseconds / 1_000_000_000_000_000)
            _ = try? await webView.callAsyncJavaScript(
                "window.__ggStartWorkoutRecovery?.(delay);",
                arguments: ["delay": milliseconds], in: nil, contentWorld: .page
            )
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard let self, self.startupDeadline == deadline else { return }
            self.cancelStartupRecovery()
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let error = error as NSError
        if error.domain == NSURLErrorDomain, error.code != NSURLErrorCancelled,
           let initialNavigation, navigation === initialNavigation, let initialPageURL {
            // Only a failed initial request can use the offline copy, never a later navigation.
            self.initialNavigation = nil
            let isStartup = !startupRecoveryCancelled && navigation === startupNavigation
            let cachedNavigation = webView.load(URLRequest(url: initialPageURL, cachePolicy: .returnCacheDataDontLoad))
            if isStartup { startupNavigation = cachedNavigation }
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        cancelStartupRecovery()
        updatePreparationState(false)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            _ = try? await webView.evaluateJavaScript(JavaScriptBridge.observerScript)

            // Reapply web-audio mute only when muted, so the default (sounds on) state
            // leaves the freshly loaded page completely untouched.
            if websiteAudioMuted {
                _ = try? await webView.evaluateJavaScript(JavaScriptBridge.websiteAudioMuteScript)
                _ = try? await webView.evaluateJavaScript(JavaScriptBridge.setWebsiteAudioMuted(true))
            }

            // A fresh page starts with the Subtract 2s observer inert; re-enable it if set.
            if disableSubtract2s {
                _ = try? await webView.evaluateJavaScript(JavaScriptBridge.setDisableSubtract2s(true))
            }
        }
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        switch message.name {
        case "workoutMissing":
            recoverMissingWorkout(message)

        case "buttonState":
            if let enabled = message.body as? Bool {
                if enabled { cancelStartupRecovery() }
                DispatchQueue.main.async { [weak self] in
                    self?.onButtonStateChanged?(enabled)
                }
            }

        case "targetWeight":
            DispatchQueue.main.async { [weak self] in
                if let weightString = message.body as? String {
                    self?.onTargetWeightChanged?(self?.parseWeight(weightString))
                } else {
                    self?.onTargetWeightChanged?(nil)
                }
            }

        case "targetDuration":
            DispatchQueue.main.async { [weak self] in
                if let duration = message.body as? Int {
                    self?.onTargetDurationChanged?(duration)
                } else {
                    self?.onTargetDurationChanged?(nil)
                }
            }

        case "preparationState":
            DispatchQueue.main.async { [weak self] in
                self?.updatePreparationState(message.body as? Bool ?? false)
            }

        case "remainingTime":
            DispatchQueue.main.async { [weak self] in
                if let remaining = message.body as? Int {
                    self?.onRemainingTimeChanged?(remaining)
                } else {
                    self?.onRemainingTimeChanged?(nil)
                }
            }

        case "weightOptions":
            DispatchQueue.main.async { [weak self] in
                if let dict = message.body as? [String: Any],
                   let weights = dict["weights"] as? [Double],
                   let isLbs = dict["isLbs"] as? Bool {
                    let floats = weights.map { Double($0) }
                    self?.onWeightOptionsChanged?(floats, isLbs)
                } else {
                    self?.onWeightOptionsChanged?([], false)
                }
            }

        case "sessionInfo":
            DispatchQueue.main.async { [weak self] in
                if let dict = message.body as? [String: Any] {
                    let gripper = dict["gripper"] as? String
                    let side = dict["side"] as? String
                    self?.onSessionInfoChanged?(gripper, side)
                }
            }

        case "settingsVisible":
            DispatchQueue.main.async { [weak self] in
                if let isVisible = message.body as? Bool {
                    self?.onSettingsVisibleChanged?(isVisible)
                }
            }

        case "saveButtonAppeared":
            DispatchQueue.main.async { [weak self] in
                self?.onSaveButtonAppeared?()
            }

        default:
            break
        }
    }

    /// Parse weight string like "20.0 kg" or "44 lbs" to Double (always returns kg)
    func parseWeight(_ string: String) -> Double? {
        let lowercased = string.lowercased()
        let isLbs = lowercased.contains("lbs") || lowercased.contains("lb")

        // Remove unit and whitespace, then parse
        let cleaned = lowercased
            .replacingOccurrences(of: "lbs", with: "")
            .replacingOccurrences(of: "lb", with: "")
            .replacingOccurrences(of: "kg", with: "")
            .trimmingCharacters(in: .whitespaces)

        guard let value = Double(cleaned) else { return nil }

        // Convert lbs to kg if needed (internal storage is always kg)
        return isLbs ? value / AppConstants.kgToLbs : value
    }

    // MARK: - Public Methods

    /// Click the fail button via JavaScript injection
    func clickFailButton() {
        Task { @MainActor in
            await clickFailButtonAsync()
        }
    }

    /// Click the fail button via JavaScript injection (async version)
    @MainActor
    func clickFailButtonAsync() async {
        do {
            _ = try await webView?.evaluateJavaScript(JavaScriptBridge.clickFailButton)
        } catch {
            Log.app.error("Error clicking fail button: \(error.localizedDescription)")
        }
    }

    /// Click the "End Session" button via JavaScript injection
    func clickEndSessionButton() {
        Task { @MainActor in
            await clickEndSessionButtonAsync()
        }
    }

    /// Click the "End Session" button (async version)
    @MainActor
    func clickEndSessionButtonAsync() async {
        do {
            _ = try await webView?.evaluateJavaScript(JavaScriptBridge.clickEndSessionButton)
        } catch {
            Log.app.error("Error clicking end session button: \(error.localizedDescription)")
        }
    }

    /// Click the "Start" button via JavaScript injection
    func clickStartButton() {
        cancelStartupRecovery()
        Task { @MainActor in
            try? await webView?.evaluateJavaScript(JavaScriptBridge.clickStartButton)
        }
    }

    /// Request current button state from the page (for manual refresh if needed)
    func refreshButtonState() {
        Task { @MainActor in
            await refreshButtonStateAsync()
        }
    }

    /// Request current button state from the page (async version)
    @MainActor
    func refreshButtonStateAsync() async {
        do {
            _ = try await webView?.evaluateJavaScript(JavaScriptBridge.checkFailButtonState)
        } catch {
            Log.app.error("Error refreshing button state: \(error.localizedDescription)")
        }
    }

    /// Reload the current page
    func reloadPage() {
        cancelStartupRecovery()
        Task { @MainActor in
            webView?.reload()
        }
    }

    /// Clear all website data (cache, cookies, storage) and reload
    func clearWebsiteData() {
        cancelStartupRecovery()
        Task { @MainActor in
            let dataStore = WKWebsiteDataStore.default()
            let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
            let date = Date(timeIntervalSince1970: 0)
            await dataStore.removeData(ofTypes: dataTypes, modifiedSince: date)
            webView?.reload()
        }
    }

    /// Manually request target weight scrape from the page
    func scrapeTargetWeight() {
        Task { @MainActor in
            await scrapeTargetWeightAsync()
        }
    }

    /// Manually request target weight scrape from the page (async version)
    @MainActor
    func scrapeTargetWeightAsync() async {
        do {
            _ = try await webView?.evaluateJavaScript(JavaScriptBridge.scrapeTargetWeight)
        } catch {
            Log.app.error("Error scraping target weight: \(error.localizedDescription)")
        }
    }

    /// Scrape available weight options from the web UI picker
    func scrapeWeightOptions() {
        Task { @MainActor in
            await scrapeWeightOptionsAsync()
        }
    }

    /// Scrape available weight options (async version)
    @MainActor
    func scrapeWeightOptionsAsync() async {
        do {
            _ = try await webView?.evaluateJavaScript(JavaScriptBridge.scrapeWeightOptions)
        } catch {
            Log.app.error("Error scraping weight options: \(error.localizedDescription)")
        }
    }

    /// Set target weight in web UI picker (value in kg, auto-converts if web is in lbs)
    func setTargetWeight(_ weightKg: Double) {
        Task { @MainActor in
            await setTargetWeightAsync(weightKg)
        }
    }

    /// Set target weight in web UI picker (async version)
    @MainActor
    func setTargetWeightAsync(_ weightKg: Double) async {
        do {
            _ = try await webView?.evaluateJavaScript(JavaScriptBridge.setTargetWeightScript(weightKg: weightKg))
        } catch {
            Log.app.error("Error setting target weight: \(error.localizedDescription)")
        }
    }

    /// Mute or unmute gripgains.ca's own sounds (Web Audio). The patch is injected lazily
    /// the first time sounds are muted, so the default (unmuted) state never touches the page.
    func setWebsiteAudioMuted(_ muted: Bool) {
        websiteAudioMuted = muted
        Task { @MainActor in
            if muted {
                _ = try? await webView?.evaluateJavaScript(JavaScriptBridge.websiteAudioMuteScript)
            }
            _ = try? await webView?.evaluateJavaScript(JavaScriptBridge.setWebsiteAudioMuted(muted))
        }
    }

    /// Enable or disable automatically turning off the timer page's "Subtract 2s" switch.
    func setDisableSubtract2s(_ disabled: Bool) {
        disableSubtract2s = disabled
        Task { @MainActor in
            _ = try? await webView?.evaluateJavaScript(JavaScriptBridge.setDisableSubtract2s(disabled))
        }
    }

    /// Record timer state when entering background
    func recordBackgroundStart() {
        Task { @MainActor in
            try? await webView?.evaluateJavaScript("window._recordBackgroundStart()")
        }
    }

    /// Add elapsed background time to compensate for JS being throttled in background
    func addBackgroundTime(milliseconds: Double) {
        Task { @MainActor in
            try? await webView?.evaluateJavaScript("window._addBackgroundTime(\(milliseconds))")
        }
    }
}
