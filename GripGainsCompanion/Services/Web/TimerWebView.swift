import SwiftUI
import WebKit

/// SwiftUI wrapper for WKWebView that displays the gripgains.ca timer page
struct TimerWebView: UIViewRepresentable {
    let coordinator: WebViewCoordinator
    var url = AppConstants.gripGainsURL
    var websiteDataStore = WKWebsiteDataStore.default()
    /// How long after load the timer page may lack its workout view before one recovery reload.
    var missingWorkoutDelay: TimeInterval = 3
    @Environment(\.scenePhase) private var scenePhase

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()

        // Enable default caching
        config.websiteDataStore = websiteDataStore

        // Suppress media content loading (not needed for this app)
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.allowsInlineMediaPlayback = false

        // Disable JavaScript popup windows
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        let contentController = config.userContentController

        // Add message handlers for JS -> Swift communication
        contentController.add(coordinator, name: "buttonState")
        contentController.add(coordinator, name: "targetWeight")
        contentController.add(coordinator, name: "targetDuration")
        contentController.add(coordinator, name: "remainingTime")
        contentController.add(coordinator, name: "preparationState")
        contentController.add(coordinator, name: "weightOptions")
        contentController.add(coordinator, name: "sessionInfo")
        contentController.add(coordinator, name: "settingsVisible")
        contentController.add(coordinator, name: "saveButtonAppeared")
        contentController.add(coordinator, name: "workoutMissing")

        // Inject background time offset script at document start (must run before page scripts)
        let backgroundTimeScript = WKUserScript(
            source: JavaScriptBridge.backgroundTimeOffsetScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        contentController.addUserScript(backgroundTimeScript)

        contentController.addUserScript(WKUserScript(
            source: JavaScriptBridge.missingWorkoutCheckScript(delayMilliseconds: Int(missingWorkoutDelay * 1000)),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))

        // Inject script to close weight picker if it's open on page load
        let closePickerScript = WKUserScript(
            source: JavaScriptBridge.closePickerOnLoadScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        contentController.addUserScript(closePickerScript)

        // Inject observer script on document end
        let observerScript = WKUserScript(
            source: JavaScriptBridge.observerScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        contentController.addUserScript(observerScript)

        // Inject target weight observer script
        let targetWeightScript = WKUserScript(
            source: JavaScriptBridge.targetWeightObserverScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        contentController.addUserScript(targetWeightScript)

        // Inject remaining time observer script
        let remainingTimeScript = WKUserScript(
            source: JavaScriptBridge.remainingTimeObserverScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        contentController.addUserScript(remainingTimeScript)

        // Inject settings visibility observer script (watches for advanced-settings-header)
        let settingsVisibilityScript = WKUserScript(
            source: JavaScriptBridge.settingsVisibilityObserverScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        contentController.addUserScript(settingsVisibilityScript)

        // Inject save button observer script (detects end of set)
        let saveButtonScript = WKUserScript(
            source: JavaScriptBridge.saveButtonObserverScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        contentController.addUserScript(saveButtonScript)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = coordinator
        coordinator.setWebView(webView)
        coordinator.setPageBackgrounded(scenePhase == .background)

        // Load only on creation; SwiftUI updates and app resumes must preserve the live workout.
        coordinator.loadInitialPage(url)

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // Do not load here: scene changes and BLE updates must not restart the workout.
        coordinator.setPageBackgrounded(scenePhase == .background)
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: ()) {
        // Clean up message handlers to avoid memory leaks
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "buttonState")
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "targetWeight")
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "targetDuration")
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "remainingTime")
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "preparationState")
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "weightOptions")
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "sessionInfo")
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "settingsVisible")
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "saveButtonAppeared")
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "workoutMissing")
    }
}
