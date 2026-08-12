//
//  PearlPetSize.swift
//  Cherry Browser
//
//  How big Pearl is, and why the answer is a whole number.
//
//  ## Pixel art cannot be scaled, only multiplied
//
//  Pearl is not a vector and she is not a photograph. She is 36x40 pixels
//  drawn by hand at 1x (`"scale": 1` in `pearl-sprites.json`), and every pixel
//  of her is a decision somebody made: her eye is two pixels, the glint in it
//  is one. Magnifying that by a WHOLE multiple with a nearest-neighbour filter
//  turns each of those pixels into a perfect square block — a 2x cat is the
//  same drawing with 2x2 blocks, and nothing about her shape changes.
//
//  Magnifying it by 1.5 does not. Nearest-neighbour at a fractional scale has
//  to decide, per output pixel, which input pixel it came from, and the answer
//  alternates: some source rows land on two output rows and some on one. Her
//  eye becomes 3 pixels wide and 2 tall; the one-pixel glint disappears from
//  one frame and reappears in the next as she breathes. The alternative —
//  a smoothing filter — is worse: it invents colours that are not in the
//  seven-colour palette the sheet is quantised to, and a blurred pixel cat is
//  neither pixel art nor a nice picture.
//
//  So the sizes offered are 1x, 2x and 3x and there is no slider. A slider
//  would be a control whose middle two thirds are broken.
//
//  ## Why these three
//
//  - **Small (1x, 36x40pt)** is what she was, kept because it is right on a
//    small laptop screen and for somebody who wants her present but not
//    noticed.
//  - **Medium (2x, 72x80pt)** is the new default. At 1x on a 1440pt-wide page
//    she is 2.5% of the width — a detail you have to look for. At 2x she reads
//    as a character sitting on the page, which is the thing the feature is
//    for, and she is still under a tenth of the page's width.
//  - **Large (3x, 108x120pt)** is as far as it goes, because 4x is a cat as
//    tall as a paragraph is wide, and at that point she is the page rather
//    than a pet on it. `PearlPetPlacement.minimumContentSize(for:)` is what
//    stops even 3x from being drawn in a window too small to carry it.
//
//  There is no "auto" that picks a size from the window: a pet whose size
//  changes when you resize the window is a pet that redraws itself at a
//  fractional multiple somewhere in the middle of the drag.
//

import CoreGraphics
import Foundation

enum PearlPetSize: Int, CaseIterable, Sendable {

    case small = 1
    case medium = 2
    case large = 3

    /// What she is on a fresh install: big enough to be a character.
    static let `default` = PearlPetSize.medium

    /// The whole multiple this size magnifies the sheet by. It IS the raw
    /// value, so the stored preference is the multiple rather than an opaque
    /// index that a reordering of this enum would silently reinterpret.
    var multiple: Int { rawValue }

    var scale: CGFloat { CGFloat(rawValue) }

    /// The menu row's title.
    var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }

    /// The size one pose is drawn at, in points: the pose's fixed logical box
    /// times this multiple. Every upright pose shares one box, so she can swap
    /// poses in place at any size (`PearlPetSpriteTests`).
    func spriteSize(for pose: PearlPetPose) -> CGSize {
        let logical = pose.logicalSize
        return CGSize(width: logical.width * scale, height: logical.height * scale)
    }

    /// Her standing box — the one the placement model reserves room for,
    /// because it is the taller and wider of the two.
    var standingSize: CGSize {
        CGSize(
            width: PearlSpriteContract.petStanding.width * scale,
            height: PearlSpriteContract.petStanding.height * scale
        )
    }

    /// A stored preference turned back into a size. Anything that is not one
    /// of the three multiples — a hand-edited number, a string, a key written
    /// by a future version — is her default rather than a cat of a size this
    /// code cannot draw.
    static func stored(_ raw: Int) -> PearlPetSize {
        PearlPetSize(rawValue: raw) ?? .default
    }
}
