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

    /// Callback when available weight options are scraped (weights in display unit, isLbs indicates unit)
    var onWeightOptionsChanged: (([Double], Bool) -> Void)?

    /// Callback when session info changes (gripper type, side)
    var onSessionInfoChanged: ((String?, String?) -> Void)?

    /// Callback when settings screen visibility changes (false = gripping in progress)
    var onSettingsVisibleChanged: ((Bool) -> Void)?

    /// Callback when "Save to Database" button appears (end of set)
    var onSaveButtonAppeared: (() -> Void)?

    override init() {
        super.init()
    }

    func setWebView(_ webView: WKWebView) {
        self.webView = webView
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            try? await webView.evaluateJavaScript(JavaScriptBridge.observerScript)
        }
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        switch message.name {
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
