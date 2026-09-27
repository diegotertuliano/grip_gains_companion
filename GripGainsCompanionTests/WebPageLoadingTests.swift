import XCTest
import SwiftUI
import WebKit
import Network
@testable import GripGainsCompanion

@MainActor
final class WebPageLoadingTests: XCTestCase {
    private var windows: [UIWindow] = []
    private var stores: [WKWebsiteDataStore] = []

    override func tearDown() {
        for window in windows {
            window.isHidden = true
            window.rootViewController = nil
        }
        windows.removeAll()
        for store in stores {
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
        }
        stores.removeAll()
        super.tearDown()
    }

    func testFreshCachedPageIsAvailableWithoutTheServer() async throws {
        let server = try await startServer(maxAge: 3600, cacheWorkout: true)
        defer { server.stop() }
        let store = persistentStore()
        let url = server.url
        let page = try await presentPage(url, store: store, recorder: PageLoadRecorder())
        try await waitForModuleState("ready", on: page)
        try await assertTitle("Workout v1", on: page)
        server.stop()

        let cached = try await presentPage(url, store: store, recorder: PageLoadRecorder())
        try await waitForModuleState("ready", on: cached)
        try await assertTitle("Workout v1", on: cached)
    }

    func testDeploymentWithFreshCachedHTMLLoadsNewWorkoutOnLaunch() async throws {
        let server = try await startServer(maxAge: 3600)
        defer { server.stop() }
        let store = persistentStore()
        let page = try await presentPage(server.url, store: store, recorder: PageLoadRecorder())
        try await waitForModuleState("ready", on: page)

        server.deployNextVersion()
        let recorder = PageLoadRecorder()
        let reopened = try await presentPage(server.url, store: store, recorder: recorder)
        try await waitForModuleState("ready", on: reopened)
        try await assertTitle("Workout v2", on: reopened)
        XCTAssertEqual(server.documentRequests, 2, "The app revalidates HTML on launch even while it is fresh")
        XCTAssertEqual(recorder.navigationCount, 1, "No recovery reload was needed")
    }

    func testMissingWorkoutViewReloadsFromServer() async throws {
        let server = try await startServer()
        defer { server.stop() }
        server.failWorkoutResponses(1)
        let recorder = PageLoadRecorder()
        // The fallback timeout is far beyond the test: the chunk failure itself triggers recovery.
        let page = try await presentPage(server.url, recorder: recorder, missingWorkoutDelay: 60)
        let failedAt = ContinuousClock.now

        // The page reports the missing workout view and the app reloads once, without user action.
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while recorder.navigationCount < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(recorder.navigationCount, 2)
        XCTAssertLessThan(ContinuousClock.now - failedAt, .seconds(2), "Recovery should not wait for the timeout")
        try await waitForModuleState("ready", on: page)
        try await assertTitle("Workout v1", on: page)
    }

    func testMissingWorkoutViewReloadsOnlyOnce() async throws {
        let server = try await startServer()
        defer { server.stop() }
        server.failWorkoutResponses(100)
        let recorder = PageLoadRecorder()
        let page = try await presentPage(server.url, recorder: recorder, missingWorkoutDelay: 0.3)
        try await Task.sleep(for: .seconds(3))
        XCTAssertEqual(recorder.navigationCount, 2, "A persistent failure must not cause a reload loop")
        try await assertTitle("Menu only", on: page)
    }

    func testSlowWorkoutAfterStartupWindowReloadsOnceAndFinishes() async throws {
        let server = try await startServer(renderDelay: 1.2)
        defer { server.stop() }
        let recorder = PageLoadRecorder()
        let page = try await presentPage(server.url, recorder: recorder, missingWorkoutDelay: 0.3)
        try await waitForModuleState("ready", on: page)
        try await Task.sleep(for: .seconds(0.5))
        XCTAssertEqual(recorder.navigationCount, 2)
        XCTAssertEqual(server.documentRequests, 2)
        try await assertTitle("Workout v1", on: page)
    }

    func testWorkoutRenderedWithinStartupWindowDisarmsTimeoutAndLaterErrors() async throws {
        let server = try await startServer(renderDelay: 0.2)
        defer { server.stop() }
        let recorder = PageLoadRecorder()
        let page = try await presentPage(server.url, recorder: recorder, missingWorkoutDelay: 1)
        try await waitForModuleState("ready", on: page)
        // Once mounted, losing the root must not rearm either startup trigger.
        _ = try await page.evaluateJavaScript("document.querySelector('.timer-view').remove();")
        try await sendChunkError(to: page)
        try await Task.sleep(for: .seconds(1.2))
        try await sendChunkError(to: page)
        XCTAssertEqual(recorder.navigationCount, 1)
        XCTAssertEqual(recorder.recoveryReports, 0)
    }

    func testFallbackEndsWindowEvenWhenCurrentRouteNeedsNoWorkout() async throws {
        let server = try await startServer(autoStart: false)
        defer { server.stop() }
        let recorder = PageLoadRecorder()
        let page = try await presentPage(server.url, recorder: recorder, missingWorkoutDelay: 0.5)
        _ = try await page.evaluateJavaScript("history.pushState({}, '', '/history');")
        try await Task.sleep(for: .seconds(0.8))
        _ = try await page.evaluateJavaScript("history.pushState({}, '', '/timer');")
        try await sendChunkError(to: page)
        XCTAssertEqual(recorder.navigationCount, 1)
        XCTAssertEqual(recorder.recoveryReports, 0)
    }

    func testBackgroundBeforeTimeoutDoesNotRecoverOnReturn() async throws {
        let server = try await startServer(autoStart: false)
        defer { server.stop() }
        let recorder = PageLoadRecorder()
        let state = PageHostState()
        let page = try await presentPage(server.url, recorder: recorder, state: state, missingWorkoutDelay: 1)
        state.phase = .background
        try await Task.sleep(for: .seconds(0.2))
        state.phase = .active
        try await Task.sleep(for: .seconds(1.2))
        try await sendChunkError(to: page)
        XCTAssertEqual(recorder.navigationCount, 1)
        XCTAssertEqual(recorder.recoveryReports, 0)
    }

    func testHiddenDocumentDoesNotRecoverWhenVisibleAgain() async throws {
        let server = try await startServer(autoStart: false)
        defer { server.stop() }
        let recorder = PageLoadRecorder()
        let page = try await presentPage(server.url, recorder: recorder, missingWorkoutDelay: 1)
        // Simulate WebKit visibility events separately from native scene changes.
        _ = try await page.evaluateJavaScript("""
            Object.defineProperty(document, 'hidden', { configurable: true, value: true });
            document.dispatchEvent(new Event('visibilitychange'));
            delete document.hidden;
            document.dispatchEvent(new Event('visibilitychange'));
            void(0);
            """)
        try await Task.sleep(for: .seconds(1.2))
        try await sendChunkError(to: page)
        XCTAssertEqual(recorder.navigationCount, 1)
        XCTAssertEqual(recorder.recoveryReports, 0)
    }

    func testInitiallyHiddenDocumentNeverArmsRecovery() async throws {
        let server = try await startServer(autoStart: false)
        defer { server.stop() }
        let recorder = PageLoadRecorder()
        recorder.beforePageScripts = "Object.defineProperty(document, 'hidden', { configurable: true, value: true });"
        let page = try await presentPage(server.url, recorder: recorder, missingWorkoutDelay: 0.3)
        _ = try await page.evaluateJavaScript("delete document.hidden; document.dispatchEvent(new Event('visibilitychange'));")
        try await Task.sleep(for: .seconds(0.6))
        try await sendChunkError(to: page)
        XCTAssertEqual(recorder.navigationCount, 1)
        XCTAssertEqual(recorder.recoveryReports, 0)
    }

    func testQueuedRecoveryIsCancelledIfWorkoutAppears() async throws {
        let server = try await startServer(autoStart: false)
        defer { server.stop() }
        let recorder = PageLoadRecorder()
        recorder.holdRecoveryReports = true
        let page = try await presentPage(server.url, recorder: recorder)
        try await sendChunkError(to: page)
        try await waitForRecoveryReport(recorder)
        _ = try await page.evaluateJavaScript("void window.openWorkout();")
        try await waitForModuleState("ready", on: page)
        recorder.deliverRecoveryReports()
        try await Task.sleep(for: .seconds(0.5))
        XCTAssertEqual(recorder.navigationCount, 1)
        try await assertTitle("Workout v1", on: page)
    }

    func testQueuedRecoveryIsCancelledIfRouteChanges() async throws {
        let server = try await startServer(autoStart: false)
        defer { server.stop() }
        let recorder = PageLoadRecorder()
        recorder.holdRecoveryReports = true
        let page = try await presentPage(server.url, recorder: recorder)
        try await sendChunkError(to: page)
        try await waitForRecoveryReport(recorder)
        _ = try await page.evaluateJavaScript("history.pushState({}, '', '/history');")
        recorder.deliverRecoveryReports()
        try await Task.sleep(for: .seconds(0.5))
        XCTAssertEqual(recorder.navigationCount, 1)
        XCTAssertEqual(page.url?.path, "/history")
    }

    func testQueuedRecoveryDoesNotAffectReplacementDocumentAtSameURL() async throws {
        let server = try await startServer(autoStart: false)
        defer { server.stop() }
        let recorder = PageLoadRecorder()
        recorder.holdRecoveryReports = true
        let page = try await presentPage(server.url, recorder: recorder)
        try await sendChunkError(to: page)
        try await waitForRecoveryReport(recorder)
        let loaded = expectation(description: "Replacement document loaded")
        recorder.finished = { _ in loaded.fulfill() }
        page.reload()
        await fulfillment(of: [loaded], timeout: 5)
        recorder.finished = nil
        recorder.deliverRecoveryReports()
        try await Task.sleep(for: .seconds(0.5))
        XCTAssertEqual(recorder.navigationCount, 2, "Only the explicit replacement navigation should occur")
    }

    func testQueuedRecoveryIsCancelledAcrossBackgroundAndReturn() async throws {
        let server = try await startServer(autoStart: false)
        defer { server.stop() }
        let recorder = PageLoadRecorder()
        recorder.holdRecoveryReports = true
        let state = PageHostState()
        let page = try await presentPage(server.url, recorder: recorder, state: state)
        try await sendChunkError(to: page)
        try await waitForRecoveryReport(recorder)
        state.phase = .background
        try await Task.sleep(for: .seconds(0.2))
        state.phase = .active
        try await Task.sleep(for: .seconds(0.2))
        recorder.deliverRecoveryReports()
        try await Task.sleep(for: .seconds(0.5))
        XCTAssertEqual(recorder.navigationCount, 1)
    }

    func testQueuedRecoveryDoesNotCancelPendingNavigation() async throws {
        let server = try await startServer(autoStart: false)
        defer { server.stop() }
        let recorder = PageLoadRecorder()
        recorder.holdRecoveryReports = true
        let page = try await presentPage(server.url, recorder: recorder)
        try await sendChunkError(to: page)
        try await waitForRecoveryReport(recorder)
        // Deliver the old report while the new navigation is waiting for its HTML.
        server.delayNextDocumentResponse(0.5)
        let loaded = expectation(description: "Pending navigation finishes")
        recorder.started = { _ in recorder.deliverRecoveryReports() }
        recorder.finished = { _ in loaded.fulfill() }
        page.reloadFromOrigin()
        await fulfillment(of: [loaded], timeout: 5)
        recorder.started = nil
        recorder.finished = nil
        try await Task.sleep(for: .seconds(0.3))
        XCTAssertEqual(recorder.navigationCount, 2, "Recovery must not replace an in-flight navigation")
        XCTAssertEqual(server.documentRequests, 2)
    }

    private func sendChunkError(to page: WKWebView) async throws {
        _ = try await page.evaluateJavaScript("window.dispatchEvent(new Event('vite:preloadError'));")
        // Allow the script message and any resulting navigation to reach the coordinator.
        try await Task.sleep(for: .milliseconds(100))
    }

    private func waitForRecoveryReport(_ recorder: PageLoadRecorder) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while recorder.recoveryReports == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(recorder.recoveryReports, 1)
    }

    func testDeploymentPreservesAlreadyLoadedGripAndRestState() async throws {
        let server = try await startServer()
        defer { server.stop() }
        let recorder = PageLoadRecorder()
        let state = PageHostState()
        let page = try await presentPage(server.url, recorder: recorder, state: state)
        try await waitForModuleState("ready", on: page)
        let initialRequestCount = server.requestCount

        for phase in ["grip", "rest"] {
            _ = try await page.evaluateJavaScript("window.workoutState = { phase: '\(phase)', reps: 2 }; void(0)")
            state.phase = .background
            state.visible = false
            try await Task.sleep(for: .milliseconds(50))
            server.deployNextVersion()
            state.phase = .active
            state.visible = true
            try await Task.sleep(for: .milliseconds(50))

            let savedPhase = try await page.evaluateJavaScript("window.workoutState.phase") as? String
            let savedReps = try await page.evaluateJavaScript("window.workoutState.reps") as? Int
            XCTAssertEqual(savedPhase, phase)
            XCTAssertEqual(savedReps, 2)
            try await assertTitle("Workout v1", on: page)
        }
        XCTAssertEqual(recorder.navigationCount, 1)
        XCTAssertEqual(server.requestCount, initialRequestCount, "Loaded modules do not need to be fetched on resume")
    }

    private func assertTitle(_ expected: String, on page: WKWebView, file: StaticString = #filePath, line: UInt = #line) async throws {
        // WKWebView.title's KVO update can arrive after didFinish; read the live document.
        let title = try await page.evaluateJavaScript("document.title") as? String
        XCTAssertEqual(title, expected, file: file, line: line)
    }

    private func waitForModuleState(_ expected: String, on page: WKWebView,
                                   file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var actual: String?
        repeat {
            actual = try await page.evaluateJavaScript("window.moduleState || 'loading'") as? String
            if actual == expected { return }
            try await Task.sleep(for: .milliseconds(50))
        } while ContinuousClock.now < deadline
        let error = try await page.evaluateJavaScript("window.moduleError || ''") as? String
        XCTFail("Expected module state \(expected), got \(actual ?? "nil"). \(error ?? "")", file: file, line: line)
    }

    private func startServer(maxAge: Int = 0, cacheWorkout: Bool = false, autoStart: Bool = true,
                             renderDelay: TimeInterval = 0) async throws -> WorkoutPageServer {
        let server = try WorkoutPageServer(maxAge: maxAge, cacheWorkout: cacheWorkout,
                                           autoStart: autoStart, renderDelay: renderDelay)
        let ready = expectation(description: "HTTP fixture ready")
        server.start { ready.fulfill() }
        await fulfillment(of: [ready], timeout: 5)
        return server
    }

    private func persistentStore() -> WKWebsiteDataStore {
        let store = WKWebsiteDataStore(forIdentifier: UUID())
        stores.append(store)
        return store
    }

    private func presentPage(_ url: URL, store: WKWebsiteDataStore? = nil,
                             recorder: PageLoadRecorder, state: PageHostState = PageHostState(),
                             missingWorkoutDelay: TimeInterval = 30) async throws -> WKWebView {
        let finished = expectation(description: "Page loaded")
        recorder.finished = { _ in finished.fulfill() }
        let host = UIHostingController(rootView: PageTestHost(
            coordinator: recorder, url: url, store: store ?? .nonPersistent(), state: state,
            missingWorkoutDelay: missingWorkoutDelay
        ))
        let window = try makeWindow()
        window.rootViewController = host
        windows.append(window)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        await fulfillment(of: [finished], timeout: 10)
        recorder.finished = nil
        return try XCTUnwrap(recorder.page)
    }

    private func makeWindow() throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        return window
    }
}

private final class PageHostState: ObservableObject {
    @Published var phase = ScenePhase.active
    @Published var visible = true
}

private struct PageTestHost: View {
    let coordinator: WebViewCoordinator
    let url: URL
    let store: WKWebsiteDataStore
    @ObservedObject var state: PageHostState
    let missingWorkoutDelay: TimeInterval

    var body: some View {
        TimerWebView(coordinator: coordinator, url: url, websiteDataStore: store,
                     missingWorkoutDelay: missingWorkoutDelay)
            .opacity(state.visible ? 1 : 0)
            .environment(\.scenePhase, state.phase)
    }
}

private final class PageLoadRecorder: WebViewCoordinator {
    weak var page: WKWebView?
    var navigationCount = 0
    var started: ((WKWebView) -> Void)?
    var finished: ((WKWebView) -> Void)?
    var recoveryReports = 0
    var holdRecoveryReports = false
    var beforePageScripts: String?
    private var queuedRecoveryReports: [WKScriptMessage] = []

    override func setWebView(_ webView: WKWebView) {
        super.setWebView(webView)
        guard let beforePageScripts else { return }
        let controller = webView.configuration.userContentController
        // Materialize a snapshot before mutating WebKit's bridged script collection.
        let scripts = controller.userScripts.map {
            WKUserScript(source: $0.source, injectionTime: $0.injectionTime, forMainFrameOnly: $0.isForMainFrameOnly)
        }
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: beforePageScripts, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        scripts.forEach { controller.addUserScript($0) }
    }

    func deliverRecoveryReports() {
        guard let page else { return }
        let reports = queuedRecoveryReports
        queuedRecoveryReports.removeAll()
        for report in reports {
            super.userContentController(page.configuration.userContentController, didReceive: report)
        }
    }

    override func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        super.webView(webView, didStartProvisionalNavigation: navigation)
        navigationCount += 1
        started?(webView)
    }

    override func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        super.webView(webView, didFinish: navigation)
        page = webView
        finished?(webView)
    }

    override func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "workoutMissing" {
            recoveryReports += 1
            if holdRecoveryReports {
                queuedRecoveryReports.append(message)
                return
            }
        }
        super.userContentController(userContentController, didReceive: message)
    }
}

/// Real HTTP responses exercise WebKit's cache, which custom URL schemes do not model.
private final class WorkoutPageServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "WorkoutPageServer")
    private let maxAge: Int
    private let cacheWorkout: Bool
    private let autoStart: Bool
    private let renderDelay: TimeInterval
    private var version = 1
    private var requests = 0
    private var totalRequests = 0
    private var failingWorkoutResponses = 0
    private var nextDocumentDelay: TimeInterval = 0

    init(maxAge: Int, cacheWorkout: Bool, autoStart: Bool, renderDelay: TimeInterval) throws {
        self.maxAge = maxAge
        self.cacheWorkout = cacheWorkout
        self.autoStart = autoStart
        self.renderDelay = renderDelay
        listener = try NWListener(using: .tcp, on: .any)
    }

    var url: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/timer")! }
    var documentRequests: Int { queue.sync { requests } }
    var requestCount: Int { queue.sync { totalRequests } }

    func deployNextVersion() { queue.sync { version += 1 } }
    /// Answer the next workout-module requests with HTML, like a missing chunk.
    func failWorkoutResponses(_ count: Int) {
        queue.sync { failingWorkoutResponses = count }
    }
    func delayNextDocumentResponse(_ delay: TimeInterval) {
        queue.sync { nextDocumentDelay = delay }
    }
    func stop() { listener.cancel() }

    func start(ready: @escaping @Sendable () -> Void) {
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.receiveRequest(connection, accumulated: Data())
        }
        listener.start(queue: queue)
    }

    private func receiveRequest(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, let data, error == nil else { connection.cancel(); return }
            let requestData = accumulated + data
            guard let request = String(data: requestData, encoding: .utf8), request.contains("\r\n\r\n") else {
                if complete { connection.cancel() }
                else { self.receiveRequest(connection, accumulated: requestData) }
                return
            }
            let path = request.components(separatedBy: " ").dropFirst().first ?? ""
            let body: String
            let type: String
            let cache: String
            var responseDelay: TimeInterval = 0
            self.totalRequests += 1
            if path == "/timer" {
                responseDelay = self.nextDocumentDelay
                self.nextDocumentDelay = 0
                self.requests += 1
                body = self.document
                type = "text/html"
                cache = "max-age=\(self.maxAge)"
            } else if path == "/js/index-build-\(self.version).js" {
                body = self.entryModule
                type = "application/javascript"
                cache = "max-age=31536000, immutable"
            } else if path == "/js/TimerView-build-\(self.version).js", self.failingWorkoutResponses == 0 {
                body = self.workoutModule
                type = "application/javascript"
                // Model an uncached chunk unless testing offline fallback.
                cache = self.cacheWorkout ? "max-age=\(self.maxAge)" : "no-store"
            } else {
                if path.hasPrefix("/js/TimerView-"), self.failingWorkoutResponses > 0 {
                    self.failingWorkoutResponses -= 1
                }
                // Match the observed missing-JS-path response from the live host.
                body = self.document
                type = "text/html"
                cache = "no-store"
            }
            let date = DateFormatter()
            date.locale = Locale(identifier: "en_US_POSIX")
            date.timeZone = TimeZone(secondsFromGMT: 0)
            date.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
            let response = "HTTP/1.1 200 OK\r\nDate: \(date.string(from: Date()))\r\nETag: \"v\(self.version)\"\r\nContent-Type: \(type)\r\nCache-Control: \(cache)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            self.queue.asyncAfter(deadline: .now() + responseDelay) {
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    private var document: String {
        """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Menu only</title><script type="module" src="/js/index-build-\(version).js"></script></head>
        <body><nav>Menu</nav><main id="workout"></main></body></html>
        """
    }

    private var entryModule: String {
        """
        window.moduleState = 'shell';
        window.openWorkout = () => import('./TimerView-build-\(version).js').then(async module => {
            \(renderDelay > 0 ? "await new Promise(resolve => setTimeout(resolve, \(Int(renderDelay * 1000))));" : "")
            module.mount(); window.moduleState = 'ready';
        }).catch(error => {
            window.moduleState = 'failed'; window.moduleError = String(error);
            // Like Vite's __vitePreload, which wraps the site's lazy route imports.
            const event = new Event('vite:preloadError', { cancelable: true });
            event.payload = error;
            window.dispatchEvent(event);
            if (!event.defaultPrevented) throw error;
        });
        \(autoStart ? "void window.openWorkout();" : "")
        """
    }

    private var workoutModule: String {
        """
        export function mount() {
            document.title = 'Workout v\(version)';
            window.workoutState = { phase: 'ready', reps: 0 };
            document.getElementById('workout').innerHTML = '<div class="timer-view">Ready</div>';
        }
        """
    }
}
