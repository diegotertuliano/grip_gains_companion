import XCTest
import WebKit
@testable import GripGainsCompanion

@MainActor
final class Subtract2sScriptTests: XCTestCase {

    private var webView: WKWebView!

    /// Mirrors gripgains.ca's pre-set switch: clicking flips aria-pressed.
    private static let toggleHTML = """
        <html><body><div class="timer-controls">
        <button id="t" type="button" aria-label="Toggle 2 second timer delay" aria-pressed="%@"
            onclick="window.clicks = (window.clicks || 0) + 1;
                     this.setAttribute('aria-pressed', this.getAttribute('aria-pressed') === 'true' ? 'false' : 'true')">
            <span>Subtract 2s</span>
        </button>
        </div></body></html>
        """

    override func setUp() {
        super.setUp()
        let contentController = WKUserContentController()
        contentController.addUserScript(WKUserScript(
            source: JavaScriptBridge.subtract2sObserverScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        webView = WKWebView(frame: .zero, configuration: config)
    }

    override func tearDown() {
        webView = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func loadHTML(_ html: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let delegate = LoadDelegate(continuation: continuation)
            webView.navigationDelegate = delegate
            objc_setAssociatedObject(webView!, "loadDelegate", delegate, .OBJC_ASSOCIATION_RETAIN)
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    private func pressed() async throws -> String? {
        try await webView.evaluateJavaScript("document.getElementById('t').getAttribute('aria-pressed')") as? String
    }

    private func clicks() async throws -> Int {
        (try await webView.evaluateJavaScript("window.clicks || 0") as? NSNumber)?.intValue ?? 0
    }

    private func setDisabled(_ disabled: Bool) async throws {
        _ = try await webView.evaluateJavaScript(JavaScriptBridge.setDisableSubtract2s(disabled))
    }

    private func waitUntilReleased(timeout: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await pressed() == "false" { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Subtract 2s switch was not turned off")
    }

    private func settle() async throws {
        try await Task.sleep(nanoseconds: 300_000_000)
    }

    // MARK: - Tests

    func testLeavesSwitchAloneWhenSettingIsOff() async throws {
        try await loadHTML(String(format: Self.toggleHTML, "true"))
        try await settle()
        let state = try await pressed()
        XCTAssertEqual(state, "true")
        let clickCount = try await clicks()
        XCTAssertEqual(clickCount, 0)
    }

    func testTurnsSwitchOffOnceWhenEnabled() async throws {
        try await loadHTML(String(format: Self.toggleHTML, "true"))
        try await setDisabled(true)
        try await waitUntilReleased()
        try await settle()
        let clickCount = try await clicks()
        XCTAssertEqual(clickCount, 1)
    }

    func testNeverClicksSwitchThatIsAlreadyOff() async throws {
        try await loadHTML(String(format: Self.toggleHTML, "false"))
        try await setDisabled(true)
        try await settle()
        let state = try await pressed()
        XCTAssertEqual(state, "false")
        let clickCount = try await clicks()
        XCTAssertEqual(clickCount, 0)
    }

    func testTurnsOffSwitchThatAppearsLater() async throws {
        try await loadHTML("<html><body><div class=\"timer-controls\"></div></body></html>")
        try await setDisabled(true)
        _ = try await webView.evaluateJavaScript("""
            const b = document.createElement('button');
            b.id = 't';
            b.setAttribute('aria-label', 'Toggle 2 second timer delay');
            b.setAttribute('aria-pressed', 'true');
            b.onclick = function() { b.setAttribute('aria-pressed', 'false'); };
            document.querySelector('.timer-controls').appendChild(b);
            true;
            """)
        try await waitUntilReleased()
    }

    func testFindsSwitchByLabelTextWhenAriaLabelChanges() async throws {
        let html = String(format: Self.toggleHTML, "true")
            .replacingOccurrences(of: "aria-label=\"Toggle 2 second timer delay\"", with: "")
        try await loadHTML(html)
        try await setDisabled(true)
        try await waitUntilReleased()
    }

    func testTurnsSwitchOffAgainAfterManualReenable() async throws {
        try await loadHTML(String(format: Self.toggleHTML, "true"))
        try await setDisabled(true)
        try await waitUntilReleased()
        // Wait out the click cooldown, then switch it back on as a user would.
        try await Task.sleep(nanoseconds: 1_100_000_000)
        _ = try await webView.evaluateJavaScript("document.getElementById('t').setAttribute('aria-pressed', 'true')")
        try await waitUntilReleased()
        let clickCount = try await clicks()
        XCTAssertEqual(clickCount, 2)
    }

    func testStopsClickingWhenSwitchNeverResponds() async throws {
        let html = String(format: Self.toggleHTML, "true")
            .replacingOccurrences(of: "this.setAttribute('aria-pressed', this.getAttribute('aria-pressed') === 'true' ? 'false' : 'true')", with: "")
        try await loadHTML(html)
        try await setDisabled(true)
        try await Task.sleep(nanoseconds: 4_500_000_000)
        let clickCount = try await clicks()
        XCTAssertEqual(clickCount, 3)
        let state = try await pressed()
        XCTAssertEqual(state, "true")
    }
}

private final class LoadDelegate: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
