//
//  TabInteraction.swift
//  Internet Browser
//

import Foundation
import CoreGraphics

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
    ///
    /// `translation` MUST be measured in the global coordinate space, the same
    /// space the bars' reorder gesture uses. In local space the number means
    /// something else entirely — the tab view itself jumps a whole slot on each
    /// reorder step, so local translation is the residual `pointer − view` and
    /// a finished reorder can look like a click.
    static func isClick(translation: CGSize) -> Bool {
        hypot(translation.width, translation.height) <= dragActivationDistance
    }

    /// Grows a control's reported frame to its real hit target, so press
    /// arbitration uses the same region hit-testing does.
    static func hitRect(for frame: CGRect, visualSize: CGFloat) -> CGRect {
        let inset = hitTargetInset(forVisualSize: visualSize)
        return frame.insetBy(dx: inset, dy: inset)
    }

    /// True when a press at `point` belongs to one of the row's controls
    /// (close, unmute) rather than to the tab body — which is how one press is
    /// kept from both closing and selecting a tab.
    ///
    /// Arbitration is by press LOCATION on purpose. The obvious alternative —
    /// remembering which control the pointer last hovered — goes stale the
    /// moment a control leaves the hierarchy while the pointer is still on it
    /// (click unmute and the button vanishes under the cursor, so its hover-exit
    /// never arrives), and a stuck flag would silently swallow every later click
    /// on that tab. A location has no memory to get stuck.
    ///
    /// Only frames of controls that are actually on screen may be passed in;
    /// callers gate each frame on the same condition that renders it.
    static func pressIsOnControl(at point: CGPoint, controlFrames: [CGRect]) -> Bool {
        controlFrames.contains { !$0.isEmpty && $0.contains(point) }
    }
}
