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

    /// A different theme gets its own loop from frame 0 rather than
    /// inheriting the previous theme's position.
    func testEachThemeGetsItsOwnStart() {
        let clock = ThemeAnimationClock.shared
        let first = "theme-a-\(UUID().uuidString)"
        let second = "theme-b-\(UUID().uuidString)"

        XCTAssertEqual(clock.elapsed(themeID: first, now: 1_000), 0)
        XCTAssertEqual(clock.elapsed(themeID: second, now: 1_007), 0)
        XCTAssertEqual(clock.elapsed(themeID: first, now: 1_007), 7)
    }

    // MARK: - The regression this whole change exists to prevent

    /// The bug: the tab strip and the toolbar each ran their own timer from
    /// their own creation, so they displayed different frames of the same
    /// GIF. Here two surfaces are "created" 10.4s apart; reading the shared
    /// clock they resolve to the same frame, while the old per-view timing
    /// (each measuring from its own birth) demonstrably does not.
    func testSurfacesCreatedAtDifferentTimesResolveToTheSameFrame() {
        let clock = ThemeAnimationClock.shared
        let themeID = "two-surfaces-\(UUID().uuidString)"
        let firstSurfaceAppeared: TimeInterval = 1_000
        let secondSurfaceAppeared = firstSurfaceAppeared + 10.4

        // The first surface to render starts the theme's clock.
        XCTAssertEqual(clock.elapsed(themeID: themeID, now: firstSurfaceAppeared), 0)

        var perViewClocksEverDiverged = false
        for now in stride(from: secondSurfaceAppeared, to: secondSurfaceAppeared + 3, by: 0.17) {
            // Each surface asks the shared clock independently, as they do in
            // their own draw passes.
            let first = frame(clock.elapsed(themeID: themeID, now: now))
            let second = frame(clock.elapsed(themeID: themeID, now: now))
            XCTAssertEqual(first, second, "both surfaces must show the same frame at t=\(now)")

            // Same instant, old behaviour: each surface measuring from its own
            // creation. This is what the owner saw as "they don't move
            // together".
            if frame(now - firstSurfaceAppeared) != frame(now - secondSurfaceAppeared) {
                perViewClocksEverDiverged = true
            }
        }
        // Guards the fixture itself: if these creation times stopped landing
        // on different frames, the test above would pass for the wrong reason.
        XCTAssertTrue(
            perViewClocksEverDiverged,
            "fixture no longer reproduces the per-view drift it is guarding against"
        )
    }
}
