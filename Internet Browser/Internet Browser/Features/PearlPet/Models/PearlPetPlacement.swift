//
//  PearlPetPlacement.swift
//  Cherry Browser
//
//  Where Pearl stands, and how she cannot end up lost.
//
//  ## She goes where she is put
//
//  She used to live on the FLOOR of the content area and slide along it, and
//  the argument for that was a good one: "the middle of the article" was not a
//  position this type could produce, so she could never be in front of the
//  sentence you were reading. The owner asked for the other thing — put her
//  where you want her — so the guarantee is gone and this is what replaced it:
//
//  - her DEFAULT is the old one, the bottom right corner, out of the way of
//    the left-hand column most pages put their body copy in;
//  - anywhere else is a thing the user did on purpose, by picking her up;
//  - and there is one row on her menu, **Send Pearl Home**, that undoes it —
//    so a cat parked somewhere awful is a mistake with a one-click way back
//    rather than a mistake you have to live with or switch her off over.
//
//  ## Her position is two fractions, never two points
//
//  A point saved from a 1600pt window puts her off the edge of a 900pt one,
//  and a point saved from a full-screen window puts her outside a restored one
//  entirely. A FRACTION of her travel re-lands correctly in any window, and
//  since the travel is recomputed from the window she is actually in, "she
//  survived a relaunch onto a smaller screen" is true by construction rather
//  than by a migration step somebody has to remember. `clamped()` then does
//  the rest: a hand-edited, corrupt or NaN preference can only produce a cat
//  standing somewhere legal.
//
//  ## The two edges she may not cross
//
//  Along the bottom she stops `floorInset` short of the edge, and at the sides
//  `sideInset`. At the TOP she stops one heart-headroom short — not because
//  the top of the page is precious, but because her reaction has to fit: the
//  hearts fly up out of the view she is drawn in, and a Pearl standing at the
//  very top would fire them off the top of the page. That is exactly the bug
//  `PearlHeartBurst` was written to fix in the setup wizard — a burst that is
//  painted, composited, and never once seen.
//

import CoreGraphics
import Foundation

/// Where on the page she is, as fractions of the room she has to move in.
///
/// `x` is 0 at the left of her travel and 1 at the right; `y` is 0 at the top
/// and **1 on the floor**, which is why `home` is `y: 1` — the floor is where
/// she started life and where "put her back" puts her.
struct PearlPetSpot: Equatable {

    var x: CGFloat
    var y: CGFloat

    /// Her corner: the bottom right, where she has always been.
    static let home = PearlPetSpot(x: 0.88, y: 1)

    /// The same spot with both axes forced into 0...1. A non-finite value is
    /// not clamped but replaced: NaN has no nearest legal value, and "she went
    /// home" is a better answer than "she went to the left edge".
    func clamped() -> PearlPetSpot {
        PearlPetSpot(
            x: PearlPetPlacement.clampedFraction(x, fallback: Self.home.x),
            y: PearlPetPlacement.clampedFraction(y, fallback: Self.home.y)
        )
    }

    /// Whether she is close enough to her corner that "Send Pearl Home" would
    /// do nothing. A fraction of travel, not points, so it means the same in
    /// every window.
    var isHome: Bool {
        abs(x - Self.home.x) < 0.01 && abs(y - Self.home.y) < 0.01
    }
}

enum PearlPetPlacement {

    /// The gap between her feet and the bottom edge of the page.
    static let floorInset: CGFloat = 4

    /// How close to the side edges she may stand.
    static let sideInset: CGFloat = 10

    /// Headroom above her for the hearts at 1x, and slack either side, so the
    /// view hosting her has somewhere to draw them. NONE of this is
    /// hit-testable — see `PearlPetView.hitTest`.
    static let baseHeartHeadroom: CGFloat = 46

    /// The headroom at a given size. It scales with her, because the burst is
    /// sized in fractions of the view it flies in: a bigger Pearl is literally
    /// bigger hearts (`PearlMascot`), and hearts sized for a 3x cat need the
    /// room a 3x cat's view has.
    static func heartHeadroom(for size: PearlPetSize) -> CGFloat {
        baseHeartHeadroom * size.scale
    }

    /// The sideroom is exactly `sideInset` on purpose, at every size: at
    /// either end of her travel the hosting view then reaches the content edge
    /// and stops, so it never hangs over a split-view divider or the window's
    /// own furniture. The burst's widest reach is a fraction of the span and
    /// fits inside it at all three sizes (`PearlPetHeartTests`).
    static var heartSideroom: CGFloat { sideInset }

    /// Her sprite's box, in points, at this size.
    static func spriteSize(for size: PearlPetSize) -> CGSize {
        size.standingSize
    }

    /// The box of the VIEW that hosts her: her sprite plus the room the hearts
    /// need.
    static func hostSize(for size: PearlPetSize) -> CGSize {
        let sprite = spriteSize(for: size)
        return CGSize(
            width: sprite.width + 2 * heartSideroom,
            height: sprite.height + heartHeadroom(for: size)
        )
    }

    /// The smallest content area a companion of this size belongs in.
    ///
    /// Two floors, and the larger wins. The first is absolute: in a window the
    /// size of a postage stamp she is not a companion, she is the page. The
    /// second is proportional and is what stops a 3x cat being drawn on a
    /// small window — she may never be more than a sixth of the page wide or a
    /// quarter of it tall. At `small` the absolute floor is the binding one,
    /// so this returns exactly the 420x260 it always did.
    static func minimumContentSize(for size: PearlPetSize) -> CGSize {
        let sprite = spriteSize(for: size)
        return CGSize(
            width: max(420, sprite.width * 6),
            height: max(260, sprite.height * 4)
        )
    }

    /// Whether a content area of this size has room for a cat of that one.
    static func fits(_ content: CGSize, size: PearlPetSize) -> Bool {
        let minimum = minimumContentSize(for: size)
        return content.width >= minimum.width && content.height >= minimum.height
    }

    /// Her sprite's rectangle in the content area's coordinates (y down, the
    /// way SwiftUI and a flipped `NSView` both count).
    ///
    /// Anything outside 0...1 — including a NaN out of a corrupt preference —
    /// is clamped rather than honoured, and the travel is measured against the
    /// content area she is being drawn in NOW, so a spot saved in a large
    /// window lands inside a small one.
    static func spriteFrame(
        in content: CGSize,
        size: PearlPetSize,
        spot: PearlPetSpot
    ) -> CGRect {
        let sprite = spriteSize(for: size)
        let spot = spot.clamped()
        let travel = travel(in: content, size: size)
        let floor = max(content.height - sprite.height - floorInset, 0)
        // With no vertical room to speak of — a window shorter than she is —
        // she goes on the floor rather than under the ceiling, because the
        // floor is the edge that is definitely on screen.
        let y = travel.height > 0 ? heartHeadroom(for: size) + travel.height * spot.y : floor
        return CGRect(
            x: sideInset + travel.width * spot.x,
            y: y,
            width: sprite.width,
            height: sprite.height
        )
    }

    /// The rectangle of the view that hosts her: her sprite plus the heart
    /// room. Kept inside the content area so it never forces an overhang.
    static func hostFrame(
        in content: CGSize,
        size: PearlPetSize,
        spot: PearlPetSpot
    ) -> CGRect {
        let sprite = spriteFrame(in: content, size: size, spot: spot)
        return CGRect(
            x: sprite.minX - heartSideroom,
            y: sprite.minY - heartHeadroom(for: size),
            width: sprite.width + 2 * heartSideroom,
            height: sprite.height + heartHeadroom(for: size)
        )
    }

    /// How far she can travel on each axis: the distance one whole unit of
    /// `spot` covers. A drag is measured in these, not in window coordinates,
    /// because the view being dragged is moving underneath the drag as it
    /// happens.
    static func travel(in content: CGSize, size: PearlPetSize) -> CGSize {
        let sprite = spriteSize(for: size)
        return CGSize(
            width: max(content.width - sprite.width - 2 * sideInset, 0),
            height: max(
                content.height - sprite.height - floorInset - heartHeadroom(for: size),
                0
            )
        )
    }

    /// Where a drag leaves her: the spot she was picked up from, moved by a
    /// distance in points, expressed back in fractions of her travel.
    ///
    /// The pointer's y counts UP the window and hers counts DOWN the page, so
    /// the vertical term is subtracted. An axis with no travel does not move,
    /// rather than dividing by zero.
    static func spot(
        draggedFrom start: PearlPetSpot,
        by delta: CGSize,
        in content: CGSize,
        size: PearlPetSize
    ) -> PearlPetSpot {
        let travel = travel(in: content, size: size)
        return PearlPetSpot(
            x: travel.width > 0 ? start.x + delta.width / travel.width : start.x,
            y: travel.height > 0 ? start.y - delta.height / travel.height : start.y
        ).clamped()
    }

    static func clampedFraction(_ value: CGFloat, fallback: CGFloat) -> CGFloat {
        guard value.isFinite else { return fallback }
        return min(max(value, 0), 1)
    }
}

/// Where the user last put her and how big she is, across tabs, windows and
/// launches.
///
/// Three numbers in `UserDefaults`, and one place for the whole app rather
/// than one per window or per tab. That is the decision, and the reason is
/// that the alternatives are worse in the same way: a pet that is in a
/// different corner in every tab is a pet you have to find, and a pet whose
/// position is keyed by window has no key that survives a relaunch — macOS
/// restores windows, not identities you can pin a cat to. One place means
/// "she is where I left her" is true of the whole browser.
///
/// None of it can corrupt anything: the only values these keys can produce are
/// numbers, every read goes through `PearlPetSpot.clamped()` or
/// `PearlPetSize.stored(_:)`, and a missing or unreadable key is her default.
/// Nothing else in Cherry reads them.
struct PearlPetHome {

    /// Kept at its original name and its original meaning — the fraction
    /// across her travel — so a Pearl who was already parked somewhere stays
    /// parked there.
    static let xKey = "pearlPetPosition"
    static let yKey = "pearlPetPositionY"
    static let sizeKey = "pearlPetSize"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var spot: PearlPetSpot {
        get {
            let stored = PearlPetSpot(
                x: defaults.object(forKey: Self.xKey) != nil
                    ? CGFloat(defaults.double(forKey: Self.xKey))
                    : PearlPetSpot.home.x,
                y: defaults.object(forKey: Self.yKey) != nil
                    ? CGFloat(defaults.double(forKey: Self.yKey))
                    : PearlPetSpot.home.y
            )
            return stored.clamped()
        }
        nonmutating set {
            let spot = newValue.clamped()
            defaults.set(Double(spot.x), forKey: Self.xKey)
            defaults.set(Double(spot.y), forKey: Self.yKey)
        }
    }

    var size: PearlPetSize {
        get {
            guard defaults.object(forKey: Self.sizeKey) != nil else { return .default }
            return PearlPetSize.stored(defaults.integer(forKey: Self.sizeKey))
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: Self.sizeKey)
        }
    }
}
