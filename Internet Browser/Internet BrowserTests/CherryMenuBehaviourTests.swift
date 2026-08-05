//
//  CherryMenuBehaviourTests.swift
//  Internet BrowserTests
//
//  The rules a menu has to obey that are not visible in a screenshot: which
//  rows ↑/↓ may land on, what a typed letter selects, which pixel row a click
//  belongs to, and whether the highlight stays legible. Each one is a way a
//  hand-drawn menu can quietly be worse than the `NSMenu` it replaced.
//

import XCTest
import SwiftUI
@testable import Cherry

final class CherryMenuBehaviourTests: XCTestCase {

    /// A menu with two sections and one unavailable command — the shape of
    /// Cherry's real ones.
    private let items: [CherryMenuItem] = [
        .action("Reload") {},
        .action("Duplicate Tab") {},
        .separator,
        .action("Open in New Window", enabled: false) {},
        .action("Mute Tab") {},
        .separator,
        .action("Close Tab") {},
    ]

    // MARK: - Keyboard

    func testArrowKeysSkipSeparators() {
        // Index 1 is "Duplicate Tab"; index 2 is a separator.
        let next = CherryMenuKeyboard.nextIndex(from: 1, direction: 1, items: items)
        XCTAssertEqual(next, 4, "Skipped both the separator and the disabled row.")
    }

    func testArrowKeysSkipDisabledRows() {
        let indices = (0..<items.count).compactMap { index -> Int? in
            items[index].isSelectable ? index : nil
        }
        XCTAssertEqual(indices, [0, 1, 4, 6], "Only enabled, non-separator rows are landing places.")
    }

    func testDownFromNothingSelectsTheFirstSelectableRow() {
        XCTAssertEqual(CherryMenuKeyboard.nextIndex(from: nil, direction: 1, items: items), 0)
    }

    func testUpFromNothingSelectsTheLastSelectableRow() {
        XCTAssertEqual(CherryMenuKeyboard.nextIndex(from: nil, direction: -1, items: items), 6)
    }

    func testHighlightWrapsAtBothEnds() {
        XCTAssertEqual(CherryMenuKeyboard.nextIndex(from: 6, direction: 1, items: items), 0)
        XCTAssertEqual(CherryMenuKeyboard.nextIndex(from: 0, direction: -1, items: items), 6)
    }

    /// A menu with nothing selectable must not spin looking for a row, and must
    /// not report one that cannot be activated.
    func testAMenuWithNothingSelectableHasNoHighlight() {
        let inert: [CherryMenuItem] = [.separator, .action("Unavailable", enabled: false) {}, .separator]
        XCTAssertNil(CherryMenuKeyboard.nextIndex(from: nil, direction: 1, items: inert))
        XCTAssertNil(CherryMenuKeyboard.firstIndex(in: inert))
        XCTAssertNil(CherryMenuKeyboard.lastIndex(in: inert))
    }

    func testHomeAndEndLandOnEnabledRows() {
        XCTAssertEqual(CherryMenuKeyboard.firstIndex(in: items), 0)
        XCTAssertEqual(CherryMenuKeyboard.lastIndex(in: items), 6)
    }

    // MARK: - Type-select

    func testTypingAPrefixJumpsToTheMatchingRow() {
        XCTAssertEqual(CherryMenuKeyboard.typeSelectIndex(prefix: "mu", from: nil, items: items), 4)
    }

    func testTypeSelectIgnoresDisabledRows() {
        // "Open in New Window" is disabled, so "o" must not land on it.
        XCTAssertNil(CherryMenuKeyboard.typeSelectIndex(prefix: "open", from: nil, items: items))
    }

    /// Repeating a letter cycles forward through the rows that start with it,
    /// which is what `NSMenu` does and the reason the search starts *after* the
    /// current row.
    func testRepeatingALetterCyclesThroughMatches() {
        let duplicates: [CherryMenuItem] = [
            .action("Close Tab") {},
            .action("Close Other Tabs") {},
            .action("Close Tabs to the Right") {},
        ]
        XCTAssertEqual(CherryMenuKeyboard.typeSelectIndex(prefix: "c", from: nil, items: duplicates), 0)
        XCTAssertEqual(CherryMenuKeyboard.typeSelectIndex(prefix: "c", from: 0, items: duplicates), 1)
        XCTAssertEqual(CherryMenuKeyboard.typeSelectIndex(prefix: "c", from: 2, items: duplicates), 0,
                       "And wraps rather than dead-ending.")
    }

    func testTypeSelectIsCaseInsensitive() {
        XCTAssertEqual(CherryMenuKeyboard.typeSelectIndex(prefix: "RELOAD", from: nil, items: items), 0)
    }

    // MARK: - Hit testing

    /// The pointer and the arrow keys have to agree on what a row is, and the
    /// menu's own arithmetic has to agree with what SwiftUI drew.
    func testHitTestingMatchesTheDrawnRowPositions() {
        for (index, item) in items.enumerated() where !item.isSeparator {
            let top = CherryMenuLayout.offsetFromTop(ofRow: index, in: items)
            let middle = top + CherryMenuLayout.height(of: item) / 2
            XCTAssertEqual(
                CherryMenuLayout.rowIndex(atOffsetFromTop: middle, in: items), index,
                "A point in the middle of row \(index) must hit row \(index)."
            )
        }
    }

    func testAPointOnASeparatorHitsNoRow() {
        let top = CherryMenuLayout.offsetFromTop(ofRow: 2, in: items)
        XCTAssertNil(CherryMenuLayout.rowIndex(atOffsetFromTop: top + 4, in: items))
    }

    func testPointsInThePaddingHitNoRow() {
        XCTAssertNil(CherryMenuLayout.rowIndex(atOffsetFromTop: 1, in: items))
        let below = CherryMenuLayout.contentHeight(of: items) + 5
        XCTAssertNil(CherryMenuLayout.rowIndex(atOffsetFromTop: below, in: items))
    }

    func testContentHeightIsThePaddingPlusEveryRow() {
        let expected = items.reduce(2 * CherryMenuMetrics.verticalPadding) { $0 + CherryMenuLayout.height(of: $1) }
        XCTAssertEqual(CherryMenuLayout.contentHeight(of: items), expected)
    }

    /// Titles truncating is the visible symptom of the width calculation and
    /// the row body disagreeing, so the width must grow with the longest title.
    func testWidthGrowsWithTheLongestTitle() {
        let short: [CherryMenuItem] = [.action("Open") {}]
        let long: [CherryMenuItem] = [.action("Close Tabs to the Right of This One") {}]
        XCTAssertGreaterThan(CherryMenuLayout.width(of: long), CherryMenuLayout.width(of: short))
        XCTAssertLessThanOrEqual(CherryMenuLayout.width(of: long), CherryMenuMetrics.maximumWidth)
        XCTAssertGreaterThanOrEqual(CherryMenuLayout.width(of: short), CherryMenuMetrics.minimumWidth)
    }

    func testASubmenuRowReservesRoomForItsChevron() {
        let plain: [CherryMenuItem] = [.action("Tab Group") {}]
        let withSubmenu: [CherryMenuItem] = [.submenu("Tab Group") { CherryMenuItem.action("New") {} }]
        XCTAssertGreaterThan(CherryMenuLayout.width(of: withSubmenu), CherryMenuLayout.width(of: plain))
    }

    // MARK: - Structure

    /// Conditional rows mean a separator can end up leading, trailing or
    /// doubled — a rule against nothing. `NSMenu` did not tidy these either;
    /// the old call sites were simply written so it never showed, and a menu
    /// built from `if`s cannot rely on that.
    func testStraySeparatorsAreDropped() {
        let messy: [CherryMenuItem] = [
            .separator, .separator,
            .action("Open") {},
            .separator, .separator,
            .action("Delete") {},
            .separator,
        ]
        let titles = messy.tidiedSeparators().map { $0.isSeparator ? "—" : $0.title }
        XCTAssertEqual(titles, ["Open", "—", "Delete"])
    }

    func testAnEmptySubmenuIsDisabledRatherThanAnOpenableDeadEnd() {
        let empty = CherryMenuItem.submenu("Tab Group") {}
        XCTAssertFalse(empty.isEnabled)
        XCTAssertFalse(empty.isSelectable)
    }

    func testASubmenuWithOnlyUnavailableRowsIsAlsoDisabled() {
        let inert = CherryMenuItem.submenu("Tab Group") {
            CherryMenuItem.action("Nothing here", enabled: false) {}
        }
        XCTAssertFalse(inert.isEnabled)
    }

    func testBuilderKeepsConditionalsAndLoops() {
        let showExtra = false
        let groups = ["Work", "Personal"]
        let built: [CherryMenuItem] = {
            @CherryMenuBuilder func make() -> [CherryMenuItem] {
                CherryMenuItem.action("Add to New Group") {}
                if showExtra { CherryMenuItem.action("Never") {} }
                for group in groups { CherryMenuItem.action(group) {} }
            }
            return make()
        }()
        XCTAssertEqual(built.map(\.title), ["Add to New Group", "Work", "Personal"])
    }

    // MARK: - Legibility

    /// The property that matters, over the palette that actually ships: text on
    /// the highlight clears WCAG AA for body text on EVERY accent the user can
    /// choose. Asserting the ratio rather than "this accent gets white" means
    /// adding a ninth accent fails here if it is unreadable, instead of
    /// shipping and being noticed by whoever picked it.
    ///
    /// White on Cherry's lighter accents (Emerald, Orange, Teal) measures about
    /// 3.6:1, which is why the rule is "whichever contrasts more" and not a
    /// brightness threshold.
    func testHighlightTextClearsWCAGAAOnEveryShippedAccent() {
        for option in AccentColorOption.options {
            let accent = Color(hex: option.hex)
            let ratio = CherryMenuColors.contrastRatio(
                of: CherryMenuColors.foregroundOn(accent), on: accent
            )
            XCTAssertGreaterThanOrEqual(
                ratio, 4.5,
                "\(option.name) (#\(option.hex)) highlights at \(String(format: "%.2f", ratio)):1, "
                    + "under WCAG AA for the 13pt a menu row is set in."
            )
        }
    }

    func testHighlightTextPicksTheHigherContrastOfBlackAndWhite() {
        for option in AccentColorOption.options {
            let accent = Color(hex: option.hex)
            let chosen = CherryMenuColors.foregroundOn(accent)
            let other: Color = chosen == .white ? .black : .white
            XCTAssertGreaterThanOrEqual(
                CherryMenuColors.contrastRatio(of: chosen, on: accent),
                CherryMenuColors.contrastRatio(of: other, on: accent),
                "\(option.name) would read better in the other one."
            )
        }
        XCTAssertEqual(CherryMenuColors.foregroundOn(.white), .black)
        XCTAssertEqual(CherryMenuColors.foregroundOn(.black), .white)
    }
}
