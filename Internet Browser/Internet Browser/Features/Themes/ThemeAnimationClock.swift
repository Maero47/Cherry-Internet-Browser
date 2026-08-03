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

/// Which frame one animated layer is showing — the ONLY per-surface
/// animation state left in the app, and the state the desync bug lived in.
///
/// It is never *advanced*: it can only be pulled onto whatever
/// `ThemeAnimationClock.frameIndex` says for a given elapsed time. That is
/// what makes two of these, mutated independently and created at different
/// moments, unable to disagree — neither one counts, both look up.
struct ThemeAnimationFrameCursor {
    private(set) var frameIndex = 0

    /// Adopts the frame showing `elapsed` seconds into the shared clock.
    /// Returns true when that changed the frame, i.e. the layer needs
    /// redrawing.
    mutating func update(elapsed: TimeInterval, delays: [TimeInterval]) -> Bool {
        let index = ThemeAnimationClock.frameIndex(elapsed: elapsed, delays: delays)
        guard index != frameIndex else { return false }
        frameIndex = index
        return true
    }
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

    /// The running theme's start: recorded once by whichever surface reads
    /// the clock first, then shared by every surface after it.
    ///
    /// ONE slot, not a table keyed by theme. Each import mints a fresh theme
    /// id and removing a theme never notifies anything, so a table would
    /// accumulate an entry per theme ever imported and keep answering for
    /// themes that no longer exist. A single slot prunes itself: the next
    /// theme to ask replaces it.
    ///
    /// The cost is that if one surface still holds the outgoing theme id for
    /// a draw pass mid-switch, it restarts the loop — visible only as a frame
    /// jump at the instant the artwork changes anyway, and both surfaces still
    /// read the same start afterwards, so they stay in step.
    private var startedThemeID: String?
    private var start: TimeInterval = 0

    /// Seconds since `themeID`'s animations started. A theme id the clock is
    /// not already running starts a fresh loop at 0.
    func elapsed(themeID: String, now: TimeInterval = CACurrentMediaTime()) -> TimeInterval {
        guard startedThemeID == themeID else {
            startedThemeID = themeID
            start = now
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

    /// Also called from `deinit`. Note the table's weak key has ALREADY been
    /// pruned by the time a receiver's `deinit` runs, so that call's
    /// `removeObject` is a no-op — what actually stops the ticker is the
    /// `syncTimer()` below finding the table empty and invalidating.
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
