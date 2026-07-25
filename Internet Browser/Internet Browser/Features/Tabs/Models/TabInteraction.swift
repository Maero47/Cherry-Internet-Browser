//
//  TabInteraction.swift
//  Internet Browser
//

import Foundation

/// Pointer thresholds shared by both tab bars and their tab items, so that a
/// press on a tab is unambiguously EITHER a click or a drag — never both, and
/// never neither.
///
/// The single number that matters is `dragActivationDistance`: the bars' reorder
/// `DragGesture` uses it as its `minimumDistance`, and the tab items use the
/// same value as the slop a click is allowed to have. Because they are the same
/// number, every press lands in exactly one bucket. The old code used 2 pt for
/// the drag and left the click to `onTapGesture`'s own (undocumented) slop — a
/// physical mouse routinely slides 2-3 pt between button-down and button-up, so
/// the drag would start mid-click and could cancel the tap that was supposed to
/// select the tab.
enum TabInteraction {
    /// How far the pointer may travel between press and release while the press
    /// still counts as a click. Chrome uses a comparable threshold before it
    /// treats a press on a tab as a drag.
    static let dragActivationDistance: CGFloat = 8

    /// Hit-target edge for a tab's small controls (close, unmute). The glyph and
    /// its circular backdrop keep their old size; only the clickable region
    /// grows, so a slightly-off click still lands on the button instead of the
    /// tab body behind it.
    static let controlHitTargetSize: CGFloat = 20

    /// Outward inset that grows a control drawn at `visualSize` to
    /// `controlHitTargetSize`. Fed to `.contentShape(Rectangle().inset(by:))`,
    /// which enlarges the hit region *without* touching layout — growing the
    /// frame instead would widen every tab and squeeze the title.
    static func hitTargetInset(forVisualSize visualSize: CGFloat) -> CGFloat {
        -max(0, (controlHitTargetSize - visualSize) / 2)
    }

    /// How long the pointer must rest on a tab before its hover preview appears.
    static let previewDelayNanoseconds: UInt64 = 800_000_000

    /// True when a press whose pointer moved by `translation` should still be
    /// treated as a click on the tab. Anything larger is a drag, and the bars'
    /// reorder/tear-off gesture owns it.
    static func isClick(translation: CGSize) -> Bool {
        hypot(translation.width, translation.height) <= dragActivationDistance
    }
}
