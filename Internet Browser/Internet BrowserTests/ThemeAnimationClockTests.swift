//
//  ThemeAnimationClockTests.swift
//  Internet BrowserTests
//
//  Locks the rule that keeps every themed chrome surface on the same frame
//  of a theme's animated header image: the frame is a pure function of time
//  elapsed since ONE shared start, never of how long a given view has been
//  alive. Two surfaces reading the same clock therefore agree by definition,
//  including one created long after the other.
//

import XCTest
@testable import Cherry

final class ThemeAnimationClockTests: XCTestCase {

    /// Binary-exact delays (total 1.0s) so wrap-around arithmetic is compared
    /// without float slop.
    private let delays: [TimeInterval] = [0.25, 0.5, 0.25]

    private func frame(_ elapsed: TimeInterval, _ delays: [TimeInterval]? = nil) -> Int {
        ThemeAnimationClock.frameIndex(elapsed: elapsed, delays: delays ?? self.delays)
    }

    // MARK: - The pure function

    /// Catches a clock that starts anywhere but the first frame.
    func testStartOfTheLoopIsTheFirstFrame() {
        XCTAssertEqual(frame(0), 0)
    }

    /// Catches an off-by-one at a frame boundary: a frame's delay is how long
    /// it shows, so t = 0.25 is already the SECOND frame.
    func testFrameBoundaryIsInclusiveOfTheNextFrame() {
        XCTAssertEqual(frame(0.24), 0)
        XCTAssertEqual(frame(0.25), 1)
        XCTAssertEqual(frame(0.26), 1)
        XCTAssertEqual(frame(0.74), 1)
        XCTAssertEqual(frame(0.75), 2)
    }

    /// Catches a loop that runs off the end of the delay list (crash or stuck
    /// on the last frame) instead of wrapping.
    func testWrapsAroundTheLoopDuration() {
        XCTAssertEqual(frame(0.99), 2)
        XCTAssertEqual(frame(1.0), 0)
        XCTAssertEqual(frame(1.3), 1)
        XCTAssertEqual(frame(2.8), 2)
    }

    /// The assertion that actually proves two surfaces agree: the frame
    /// depends only on the position within the loop, so an elapsed time many
    /// loops later lands exactly where a short one does.
    func testManyLoopsLaterLandsWhereAShortElapsedDoes() {
        for offset in stride(from: 0.0, to: 1.0, by: 0.05) {
            XCTAssertEqual(
                frame(offset),
                frame(offset + 3600),
                "an hour of loops later must resolve to the same frame at offset \(offset)"
            )
        }
    }

    /// Catches a modulo/indexing rule that misbehaves when there is nothing
    /// to advance to.
    func testSingleFrameLayerAlwaysShowsItsOnlyFrame() {
        XCTAssertEqual(frame(0, [0.1]), 0)
        XCTAssertEqual(frame(5, [0.1]), 0)
        XCTAssertEqual(frame(1_000_000, [0.1]), 0)
    }

    /// Catches a divide-by-zero or an infinite scan on degenerate delay
    /// lists — an empty list, or one whose delays sum to zero.
    func testDegenerateDelayListsResolveToFrameZero() {
        XCTAssertEqual(frame(0, []), 0)
        XCTAssertEqual(frame(12.5, []), 0)
        XCTAssertEqual(frame(12.5, [0, 0, 0]), 0)
        XCTAssertEqual(frame(12.5, [0]), 0)
    }

    /// Zero-duration frames are skipped rather than displayed for a moment,
    /// and a negative or non-finite delay is treated as zero rather than
    /// dragging the loop duration backwards.
    func testNonPositiveDelaysAreTreatedAsZeroDurationFrames() {
        XCTAssertEqual(frame(0.1, [0, 0.5]), 1)
        XCTAssertEqual(frame(0.1, [-1, 0.5]), 1)
        XCTAssertEqual(frame(0.1, [.nan, 0.5]), 1)
        XCTAssertEqual(frame(0.1, [.infinity, 0.5]), 1)
    }

    /// A surface reading the clock with a garbage or pre-start time must
    /// still name a real frame rather than crash or index out of range.
    func testNonFiniteAndNegativeElapsedStayInRange() {
        XCTAssertEqual(frame(.nan), 0)
        XCTAssertEqual(frame(.infinity), 0)
        XCTAssertEqual(frame(-0.1), 2)
        XCTAssertEqual(frame(-1.3), 1)
    }

    // MARK: - The shared start time

    /// Catches a clock that restarts every time it is read, which would put
    /// every surface permanently on frame 0.
    func testTheStartTimeIsRecordedOncePerTheme() {
        let clock = ThemeAnimationClock.shared
        let themeID = "start-once-\(UUID().uuidString)"

        XCTAssertEqual(clock.elapsed(themeID: themeID, now: 1_000), 0)
        XCTAssertEqual(clock.elapsed(themeID: themeID, now: 1_004.5), 4.5)
        XCTAssertEqual(clock.elapsed(themeID: themeID, now: 1_009), 9)
    }

    /// A different theme starts its own loop at frame 0 rather than
    /// inheriting the previous theme's position — and the clock keeps only
    /// the running theme, so it stops answering for a theme that has been
    /// switched away from or removed (each import mints a fresh id, so a
    /// table keyed by theme would grow forever).
    func testSwitchingThemeRestartsTheClockAndForgetsTheOldOne() {
        let clock = ThemeAnimationClock.shared
        let first = "theme-a-\(UUID().uuidString)"
        let second = "theme-b-\(UUID().uuidString)"

        XCTAssertEqual(clock.elapsed(themeID: first, now: 1_000), 0)
        XCTAssertEqual(clock.elapsed(themeID: first, now: 1_004), 4)

        // Switching restarts the loop for the new theme…
        XCTAssertEqual(clock.elapsed(themeID: second, now: 1_007), 0)
        XCTAssertEqual(clock.elapsed(themeID: second, now: 1_009), 2)

        // …and the old theme's start is gone, not remembered.
        XCTAssertEqual(clock.elapsed(themeID: first, now: 1_009), 0)
    }

    // MARK: - The regression this whole change exists to prevent

    /// The bug: the tab strip and the toolbar each held their own frame
    /// counter, driven by their own timer from their own creation, so they
    /// displayed different frames of the same GIF and drifted further apart.
    ///
    /// This drives two genuinely independent frame-holding objects — the same
    /// `ThemeAnimationFrameCursor` the renderer stores — created 10.4s apart
    /// and pulled through the shared clock at the same instants, and checks
    /// three things at every step: the late surface agrees with the early one,
    /// BOTH match the frame the elapsed wall-clock time calls for (so a clock
    /// that agreed by standing still, e.g. always answering 0, fails here),
    /// and the animation actually moves.
    func testTwoSurfacesCreatedAtDifferentTimesShowTheSameFrame() {
        let clock = ThemeAnimationClock.shared
        let themeID = "two-surfaces-\(UUID().uuidString)"
        let firstAppeared: TimeInterval = 1_000
        let secondAppeared = firstAppeared + 10.4

        // Two surfaces, each with its own frame state, exactly as two chrome
        // canvases hold one cursor per animated layer.
        var early = ThemeAnimationFrameCursor()
        var late = ThemeAnimationFrameCursor()

        // The first surface to draw starts the theme's clock, then animates
        // alone until the second one appears (a new window, a split pane, the
        // toolbar coming back from fullscreen).
        for now in stride(from: firstAppeared, to: secondAppeared, by: 0.11) {
            _ = early.update(elapsed: clock.elapsed(themeID: themeID, now: now), delays: delays)
        }

        var framesSeen: Set<Int> = []
        for now in stride(from: secondAppeared, to: secondAppeared + 4, by: 0.13) {
            // Each surface reads the shared clock in its own draw pass.
            _ = early.update(elapsed: clock.elapsed(themeID: themeID, now: now), delays: delays)
            _ = late.update(elapsed: clock.elapsed(themeID: themeID, now: now), delays: delays)

            XCTAssertEqual(
                late.frameIndex, early.frameIndex,
                "surfaces born 10.4s apart show different frames at t=\(now)"
            )
            // Independently of the clock: the frame the elapsed time calls for.
            XCTAssertEqual(
                early.frameIndex, frame(now - firstAppeared),
                "the shared frame stopped tracking elapsed time at t=\(now)"
            )
            framesSeen.insert(early.frameIndex)
        }

        XCTAssertEqual(
            framesSeen, Set(0..<delays.count),
            "the surfaces agreed but the animation never ran through its frames"
        )

        // Guards the fixture: these two creation times must be ones the OLD
        // per-view timing (each cursor measuring from its own birth) actually
        // got wrong, or the assertions above would pass for the wrong reason.
        var perViewEarly = ThemeAnimationFrameCursor()
        var perViewLate = ThemeAnimationFrameCursor()
        var perViewEverDiverged = false
        for now in stride(from: secondAppeared, to: secondAppeared + 4, by: 0.13) {
            _ = perViewEarly.update(elapsed: now - firstAppeared, delays: delays)
            _ = perViewLate.update(elapsed: now - secondAppeared, delays: delays)
            if perViewEarly.frameIndex != perViewLate.frameIndex { perViewEverDiverged = true }
        }
        XCTAssertTrue(
            perViewEverDiverged,
            "fixture no longer reproduces the per-view drift it is guarding against"
        )
    }

    /// A cursor never counts frames of its own: pulled to an arbitrary point
    /// in the loop it lands there directly, so a surface that appears mid-loop
    /// snaps to the shared frame instead of starting over at 0. Also pins the
    /// "needs redrawing" answer the canvas uses to decide whether to repaint.
    func testCursorJumpsStraightToTheSharedFrameAndReportsChanges() {
        var cursor = ThemeAnimationFrameCursor()
        XCTAssertEqual(cursor.frameIndex, 0)

        XCTAssertTrue(cursor.update(elapsed: 10.4, delays: delays))
        XCTAssertEqual(cursor.frameIndex, 1)

        // Same frame again: no redraw.
        XCTAssertFalse(cursor.update(elapsed: 10.6, delays: delays))
        XCTAssertEqual(cursor.frameIndex, 1)

        XCTAssertTrue(cursor.update(elapsed: 10.8, delays: delays))
        XCTAssertEqual(cursor.frameIndex, 2)
    }
}
