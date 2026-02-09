import UIKit

@Observable
final class ForceChartDataSource {
    /// Raw samples — private, not read by views, no SwiftUI re-renders
    private var rawHistory: [(timestamp: Date, force: Double)] = []

    /// Display snapshot — updated at screen refresh rate only
    private(set) var displayHistory: [(timestamp: Date, force: Double)] = []

    private var displayLink: DisplayLinkHelper?
    private var needsUpdate = false

    init() {
        displayLink = DisplayLinkHelper { [weak self] in
            guard let self, self.needsUpdate else { return }
            self.needsUpdate = false
            self.displayHistory = self.rawHistory
        }
    }

    func addSample(timestamp: Date, force: Double) {
        rawHistory.append((timestamp: timestamp, force: force))
        needsUpdate = true
    }

    func clear() {
        rawHistory.removeAll()
        needsUpdate = true
    }

    deinit {
        displayLink = nil
    }
}

private class DisplayLinkHelper {
    private var displayLink: CADisplayLink?
    private let callback: () -> Void

    init(callback: @escaping () -> Void) {
        self.callback = callback
        displayLink = CADisplayLink(target: self, selector: #selector(update))
        displayLink?.add(to: .main, forMode: .common)
    }

    @objc private func update() {
        callback()
    }

    deinit {
        displayLink?.invalidate()
    }
}
