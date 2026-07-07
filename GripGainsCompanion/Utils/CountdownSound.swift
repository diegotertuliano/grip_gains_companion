import Foundation

/// Tracks the workout timer's remaining seconds and fires a per-second callback
/// during the final countdown (5, 4, 3, 2, 1, 0). Each second plays once; the state
/// resets when the timer climbs back above the countdown window (a new cycle) or is
/// cleared with `nil`. Ported from the Android fork's `CountdownSound`.
final class CountdownSound {
    private let countdownStartSeconds: Int
    private let playSecond: (Int) -> Void
    private var playedSeconds = Set<Int>()
    private var lastRemainingTime: Int?

    init(countdownStartSeconds: Int = 5, playSecond: @escaping (Int) -> Void) {
        self.countdownStartSeconds = countdownStartSeconds
        self.playSecond = playSecond
    }

    func onRemainingTimeChanged(_ seconds: Int?) {
        let previous = lastRemainingTime

        guard let seconds else {
            playedSeconds.removeAll()
            lastRemainingTime = nil
            return
        }

        let range = 0...countdownStartSeconds
        if seconds > countdownStartSeconds ||
            (previous != nil && seconds > previous! && range.contains(seconds)) {
            playedSeconds.removeAll()
        }

        if range.contains(seconds), playedSeconds.insert(seconds).inserted {
            playSecond(seconds)
        }

        lastRemainingTime = seconds
    }
}
