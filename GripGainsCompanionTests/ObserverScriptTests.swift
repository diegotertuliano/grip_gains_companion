import XCTest
import WebKit
@testable import GripGainsCompanion

@MainActor
final class ObserverScriptTests: XCTestCase, WKScriptMessageHandler {

    private var webView: WKWebView!
    private var messageExpectation: XCTestExpectation?
    private var lastButtonState: Bool?

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        let contentController = WKUserContentController()
        contentController.add(self, name: "buttonState")

        let userScript = WKUserScript(
            source: JavaScriptBridge.observerScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        contentController.addUserScript(userScript)

        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        webView = WKWebView(frame: .zero, configuration: config)
    }

    override func tearDown() {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "buttonState")
        webView = nil
        messageExpectation = nil
        lastButtonState = nil
        super.tearDown()
    }

    // MARK: - WKScriptMessageHandler

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        Task { @MainActor in
            if let enabled = message.body as? Bool {
                self.lastButtonState = enabled
                self.messageExpectation?.fulfill()
            }
        }
    }

    // MARK: - Helpers

    private func loadHTML(_ html: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let delegate = NavigationDelegate(continuation: continuation)
            webView.navigationDelegate = delegate
            objc_setAssociatedObject(webView!, "navDelegate", delegate, .OBJC_ASSOCIATION_RETAIN)
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    // MARK: - Tests

    func testInitialEnabledButton() async throws {
        messageExpectation = expectation(description: "Initial enabled button state")
        let html = "<html><body><button class=\"btn-fail-prominent\">Fail</button></body></html>"
        try await loadHTML(html)
        await fulfillment(of: [messageExpectation!], timeout: 5)
        XCTAssertEqual(lastButtonState, true)
    }

    func testInitialDisabledButton() async throws {
        messageExpectation = expectation(description: "Initial disabled button state")
        let html = "<html><body><button class=\"btn-fail-prominent\" disabled>Fail</button></body></html>"
        try await loadHTML(html)
        await fulfillment(of: [messageExpectation!], timeout: 5)
        XCTAssertEqual(lastButtonState, false)
    }

    func testButtonDisabledToggle() async throws {
        // Load with enabled button
        messageExpectation = expectation(description: "Initial state")
        let html = "<html><body><button class=\"btn-fail-prominent\">Fail</button></body></html>"
        try await loadHTML(html)
        await fulfillment(of: [messageExpectation!], timeout: 5)
        XCTAssertEqual(lastButtonState, true)

        // Disable the button (regular timer behavior)
        messageExpectation = expectation(description: "Button disabled")
        try await webView.evaluateJavaScript(
            "document.querySelector('button.btn-fail-prominent').disabled = true;"
        )
        await fulfillment(of: [messageExpectation!], timeout: 5)
        XCTAssertEqual(lastButtonState, false)
    }

    func testButtonReEnabled() async throws {
        // Load with enabled button
        messageExpectation = expectation(description: "Initial state")
        let html = "<html><body><button class=\"btn-fail-prominent\">Fail</button></body></html>"
        try await loadHTML(html)
        await fulfillment(of: [messageExpectation!], timeout: 5)
        XCTAssertEqual(lastButtonState, true)

        // Disable
        messageExpectation = expectation(description: "Button disabled")
        try await webView.evaluateJavaScript(
            "document.querySelector('button.btn-fail-prominent').disabled = true;"
        )
        await fulfillment(of: [messageExpectation!], timeout: 5)
        XCTAssertEqual(lastButtonState, false)

        // Re-enable (regular timer behavior)
        messageExpectation = expectation(description: "Button re-enabled")
        try await webView.evaluateJavaScript(
            "document.querySelector('button.btn-fail-prominent').disabled = false;"
        )
        await fulfillment(of: [messageExpectation!], timeout: 5)
        XCTAssertEqual(lastButtonState, true)
    }

    func testButtonRemovedFromDOM() async throws {
        // Load with enabled button
        messageExpectation = expectation(description: "Initial state")
        let html = "<html><body><button class=\"btn-fail-prominent\">Fail</button></body></html>"
        try await loadHTML(html)
        await fulfillment(of: [messageExpectation!], timeout: 5)
        XCTAssertEqual(lastButtonState, true)

        // Remove button (basic timer behavior)
        messageExpectation = expectation(description: "Button removed")
        try await webView.evaluateJavaScript(
            "document.querySelector('button.btn-fail-prominent').remove();"
        )
        await fulfillment(of: [messageExpectation!], timeout: 5)
        XCTAssertEqual(lastButtonState, false)
    }

    func testButtonReAddedAfterRemoval() async throws {
        // Load with enabled button
        messageExpectation = expectation(description: "Initial state")
        let html = "<html><body><button class=\"btn-fail-prominent\">Fail</button></body></html>"
        try await loadHTML(html)
        await fulfillment(of: [messageExpectation!], timeout: 5)
        XCTAssertEqual(lastButtonState, true)

        // Remove button (basic timer between reps)
        messageExpectation = expectation(description: "Button removed")
        try await webView.evaluateJavaScript(
            "document.querySelector('button.btn-fail-prominent').remove();"
        )
        await fulfillment(of: [messageExpectation!], timeout: 5)
        XCTAssertEqual(lastButtonState, false)

        // Re-add button (basic timer next rep)
        messageExpectation = expectation(description: "Button re-added")
        try await webView.evaluateJavaScript("""
            var btn = document.createElement('button');
            btn.className = 'btn-fail-prominent';
            btn.textContent = 'Fail';
            document.body.appendChild(btn);
            void(0);
        """)
        await fulfillment(of: [messageExpectation!], timeout: 5)
        XCTAssertEqual(lastButtonState, true)
    }

    func testMultipleRemoveReAddCycles() async throws {
        // Load with enabled button
        messageExpectation = expectation(description: "Initial state")
        let html = "<html><body><button class=\"btn-fail-prominent\">Fail</button></body></html>"
        try await loadHTML(html)
        await fulfillment(of: [messageExpectation!], timeout: 5)
        XCTAssertEqual(lastButtonState, true)

        for cycle in 1...3 {
            // Remove
            messageExpectation = expectation(description: "Cycle \(cycle) remove")
            try await webView.evaluateJavaScript(
                "document.querySelector('button.btn-fail-prominent').remove();"
            )
            await fulfillment(of: [messageExpectation!], timeout: 5)
            XCTAssertEqual(lastButtonState, false, "Cycle \(cycle): expected false after removal")

            // Re-add
            messageExpectation = expectation(description: "Cycle \(cycle) re-add")
            try await webView.evaluateJavaScript("""
                var btn = document.createElement('button');
                btn.className = 'btn-fail-prominent';
                btn.textContent = 'Fail';
                document.body.appendChild(btn);
                void(0);
            """)
            await fulfillment(of: [messageExpectation!], timeout: 5)
            XCTAssertEqual(lastButtonState, true, "Cycle \(cycle): expected true after re-add")
        }
    }
}

// MARK: - Navigation Delegate Helper

private final class NavigationDelegate: NSObject, WKNavigationDelegate {
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
