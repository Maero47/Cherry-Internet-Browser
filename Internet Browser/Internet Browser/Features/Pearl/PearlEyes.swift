//
//  PearlEyes.swift
//  Cherry Browser
//
//  **What colour Pearl's eyes are, and the one line that changes it.**
//
//  Her eyes are the most recognisable thing about her — amber on a cream
//  sclera, against a coat so dark that on a dark surface it is the rim light
//  and the eyes that say a cat is there at all. Changing them is an identity
//  change, so this round asks the question rather than answering it: both
//  colours exist, one of them is painted into the shipped artwork, and
//  swapping is two mechanical steps that cannot get out of step with each
//  other.
//
//  ## To go the other way
//
//      1. change `shipping` below
//      2. `python3 Tools/pearl-eyes/pearl_eyes.py paint <that colour>`
//
//  That is the whole switch. `PearlEyeColourTests` decodes the shipped
//  artwork and measures it, so doing one step without the other fails a test
//  instead of shipping a lie — and going back to amber is a byte-for-byte
//  restore from `Tools/pearl-eyes/amber/`, not a re-render.
//
//  To delete the question entirely: keep whichever artwork is in the tree,
//  delete `Tools/pearl-eyes/`, this file, and `PearlEyeColourTests`. Nothing
//  else reads any of it.
//
//  ## Why this holds numbers and not just a name
//
//  The two values below are the sprite sheet's ACTUAL iris pixels — the sheet
//  is seven flat colours and these are two of them — and `paintedHue` is where
//  the painterly poses' irises land in OKLCh. They are here rather than in the
//  test so that the artwork, the tool that paints it and the test that checks
//  it are all quoting one source. `PearlMascot` deliberately does not read
//  any of this: nothing about how Pearl is drawn depends on her eye colour,
//  which is exactly why trying purple is cheap.
//

import Foundation

enum PearlEyes {

    /// **THE SWITCH.** See the file comment: change this, then run the tool.
    static let shipping: Colour = .purple

    enum Colour: String, CaseIterable, Sendable {

        /// What she shipped with: warm, in the same family as her coat's
        /// browns and as the gold rim light on her ears, so at sprite size her
        /// face reads as one warm shape.
        case amber

        /// The alternative this round exists to show. A rotation of the amber
        /// in OKLCh — the same lightness structure, the same internal
        /// variation, a hue 237° round — so it is her eye in a different
        /// colour rather than a differently drawn eye.
        case purple

        /// The bright iris value in `pearl-sprites.png`, where Pearl is seven
        /// flat colours and her eye is a handful of pixels.
        var spriteIris: (red: UInt8, green: UInt8, blue: UInt8) {
            switch self {
            case .amber: (232, 160, 32)
            case .purple: (189, 127, 225)
            }
        }

        /// The iris's shade value, one step down. In amber this is also the
        /// rim light on her ears and her back, which is why the sprite sheet's
        /// eyes cannot be found by colour alone — see `pearl_eyes.py`.
        var spriteIrisShade: (red: UInt8, green: UInt8, blue: UInt8) {
            switch self {
            case .amber: (184, 120, 24)
            case .purple: (141, 98, 179)
            }
        }

        /// Where the painterly poses' irises sit in OKLCh, as the circular
        /// mean hue of the iris pixels in the drawing.
        ///
        /// Not the same number as the rotation the tool applies (312°): a
        /// painted iris is a spread of hues from its dark rim to its lit edge,
        /// and this is where that spread's middle lands.
        var paintedHue: Double {
            switch self {
            case .amber: 70
            case .purple: 306
            }
        }
    }

    /// How far a pose's measured iris hue may sit from `paintedHue` before it
    /// is a different colour rather than the same one painted. The two answers
    /// are 237° apart, so this is not a bar being scraped.
    static let paintedHueTolerance: Double = 25
}
