//
//  ThemeAnimationClock.swift
//  Internet Browser
//

import Foundation
import QuartzCore

/// A live themed chrome surface that wants a "please redraw" signal.
protocol ThemeAnimationTickReceiver: AnyObject {
    func themeAnimationDidTick()
}

/// The one animation clock every themed chrome surface reads — one clock per
/// theme, not one per view.
///
/// Which frame of an animated header image (GIF/APNG) is showing is a PURE
/// FUNCTION of wall-clock time since the theme's shared start, never of how
/// long a particular view has been alive. That is what keeps the tab strip
/// and the toolbar on the same frame: they compute the same number from the
/// same start time, so they agree by construction and cannot drift apart.
/// It also fixes late arrivals — a surface created ten seconds in (a new
/// window, a split pane, the toolbar reappearing when you leave fullscreen)
/// snaps straight to the frame everyone else is showing instead of starting
/// its own loop at frame 0. Synchronising per-view timers at creation would
/// do neither.
///
/// The ticker below is only a redraw signal. It no longer owns the frame
/// number, so a timer that starts late or slips cannot desync anything.
final class ThemeAnimationClock {
    static let shared = ThemeAnimationClock()

    // MARK: - The frame, as a pure function of elapsed time

    /// The frame showing `elapsed` seconds into a loop whose frames last
    /// `delays` seconds each: cumulative delays, wrapped by the loop's total
    /// duration.
    ///
    /// Degenerate input neither traps nor loops forever: an empty or
    /// single-frame list is always frame 0, so is a list of delays summing to
    /// zero, and individual non-positive/non-finite delays are treated as
    /// zero-duration frames — skipped, never displayed. A negative `elapsed`
    /// (a surface reading the clock before the recorded start) wraps back
    /// into the loop rather than falling off the front.
    static func frameIndex(elapsed: TimeInterval, delays: [TimeInterval]) -> Int {
        guard delays.count > 1, elapsed.isFinite else { return 0 }
        let sanitized = delays.map { $0.isFinite && $0 > 0 ? $0 : 0 }
        let duration = sanitized.reduce(0, +)
        guard duration > 0 else { return 0 }

        var position = elapsed.truncatingRemainder(dividingBy: duration)
        if position < 0 { position += duration }

        var cumulative: TimeInterval = 0
        for (index, delay) in sanitized.enumerated() {
            cumulative += delay
            if position < cumulative { return index }
        }
        // Only reachable when float rounding leaves `position` at the very
        // end of the loop.
        return sanitized.count - 1
    }

    // MARK: - The shared start time

    /// Recorded once per theme, by whichever surface reads the clock first,
    /// and shared by every surface after it. Keyed by theme so re-importing
    /// or switching themes starts a fresh loop at frame 0.
    private var starts: [String: TimeInterval] = [:]

    /// Seconds since `themeID`'s animations started.
    func elapsed(themeID: String, now: TimeInterval = CACurrentMediaTime()) -> TimeInterval {
        guard let start = starts[themeID] else {
            starts[themeID] = now
            return 0
        }
        return now - start
    }

    // MARK: - The shared redraw ticker

    /// Weak keys: a canvas whose window closed drops out of the table on its
    /// own, so a stale entry can never keep the ticker alive. The value is
    /// that canvas's shortest frame delay.
    private let receivers = NSMapTable<AnyObject, NSNumber>.weakToStrongObjects()
    private var timer: Timer?
    private var interval: TimeInterval = 0

    /// Starts redrawing `receiver` at least every `shortestFrameDelay`
    /// seconds. One timer serves every live canvas, running at the shortest
    /// interval any of them asked for.
    func addReceiver(_ receiver: ThemeAnimationTickReceiver, shortestFrameDelay: TimeInterval) {
        receivers.setObject(NSNumber(value: shortestFrameDelay), forKey: receiver)
        syncTimer()
    }

    /// Also called from `deinit`, so a closing window's canvas stops the
    /// ticker instead of leaving it firing.
    func removeReceiver(_ receiver: ThemeAnimationTickReceiver) {
        receivers.removeObject(forKey: receiver)
        syncTimer()
    }

    /// No animating canvas, no timer — the ticker only runs while something
    /// actually animates.
    private func syncTimer() {
        let delays = receivers.objectEnumerator()?.allObjects.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
        guard let shortest = delays.min() else {
            timer?.invalidate()
            timer = nil
            interval = 0
            return
        }
        let wanted = max(shortest, 1.0 / 60.0)
        guard timer == nil || wanted != interval else { return }
        timer?.invalidate()
        interval = wanted
        let newTimer = Timer(timeInterval: wanted, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // .common so the animation keeps running during scrolling/tracking.
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    private func tick() {
        for case let receiver as ThemeAnimationTickReceiver in receivers.keyEnumerator().allObjects {
            receiver.themeAnimationDidTick()
        }
    }
}
