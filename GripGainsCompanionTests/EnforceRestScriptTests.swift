import XCTest
import WebKit
@testable import GripGainsCompanion

@MainActor
final class EnforceRestScriptTests: XCTestCase {

    private var webView: WKWebView!

    /// Mirrors gripgains.ca's Advanced Settings "Rest" slider: a range input bound with
    /// v-model (listens for 'input'), with the value label re-rendered from the model.
    /// `window.setRest(n)` stands in for the page changing rest itself (presets, workouts).
    private static let sliderHTML = """
        <html><body>
        <div class="slider-item">
          <div class="slider-header">
            <span class="slider-label">Reps</span><span class="slider-value-display">6</span>
          </div>
          <input id="reps" type="range" min="1" max="10" value="6" class="modern-slider">
        </div>
        <div class="slider-item">
          <div class="slider-header">
            <span class="slider-label">Rest</span><span id="label" class="slider-value-display">%@s</span>
          </div>
          <input id="rest" type="range" min="20" max="60" step="10" value="%@" class="modern-slider" %@>
        </div>
        <script>
          window.model = %@;
          window.sets = 0;
          const input = document.getElementById('rest');
          const label = document.getElementById('label');
          function render() {
            input.value = String(window.model);
            label.textContent = window.model + 's';
          }
          window.inputs = 0;
          input.addEventListener('input', function() {
            window.inputs += 1;
            if (window.ignoreInput) { render(); return; }
            window.sets += 1;
            window.model = Number(input.value);
            render();
          });
          window.setRest = function(n) { window.model = n; render(); };
        </script>
        </body></html>
        """

    private static func html(rest: Int = 20, disabled: Bool = false) -> String {
        String(format: sliderHTML, "\(rest)", "\(rest)", disabled ? "disabled" : "", "\(rest)")
    }

    override func setUp() {
        super.setUp()
        let contentController = WKUserContentController()
        contentController.addUserScript(WKUserScript(
            source: JavaScriptBridge.enforceRestObserverScript,
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

    private func model() async throws -> Int {
        (try await webView.evaluateJavaScript("window.model") as? NSNumber)?.intValue ?? -1
    }

    private func sets() async throws -> Int {
        (try await webView.evaluateJavaScript("window.sets") as? NSNumber)?.intValue ?? -1
    }

    private func reps() async throws -> String? {
        try await webView.evaluateJavaScript("document.getElementById('reps').value") as? String
    }

    private func enforce(_ seconds: Int?) async throws {
        _ = try await webView.evaluateJavaScript(JavaScriptBridge.setEnforcedRest(seconds))
    }

    private func run(_ js: String) async throws {
        _ = try await webView.evaluateJavaScript(js + "; true;")
    }

    private func waitForModel(_ expected: Int, timeout: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await model() == expected { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let actual = try await model()
        XCTFail("Rest was \(actual)s, expected \(expected)s")
    }

    private func settle() async throws {
        try await Task.sleep(nanoseconds: 400_000_000)
    }

    // MARK: - Tests

    func testLeavesSliderAloneWhenNotEnforcing() async throws {
        try await loadHTML(Self.html(rest: 30))
        try await settle()
        let value = try await model()
        XCTAssertEqual(value, 30)
        let count = try await sets()
        XCTAssertEqual(count, 0)
    }

    func testSetsRestWhenEnabled() async throws {
        try await loadHTML(Self.html(rest: 30))
        try await enforce(40)
        try await waitForModel(40)
        try await settle()
        let count = try await sets()
        XCTAssertEqual(count, 1)
        let repsValue = try await reps()
        XCTAssertEqual(repsValue, "6", "Reps slider must not be touched")
    }

    func testDoesNothingWhenAlreadyAtTarget() async throws {
        try await loadHTML(Self.html(rest: 20))
        try await enforce(20)
        try await settle()
        let count = try await sets()
        XCTAssertEqual(count, 0)
    }

    func testResetsRestWhenPageChangesIt() async throws {
        try await loadHTML(Self.html(rest: 20))
        try await enforce(50)
        try await waitForModel(50)
        // Wait out the cooldown, then have the page change rest (e.g. a preset was picked).
        try await Task.sleep(nanoseconds: 350_000_000)
        try await run("window.setRest(30)")
        try await waitForModel(50)
    }

    func testSkipsDisabledSliderAndAppliesOnceEnabled() async throws {
        try await loadHTML(Self.html(rest: 30, disabled: true))
        try await enforce(60)
        try await settle()
        let lockedValue = try await model()
        XCTAssertEqual(lockedValue, 30)
        try await run("document.getElementById('rest').disabled = false")
        try await waitForModel(60)
    }

    func testAppliesToSliderThatAppearsLater() async throws {
        try await loadHTML("<html><body><div id=\"root\"></div></body></html>")
        try await enforce(40)
        try await run("""
            const tmp = document.createElement('div');
            tmp.innerHTML = \(Self.jsString(Self.sliderBodyOnly(rest: 20)));
            document.getElementById('root').appendChild(tmp);
            window.model = 20; window.sets = 0;
            const input = document.getElementById('rest');
            input.addEventListener('input', function() {
                window.sets += 1; window.model = Number(input.value);
                document.getElementById('label').textContent = window.model + 's';
            })
            """)
        try await waitForModel(40)
    }

    func testStopsEnforcingWhenTurnedOff() async throws {
        try await loadHTML(Self.html(rest: 20))
        try await enforce(40)
        try await waitForModel(40)
        try await enforce(nil)
        try await Task.sleep(nanoseconds: 350_000_000)
        try await run("window.setRest(30)")
        try await settle()
        let value = try await model()
        XCTAssertEqual(value, 30)
    }

    func testStopsAfterChangesThatNeverTake() async throws {
        try await loadHTML(Self.html(rest: 30))
        try await run("window.ignoreInput = true")
        try await enforce(50)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let value = try await model()
        XCTAssertEqual(value, 30)
        let attempts = (try await webView.evaluateJavaScript("window.inputs") as? NSNumber)?.intValue
        XCTAssertEqual(attempts, 3)
        // Further page changes don't restart a loop.
        try await run("window.setRest(30)")
        try await settle()
        let after = (try await webView.evaluateJavaScript("window.inputs") as? NSNumber)?.intValue
        XCTAssertEqual(after, 3)
    }

    // MARK: - Fixtures

    private static func sliderBodyOnly(rest: Int) -> String {
        """
        <div class="slider-item"><div class="slider-header">\
        <span class="slider-label">Rest</span><span id="label" class="slider-value-display">\(rest)s</span>\
        </div><input id="rest" type="range" min="20" max="60" step="10" value="\(rest)" class="modern-slider"></div>
        """
    }

    private static func jsString(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s])
        let array = String(data: data, encoding: .utf8)!
        return String(array.dropFirst().dropLast())
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
