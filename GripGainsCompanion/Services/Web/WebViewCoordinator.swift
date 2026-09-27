import WebKit
import Combine

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

    // Only attempt offline cache fallback before the first completed page load.
    private var finishedPageLoads = 0

    private var initialPageURL: URL?
    private var triedCachedInitialPage = false
    private var recoveredMissingWorkout = false
    private var checkingMissingWorkout = false
    private var pageGeneration = 0
    private var pageCommitted = false
    private var pageBackgrounded = false
    private var startupRecoveryCancelled = false

    override init() {
        super.init()
    }

    func setWebView(_ webView: WKWebView) {
        self.webView = webView
        pageGeneration += 1
        pageCommitted = false
        finishedPageLoads = 0
    }

    /// Revalidate the HTML on launch so a deploy can't leave cached HTML pointing at removed
    /// workout chunks (the site sends no Cache-Control, so WebKit may otherwise reuse it).
    /// Offline, `didFailProvisionalNavigation` falls back to the cached copy.
    func loadInitialPage(_ url: URL) {
        initialPageURL = url
        triedCachedInitialPage = false
        webView?.load(URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData))
    }

    /// Cancel on background even if WebKit suspends before delivering visibilitychange.
    /// Returning to the foreground does not rearm recovery for this document.
    func setPageBackgrounded(_ backgrounded: Bool) {
        guard pageBackgrounded != backgrounded else { return }
        pageBackgrounded = backgrounded
        guard backgrounded else { return }
        startupRecoveryCancelled = true
        let generation = pageGeneration
        Task { @MainActor [weak self] in
            guard let self, self.pageGeneration == generation else { return }
            _ = try? await self.webView?.evaluateJavaScript("window.__ggCancelWorkoutRecovery?.();")
        }
    }

    /// Reload at most once, after confirming the report still refers to a missing workout
    /// in the current foreground document. A report can outlive the state that produced it.
    private func recoverMissingWorkout(_ message: WKScriptMessage) {
        guard pageCommitted, !recoveredMissingWorkout, !checkingMissingWorkout, !startupRecoveryCancelled,
              message.frameInfo.isMainFrame, let token = message.body as? String,
              let webView, message.webView === webView else { return }
        checkingMissingWorkout = true
        let generation = pageGeneration
        Task { @MainActor [weak self, weak webView] in
            guard let self else { return }
            defer { self.checkingMissingWorkout = false }
            guard let webView, self.webView === webView,
                  self.pageGeneration == generation, self.pageCommitted, !self.startupRecoveryCancelled,
                  !self.pageBackgrounded, UIApplication.shared.applicationState != .background else { return }
            let confirmed = try? await webView.callAsyncJavaScript(
                "return window.__ggConfirmWorkoutRecovery?.(token) === true;",
                arguments: ["token": token], in: nil, contentWorld: .page
            )
            guard confirmed as? Bool == true, self.webView === webView,
                  self.pageGeneration == generation, self.pageCommitted, !self.startupRecoveryCancelled,
                  !self.pageBackgrounded, UIApplication.shared.applicationState != .background else { return }
            self.recoveredMissingWorkout = true
            webView.reloadFromOrigin()
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        pageGeneration += 1
        pageCommitted = false
        startupRecoveryCancelled = pageBackgrounded
        updatePreparationState(false)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        pageCommitted = true
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let error = error as NSError
        if error.domain == NSURLErrorDomain, error.code != NSURLErrorCancelled,
           !triedCachedInitialPage, finishedPageLoads == 0, let initialPageURL {
            triedCachedInitialPage = true
            webView.load(URLRequest(url: initialPageURL, cachePolicy: .returnCacheDataDontLoad))
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        updatePreparationState(false)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishedPageLoads += 1
        Task { @MainActor in
            try? await webView.evaluateJavaScript(JavaScriptBridge.observerScript)

            // Reapply web-audio mute only when muted, so the default (sounds on) state
            // leaves the freshly loaded page completely untouched.
            if websiteAudioMuted {
                try? await webView.evaluateJavaScript(JavaScriptBridge.websiteAudioMuteScript)
                try? await webView.evaluateJavaScript(JavaScriptBridge.setWebsiteAudioMuted(true))
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
        Task { @MainActor in
            webView?.reload()
        }
    }

    /// Clear all website data (cache, cookies, storage) and reload
    func clearWebsiteData() {
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
                try? await webView?.evaluateJavaScript(JavaScriptBridge.websiteAudioMuteScript)
            }
            try? await webView?.evaluateJavaScript(JavaScriptBridge.setWebsiteAudioMuted(muted))
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
