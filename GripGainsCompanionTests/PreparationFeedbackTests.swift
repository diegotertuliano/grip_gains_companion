import XCTest
import WebKit
@testable import GripGainsCompanion

final class PreparationFeedbackTests: XCTestCase {
    private var feedback = PreparationFeedback()

    private func sample(_ force: Double, at time: Double = 0, eligible: Bool = true,
                        target: Double? = 20, baseline: Double = 0) -> Double? {
        feedback.update(rawWeight: force, baseline: baseline, target: target,
                        engageThreshold: 10, releaseThreshold: 4, tolerance: 1,
                        eligible: eligible, now: time)
    }

    func testUnloadedAndBelowEngageAreSilent() {
        XCTAssertNil(sample(0))
        XCTAssertNil(sample(9.99))
        XCTAssertEqual(sample(10), -10)
    }

    func testReleaseThresholdAndHysteresis() {
        XCTAssertEqual(sample(10), -10)
        XCTAssertEqual(sample(4, at: 0.5), -16)
        XCTAssertNil(sample(3.99, at: 1))
        XCTAssertNil(sample(9, at: 1.5))
        XCTAssertEqual(sample(10, at: 2), -10)
    }

    func testToleranceDirectionAndCadence() {
        XCTAssertEqual(sample(15), -5)
        XCTAssertNil(sample(15, at: 0.49))
        XCTAssertEqual(sample(23, at: 0.5), 3)
        XCTAssertNil(sample(20, at: 0.6))
        XCTAssertEqual(sample(21, at: 0.7), 1)
    }

    func testPhaseExitAndMissingTargetResetHold() {
        XCTAssertNotNil(sample(10))
        XCTAssertNil(sample(10, eligible: false))
        XCTAssertNil(sample(5))
        XCTAssertNotNil(sample(10))
        XCTAssertNil(sample(10, target: nil))
        XCTAssertNil(sample(5))
    }

    func testBaselineOnlyAffectsLoadDetection() {
        XCTAssertNil(sample(12, baseline: 3))
        XCTAssertEqual(sample(13, baseline: 3), -7)
        XCTAssertNil(sample(6, at: 0.5, baseline: 3))
    }

    func testStreamGapRequiresReengagement() {
        XCTAssertNotNil(sample(10))
        XCTAssertNil(sample(5, at: 2))
        XCTAssertNotNil(sample(10, at: 2.5))
    }
}

@MainActor
final class PreparationStateObserverTests: XCTestCase, WKScriptMessageHandler {
    private var webView: WKWebView!
    private var expected: Bool?
    private var event: XCTestExpectation?

    override func setUp() {
        super.setUp()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(self, name: "remainingTime")
        configuration.userContentController.add(self, name: "preparationState")
        webView = WKWebView(frame: .zero, configuration: configuration)
    }

    override func tearDown() {
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView = nil
        super.tearDown()
    }

    nonisolated func userContentController(_ userContentController: WKUserContentController,
                                          didReceive message: WKScriptMessage) {
        guard message.name == "preparationState" else { return }
        let value = message.body as? Bool
        Task { @MainActor in
            XCTAssertEqual(value, self.expected)
            self.event?.fulfill()
        }
    }

    private func change(_ script: String, expecting value: Bool) async throws {
        expected = value
        event = expectation(description: "Preparation state \(value)")
        _ = try await webView.evaluateJavaScript(script)
        await fulfillment(of: [event!], timeout: 5)
        event = nil
    }

    func testInitialCountdownWithHiddenAndVisibleTimerCopies() async throws {
        try await change("""
            document.body.innerHTML = '<div class="timer-value timer-prep-start invisible">20</div><div class="timer-status invisible">Get ready</div><div class="rest-overlay"><div class="timer-value timer-prep-start">20</div><div class="timer-status">Get ready</div></div><button class="btn-fail-prominent" disabled>Fail Rep</button>';
            \(JavaScriptBridge.remainingTimeObserverScript)
            """, expecting: true)
        try await change("""
            document.querySelector('.timer-value').className = 'timer-value timer-hanging';
            document.querySelector('.timer-value').textContent = '30';
            document.querySelector('.timer-status').textContent = 'Rep 1';
            document.querySelector('.rest-overlay').remove();
            document.querySelector('.btn-fail-prominent').disabled = false;
            """, expecting: false)
    }

    func testPhasesAndDOMReplacement() async throws {
        // about:blank supplies a document without loading the live website.
        try await change("""
            document.body.innerHTML = '<div class="timer-value">20</div><div class="timer-status">Get ready</div><button class="btn-fail-prominent" disabled>Fail</button>';
            \(JavaScriptBridge.remainingTimeObserverScript)
            """, expecting: true)
        try await change("document.querySelector('.timer-status').textContent = 'Paused'", expecting: false)
        try await change("document.querySelector('.timer-status').textContent = 'Rest 1'", expecting: true)
        try await change("document.querySelector('button').disabled = false", expecting: false)
        try await change("document.querySelector('button').disabled = true; document.querySelector('.timer-status').textContent = 'Ready for Rep 2'", expecting: true)
        try await change("document.body.innerHTML = '<div class=\"timer-status\">Workout complete!</div>'", expecting: false)
        try await change("document.body.innerHTML = '<div class=\"timer-value\">20</div><div class=\"timer-status\">Get ready</div><button class=\"btn-fail-prominent\" disabled>Fail</button>'", expecting: true)
        try await change("document.querySelector('button').remove()", expecting: false)
    }
}
