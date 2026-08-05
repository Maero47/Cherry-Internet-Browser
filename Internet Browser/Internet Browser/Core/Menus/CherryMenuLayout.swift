//
//  CherryMenuLayout.swift
//  Cherry Browser
//

import SwiftUI
import AppKit

/// Turns a list of items into the numbers the menu is built from: how tall it
/// is, how wide it needs to be, which row a point is over, and where a row's
/// top edge sits.
///
/// Deliberately arithmetic rather than a `GeometryReader` read-back. The panel
/// has to be sized and placed *before* it is shown — a menu that appears at the
/// wrong size and then corrects itself is worse than a native one — and
/// submenu placement needs a row's top edge in screen coordinates while the
/// row is still being laid out. Doing the layout by hand also makes hit
/// testing and edge flipping testable without putting a window on screen.
enum CherryMenuLayout {
    static func height(of item: CherryMenuItem) -> CGFloat {
        item.isSeparator ? CherryMenuMetrics.separatorHeight : CherryMenuMetrics.rowHeight
    }

    /// Total height of the panel's content, rows plus the padding above and
    /// below them.
    static func contentHeight(of items: [CherryMenuItem]) -> CGFloat {
        items.reduce(2 * CherryMenuMetrics.verticalPadding) { $0 + height(of: $1) }
    }

    /// Distance from the top of the menu to the top of row `index`.
    static func offsetFromTop(ofRow index: Int, in items: [CherryMenuItem]) -> CGFloat {
        items.prefix(index).reduce(CherryMenuMetrics.verticalPadding) { $0 + height(of: $1) }
    }

    /// The row under a point given as a distance from the top of the menu, or
    /// `nil` for the padding strips and for separators — which are not rows you
    /// can be "on", exactly as in `NSMenu`.
    static func rowIndex(atOffsetFromTop offset: CGFloat, in items: [CherryMenuItem]) -> Int? {
        guard offset >= CherryMenuMetrics.verticalPadding else { return nil }
        var y = CherryMenuMetrics.verticalPadding
        for (index, item) in items.enumerated() {
            let next = y + height(of: item)
            if offset < next { return item.isSeparator ? nil : index }
            y = next
        }
        return nil
    }

    /// How wide the menu has to be for its longest row to fit without
    /// truncating, clamped so one pathological title cannot produce a menu
    /// wider than the screen.
    static func width(of items: [CherryMenuItem]) -> CGFloat {
        let font = NSFont.systemFont(ofSize: CherryMenuMetrics.fontSize)
        var widest: CGFloat = 0
        for item in items where !item.isSeparator {
            // Every term mirrors one element of the row in
            // `CherryMenuContentView`; if a row grows a column, it grows here.
            var w = CherryMenuMetrics.rowHorizontalPadding * 2
                + CherryMenuMetrics.stateColumnWidth
                + CherryMenuMetrics.titleTrailingPadding
            if item.systemImage != nil { w += CherryMenuMetrics.iconColumnWidth }
            if item.swatch != nil { w += 14 }
            if item.hasSubmenu { w += CherryMenuMetrics.submenuChevronWidth }
            w += ceil((item.title as NSString).size(withAttributes: [.font: font]).width)
            widest = max(widest, w)
        }
        return min(max(widest, CherryMenuMetrics.minimumWidth), CherryMenuMetrics.maximumWidth)
    }
}
