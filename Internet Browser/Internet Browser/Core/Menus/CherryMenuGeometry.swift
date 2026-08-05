//
//  CherryMenuGeometry.swift
//  Cherry Browser
//

import CoreGraphics

/// Where a Cherry-drawn menu goes on screen.
///
/// Split out as pure functions over `CGRect` because this is the one part of a
/// hand-drawn menu that `NSMenu` gets right silently and a re-implementation
/// gets wrong silently: a menu opened near the bottom of the screen must flip
/// rather than hang off the edge, and you cannot see that in a screenshot you
/// did not think to take. As free functions it is covered by tests at every
/// edge instead.
///
/// All rects are AppKit screen coordinates: origin bottom-left, y increasing
/// upward, which is what `NSWindow.setFrame` and `NSScreen.visibleFrame` speak.
enum CherryMenuGeometry {
    /// How much a submenu overlaps its parent, matching AppKit's look.
    static let submenuOverlap: CGFloat = 4
    /// The gap a menu keeps from the edge of the usable screen.
    static let screenMargin: CGFloat = 6

    /// The tallest a menu may be on this screen. Anything taller scrolls.
    static func maxHeight(in visible: CGRect) -> CGFloat {
        max(64, visible.height - 2 * screenMargin)
    }

    /// A context menu: its top-left corner sits at the click, and it flips
    /// up/left rather than being clipped.
    static func contextFrame(size: CGSize, at point: CGPoint, in visible: CGRect) -> CGRect {
        let below = CGRect(x: point.x, y: point.y - size.height, width: size.width, height: size.height)
        let flippedUp = CGRect(x: point.x, y: point.y, width: size.width, height: size.height)
        var frame = fitsVertically(below, in: visible) || !fitsVertically(flippedUp, in: visible) ? below : flippedUp
        frame = flipHorizontally(frame, pivot: point.x, in: visible)
        return clamp(frame, in: visible)
    }

    /// A menu hung off a control: it opens below, aligned to the control's left
    /// edge, and flips above the control when there is no room below.
    static func anchoredFrame(size: CGSize, below anchor: CGRect, in visible: CGRect) -> CGRect {
        let below = CGRect(x: anchor.minX, y: anchor.minY - size.height, width: size.width, height: size.height)
        let above = CGRect(x: anchor.minX, y: anchor.maxY, width: size.width, height: size.height)
        var frame = fitsVertically(below, in: visible) || !fitsVertically(above, in: visible) ? below : above
        frame = flipHorizontally(frame, pivot: anchor.maxX, in: visible)
        return clamp(frame, in: visible)
    }

    /// A submenu: to the right of its parent with its first row level with the
    /// row that opened it, flipping to the left when the right is full.
    static func submenuFrame(size: CGSize, rowTop: CGFloat, parent: CGRect, in visible: CGRect) -> CGRect {
        let right = CGRect(x: parent.maxX - submenuOverlap, y: rowTop - size.height, width: size.width, height: size.height)
        let left = CGRect(x: parent.minX - size.width + submenuOverlap, y: right.minY, width: size.width, height: size.height)
        let frame = right.maxX <= visible.maxX - screenMargin || left.minX < visible.minX + screenMargin ? right : left
        return clamp(frame, in: visible)
    }

    // MARK: - Pieces

    private static func fitsVertically(_ frame: CGRect, in visible: CGRect) -> Bool {
        frame.minY >= visible.minY + screenMargin && frame.maxY <= visible.maxY - screenMargin
    }

    /// Moves the menu to the other side of `pivot` when its right edge would
    /// leave the screen — the horizontal half of "flip rather than clip".
    private static func flipHorizontally(_ frame: CGRect, pivot: CGFloat, in visible: CGRect) -> CGRect {
        guard frame.maxX > visible.maxX - screenMargin else { return frame }
        let flipped = CGRect(x: pivot - frame.width, y: frame.minY, width: frame.width, height: frame.height)
        return flipped.minX >= visible.minX + screenMargin ? flipped : frame
    }

    /// Last resort when neither side fits: slide it fully on screen. A menu
    /// that is off the edge is unusable; one that is merely not where you
    /// expected still works.
    private static func clamp(_ frame: CGRect, in visible: CGRect) -> CGRect {
        var f = frame
        f.size.height = min(f.height, maxHeight(in: visible))
        f.origin.x = min(max(f.minX, visible.minX + screenMargin), max(visible.minX + screenMargin, visible.maxX - screenMargin - f.width))
        f.origin.y = min(max(f.minY, visible.minY + screenMargin), max(visible.minY + screenMargin, visible.maxY - screenMargin - f.height))
        return f
    }
}

/// Which row ↑/↓ moves to, given that separators and disabled rows are not
/// landing places. Pure so the wrap-around and the all-disabled case are
/// testable without a window on screen.
enum CherryMenuKeyboard {
    /// The next selectable index in `direction` (+1 down, −1 up), wrapping.
    /// `nil` when nothing in the menu can be selected at all.
    static func nextIndex(from current: Int?, direction: Int, items: [CherryMenuItem]) -> Int? {
        guard items.contains(where: \.isSelectable) else { return nil }
        let count = items.count
        var index = current ?? (direction > 0 ? -1 : count)
        for _ in 0..<count {
            index = ((index + direction) % count + count) % count
            if items[index].isSelectable { return index }
        }
        return nil
    }

    static func firstIndex(in items: [CherryMenuItem]) -> Int? {
        items.firstIndex(where: \.isSelectable)
    }

    static func lastIndex(in items: [CherryMenuItem]) -> Int? {
        items.lastIndex(where: \.isSelectable)
    }

    /// Type-select: the row a typed prefix jumps to, searching forward from the
    /// current row so repeated letters cycle through matches the way `NSMenu`
    /// does.
    static func typeSelectIndex(prefix: String, from current: Int?, items: [CherryMenuItem]) -> Int? {
        let needle = prefix.lowercased()
        guard !needle.isEmpty else { return nil }
        let count = items.count
        guard count > 0 else { return nil }
        let start = (current ?? -1) + 1
        for offset in 0..<count {
            let index = (start + offset) % count
            let item = items[index]
            guard item.isSelectable else { continue }
            if item.title.lowercased().hasPrefix(needle) { return index }
        }
        return nil
    }
}
