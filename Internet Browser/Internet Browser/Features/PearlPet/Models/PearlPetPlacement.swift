//
//  PearlPetPlacement.swift
//  Cherry Browser
//
//  Where Pearl is allowed to stand, and where she is not.
//
//  ## The rule that makes her tolerable
//
//  She sits on top of a live page. The single most annoying thing a desktop
//  pet can do is stand in front of the sentence you are reading, so she is not
//  free to be anywhere: she lives on the FLOOR of the content area — a strip
//  one cat tall along the bottom edge — and the user moves her along it. There
//  is no way to drag her into the middle of the article, because "the middle
//  of the article" is not a position this type can produce.
//
//  That also keeps her off the two places a browser's own furniture lives: the
//  top, where the chrome, the address bar's autofill popup and a page's sticky
//  header are, and the vertical centre, where a form and its caret are while
//  you type into it.
//
//  ## Her position is one number
//
//  Not a point: a FRACTION of the usable width. A point saved from a 1600pt
//  window puts her off the edge of a 900pt one, and a point saved from a
//  full-screen window puts her outside a restored one entirely. A fraction
//  re-lands correctly in any window, and `frame(in:)` clamps whatever it is
//  given, so even a hand-edited or corrupt preference can only produce a cat
//  standing somewhere legal.
//

import CoreGraphics
import Foundation

enum PearlPetPlacement {

    /// The gap between her feet and the bottom edge of the page.
    static let floorInset: CGFloat = 4

    /// How close to the side edges she may stand.
    static let sideInset: CGFloat = 10

    /// Headroom above her for the hearts, and slack either side, so the view
    /// hosting her has somewhere to draw them. NONE of this is hit-testable —
    /// see `PearlPetView.hitTest`.
    ///
    /// The sideroom is exactly `sideInset` on purpose: at either end of her
    /// travel the hosting view then reaches the content edge and stops, so it
    /// never hangs over a split-view divider or the window's own furniture.
    static let heartHeadroom: CGFloat = 46
    static var heartSideroom: CGFloat { sideInset }

    /// She is not drawn in a content area smaller than this. A cat is 36pt
    /// wide; in a window the size of a postage stamp she is not a companion,
    /// she is the page.
    static let minimumContentSize = CGSize(width: 420, height: 260)

    /// Where she starts life: near the right edge, out of the way of the
    /// left-hand text column most pages put their body copy in.
    static let defaultPosition: CGFloat = 0.88

    /// Whether a content area of this size has room for her at all.
    static func fits(_ size: CGSize) -> Bool {
        size.width >= minimumContentSize.width && size.height >= minimumContentSize.height
    }

    /// Her sprite's rectangle in the content area's coordinates (y down, the
    /// way SwiftUI and a flipped `NSView` both count).
    ///
    /// `position` is a fraction of the usable width; anything outside 0...1 —
    /// including a NaN out of a corrupt preference — is clamped rather than
    /// honoured.
    static func spriteFrame(
        in content: CGSize,
        spriteSize: CGSize,
        position: CGFloat
    ) -> CGRect {
        let clamped = clampedPosition(position)
        let x = sideInset + travel(in: content, spriteSize: spriteSize) * clamped
        let y = max(content.height - spriteSize.height - floorInset, 0)
        return CGRect(x: x, y: y, width: spriteSize.width, height: spriteSize.height)
    }

    /// The rectangle of the VIEW that hosts her: her sprite plus the room the
    /// hearts need. Kept inside the content area so it never forces a
    /// scrollable overhang.
    static func hostFrame(
        in content: CGSize,
        spriteSize: CGSize,
        position: CGFloat
    ) -> CGRect {
        let sprite = spriteFrame(in: content, spriteSize: spriteSize, position: position)
        return CGRect(
            x: sprite.minX - heartSideroom,
            y: sprite.minY - heartHeadroom,
            width: sprite.width + 2 * heartSideroom,
            height: sprite.height + heartHeadroom
        )
    }

    /// How far she can walk: the width one whole unit of `position` covers.
    /// A drag is measured in these, not in window coordinates, because the
    /// view being dragged is moving underneath the drag as it happens.
    static func travel(in content: CGSize, spriteSize: CGSize) -> CGFloat {
        max(content.width - spriteSize.width - 2 * sideInset, 0)
    }

    static func clampedPosition(_ position: CGFloat) -> CGFloat {
        guard position.isFinite else { return defaultPosition }
        return min(max(position, 0), 1)
    }
}

/// Where the user last put her, across tabs, windows and launches.
///
/// One `Double` in `UserDefaults`. It is worth the storage because a pet you
/// have to shove out of the way every time you open a tab is a pet you switch
/// off, and it cannot corrupt anything: the only value it can produce is a
/// number, every read goes through `PearlPetPlacement.clampedPosition`, and a
/// missing or unreadable key is her default corner. Nothing else in Cherry
/// reads it.
struct PearlPetHome {

    static let key = "pearlPetPosition"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var position: CGFloat {
        get {
            guard defaults.object(forKey: Self.key) != nil else {
                return PearlPetPlacement.defaultPosition
            }
            return PearlPetPlacement.clampedPosition(CGFloat(defaults.double(forKey: Self.key)))
        }
        nonmutating set {
            defaults.set(Double(PearlPetPlacement.clampedPosition(newValue)), forKey: Self.key)
        }
    }
}
