//
//  TabInteractionTests.swift
//  Internet BrowserTests
//
//  Covers the two pieces of pure logic behind tab-click reliability:
//
//  1. `TabInteraction.isClick` — the click/drag classifier. The tab bars' reorder
//     gesture and the tab items' click handling share one threshold, so every
//     press is EITHER a click or a drag: no press can fall through both (the old
//     2 pt drag threshold let a normal mouse click start a drag, which could
//     cancel the tap and lose the click) or be claimed by both.
//
//  2. `TabManager`'s drag-session tokens — the shared `draggedTabID` outlives its
//     gesture on purpose (a cross-window `onDrop` reads it after the gesture
//     ends), and the deferred cleanup that used to clear it unconditionally could
//     wipe out a drag that had started in the meantime.
//

import XCTest
@testable import Cherry

final class TabInteractionTests: XCTestCase {

    // MARK: - Click vs. drag

    func testPerfectlyStillPressIsAClick() {
        XCTAssertTrue(TabInteraction.isClick(translation: .zero))
    }

    func testSmallMouseSlipDuringAClickStillCounts() {
        // The reported failure mode: a physical mouse slides a few points
        // between button-down and button-up.
        XCTAssertTrue(TabInteraction.isClick(translation: CGSize(width: 3, height: -2)))
    }

    func testPressAtTheThresholdIsStillAClick() {
        XCTAssertTrue(
            TabInteraction.isClick(
                translation: CGSize(width: TabInteraction.dragActivationDistance, height: 0)
            )
        )
    }

    func testDragBeyondTheThresholdIsNotAClick() {
        XCTAssertFalse(
            TabInteraction.isClick(
                translation: CGSize(width: TabInteraction.dragActivationDistance + 1, height: 0)
            )
        )
    }

    func testDiagonalDistanceIsMeasuredRadially() {
        // 6×6 is 8.49 pt away — a drag, even though neither axis exceeds the
        // threshold on its own.
        XCTAssertFalse(TabInteraction.isClick(translation: CGSize(width: 6, height: 6)))
        // 5×5 is 7.07 pt — still a click.
        XCTAssertTrue(TabInteraction.isClick(translation: CGSize(width: 5, height: 5)))
    }

    func testClassificationIsDirectionAgnostic() {
        let far = TabInteraction.dragActivationDistance + 2
        for translation in [CGSize(width: far, height: 0), CGSize(width: -far, height: 0),
                            CGSize(width: 0, height: far), CGSize(width: 0, height: -far)] {
            XCTAssertFalse(TabInteraction.isClick(translation: translation))
        }
    }

    // MARK: - Press arbitration (which press belongs to a control)

    /// A tab row 240 pt wide at global x 100, with its close button's 20 pt hit
    /// target at the trailing end.
    private let closeHitRect = CGRect(x: 296, y: 8, width: 20, height: 20)

    func testPressOnTheCloseButtonBelongsToTheControl() {
        XCTAssertTrue(
            TabInteraction.pressIsOnControl(at: CGPoint(x: 306, y: 18),
                                            controlFrames: [closeHitRect])
        )
    }

    func testPressOnTheTabBodyDoesNotBelongToTheControl() {
        XCTAssertFalse(
            TabInteraction.pressIsOnControl(at: CGPoint(x: 150, y: 18),
                                            controlFrames: [closeHitRect])
        )
    }

    func testPressJustOutsideTheControlBelongsToTheTabBody() {
        // The strip immediately before the button must still select the tab —
        // a guard that is too wide would be a new click-eater.
        XCTAssertFalse(
            TabInteraction.pressIsOnControl(at: CGPoint(x: 295, y: 18),
                                            controlFrames: [closeHitRect])
        )
    }

    func testAControlThatIsNotOnScreenClaimsNothing() {
        // The caller passes no frame for a control it isn't rendering, so a
        // press anywhere belongs to the tab. This is the property that lingering
        // hover flags could not provide: they stayed `true` after the unmute
        // button vanished under the pointer and then swallowed every click.
        XCTAssertFalse(
            TabInteraction.pressIsOnControl(at: CGPoint(x: 306, y: 18), controlFrames: [])
        )
    }

    func testAnUnlaidOutControlFrameClaimsNothing() {
        // `.zero` is the pre-layout value of the frame state.
        XCTAssertFalse(
            TabInteraction.pressIsOnControl(at: .zero, controlFrames: [.zero])
        )
    }

    func testAnyOfSeveralControlsCanClaimThePress() {
        let muteHitRect = CGRect(x: 268, y: 8, width: 20, height: 20)
        XCTAssertTrue(
            TabInteraction.pressIsOnControl(at: CGPoint(x: 278, y: 18),
                                            controlFrames: [closeHitRect, muteHitRect])
        )
    }

    func testHitRectExpandsAControlsFrameToTheHitTarget() {
        // The reported frame is the 16 pt glyph; arbitration must use the same
        // 20 pt region the control is actually clickable across.
        let glyph = CGRect(x: 300, y: 10, width: 16, height: 16)
        let hit = TabInteraction.hitRect(for: glyph, visualSize: 16)
        XCTAssertEqual(hit, CGRect(x: 298, y: 8, width: 20, height: 20))
    }

    // MARK: - Control hit targets

    func testHitTargetInsetGrowsSmallControlsToTheTargetSize() {
        // The horizontal bar's close button draws at 16 pt, the vertical bar's
        // at 14 pt, and its unmute glyph at 12 pt — all must end up clickable
        // across the full 20 pt target.
        for visual in [CGFloat(16), 14, 12] {
            let inset = TabInteraction.hitTargetInset(forVisualSize: visual)
            XCTAssertEqual(visual - 2 * inset, TabInteraction.controlHitTargetSize, accuracy: 0.001)
        }
    }

    func testHitTargetInsetNeverShrinksAnAlreadyLargeControl() {
        XCTAssertEqual(TabInteraction.hitTargetInset(forVisualSize: 28), 0)
    }

    // MARK: - Drag sessions

    override func tearDown() {
        TabManager.clearDragSession(TabManager.dragSessionToken)
        super.tearDown()
    }

    func testBeginningASessionPublishesTheDraggedTab() {
        let id = UUID()
        let token = TabManager.beginDragSession(for: id)
        XCTAssertEqual(TabManager.draggedTabID, id)
        XCTAssertFalse(TabManager.reorderedByGesture)
        XCTAssertEqual(token, TabManager.dragSessionToken)
        XCTAssertNotEqual(token, 0, "0 is reserved for 'no session'")
    }

    func testEndingASessionKeepsTheDraggedTabReadableForALateDrop() {
        let id = UUID()
        let token = TabManager.beginDragSession(for: id)
        TabManager.endDragSession(token)
        // The gesture is over, but a cross-window onDrop still needs both facts.
        XCTAssertEqual(TabManager.draggedTabID, id)
        XCTAssertTrue(TabManager.reorderedByGesture)
    }

    func testClearingASessionWipesTheSharedState() {
        let token = TabManager.beginDragSession(for: UUID())
        TabManager.endDragSession(token)
        TabManager.clearDragSession(token)
        XCTAssertNil(TabManager.draggedTabID)
        XCTAssertFalse(TabManager.reorderedByGesture)
    }

    func testAStaleCleanupCannotClearANewerDrag() {
        // The regression: drag 1's deferred cleanup fires while drag 2 is live.
        let firstToken = TabManager.beginDragSession(for: UUID())
        TabManager.endDragSession(firstToken)

        let secondID = UUID()
        let secondToken = TabManager.beginDragSession(for: secondID)
        XCTAssertNotEqual(firstToken, secondToken)

        TabManager.clearDragSession(firstToken)   // drag 1's late timer

        XCTAssertEqual(TabManager.draggedTabID, secondID, "the live drag must survive")
    }

    func testAStaleEndCannotMarkANewerDragAsAlreadyReordered() {
        let firstToken = TabManager.beginDragSession(for: UUID())
        _ = TabManager.beginDragSession(for: UUID())
        TabManager.endDragSession(firstToken)
        XCTAssertFalse(
            TabManager.reorderedByGesture,
            "the newer drag has not reordered anything yet"
        )
    }

    func testTokenZeroIsNeverALiveSession() {
        let id = UUID()
        TabManager.beginDragSession(for: id)
        // A bar that never opened a session (e.g. a pinned tab, whose drag is
        // ignored) holds token 0 and must not touch anyone else's state.
        TabManager.endDragSession(0)
        TabManager.clearDragSession(0)
        XCTAssertEqual(TabManager.draggedTabID, id)
        XCTAssertFalse(TabManager.reorderedByGesture)
    }
}
