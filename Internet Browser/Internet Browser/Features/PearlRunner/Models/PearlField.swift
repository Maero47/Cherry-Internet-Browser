//
//  PearlField.swift
//  Cherry Browser
//
//  How big the game is drawn — and nothing about how it is played.
//
//  ## One number, and what it is allowed to touch
//
//  The simulation is settled work. `PearlWorld` is 560×150 logical points,
//  `PearlTuning`'s jump arithmetic is measured against `PearlSpriteContract`'s
//  sizes, and `PearlRunnerGameTests` steps out frame by frame what a jump
//  clears. None of that may move because a window got wider. So the field's
//  size is not a second geometry: it is a single magnification applied to the
//  one that already exists, by `context.scaleBy` inside the canvas.
//
//  Everything drawn inside the world grows with it — Pearl, the cherry trees,
//  the gulls, the ground strip, the clouds, the moon, the score. Nothing
//  measured in world units changes: `feetLine` is still 140, Pearl still
//  stands at x 30, a large tree is still 50 tall, and a tap jump still clears
//  a small tree and provably not a large one. At scale 2 the same run is the
//  same run, twice the size.
//
//  ## Why the scale comes in halves
//
//  The sheet is pixel art authored at 1x and magnified nearest-neighbour
//  (`PearlSpriteLibrary`). A fractional magnification makes some source pixels
//  land on more device pixels than their neighbours — the row of Pearl's
//  whiskers three pixels tall and the row beside it two. Cherry's windows are
//  overwhelmingly on 2x displays, where a half-point step is a whole device
//  pixel, so the scale is quantised to halves and every source pixel comes out
//  the same size as every other.
//
//  Rounding is DOWNWARD, always. A field is allowed to be smaller than the
//  room it was given; it is never allowed to be bigger, because the thing
//  immediately outside it is the failure copy's margin.
//
//  ## The ceiling, the floor, and the height share
//
//  - 2× is the ceiling: 1120×300, which is as much of a full-screen window as
//    a 560-point world can take without Pearl reading as a poster.
//  - 0.5× is the floor: 280×75. Below the floor the art stops being legible,
//    so a container narrower than that gets a field that overhangs its margin
//    rather than a field nobody can see. The narrowest container Cherry can
//    actually produce is a 400-point split-view pane, which lands exactly on
//    the floor with room to spare.
//  - Half the container's height is the ceiling in the other direction. The
//    failure copy sits under the field, and a short window must not be all
//    game: at any height, half of it is still copy.
//

import Foundation

/// The drawn size of the runner's canvas, derived from the room it was given.
/// Pure arithmetic over two numbers — `PearlFieldTests` is the whole story.
nonisolated enum PearlField {

    /// The smallest magnification the field is ever drawn at.
    static let minimumScale = 0.5
    /// The largest. Past this the world is a poster, not a game.
    static let maximumScale = 2.0
    /// Magnification comes in these steps, rounded down. See the note above.
    static let scaleStep = 0.5
    /// At most this much of the container's height is game; the rest is the
    /// failure copy the game sits above.
    static let heightShare = 0.5
    /// The margin the field keeps on each side. `FailureColumn`'s own — read
    /// from it, not copied — so a field that has outgrown the reading column
    /// still stops where the column's copy stops.
    static var horizontalMargin: Double { FailureLayout.horizontalMargin }

    /// A drawn field: the magnification, and the two sizes that follow from it.
    struct Metrics: Equatable {
        let scale: Double

        var width: Double { PearlWorld.width * scale }
        var height: Double { PearlWorld.height * scale }
    }

    /// The field for a container of this size. Both dimensions are consulted:
    /// width decides how much of the world's measure fits beside the margins,
    /// height keeps the game from swallowing a short window.
    static func metrics(availableWidth: Double, availableHeight: Double) -> Metrics {
        let widthAllowance = (availableWidth - horizontalMargin * 2) / PearlWorld.width
        let heightAllowance = (availableHeight * heightShare) / PearlWorld.height
        let allowed = min(widthAllowance, heightAllowance, maximumScale)
        let stepped = (allowed / scaleStep).rounded(.down) * scaleStep
        return Metrics(scale: max(minimumScale, stepped))
    }

    /// The width of the reading column inside a container this wide — what
    /// `FailureColumn` lays its copy out in. The field is centred on this box
    /// and bleeds past it symmetrically, so a field wider than the column is
    /// still centred on the same axis as the words under it.
    static func columnWidth(availableWidth: Double) -> Double {
        max(0, min(FailureLayout.measure, availableWidth - horizontalMargin * 2))
    }

    /// How far the field hangs past each edge of the reading column. Zero when
    /// it fits inside the column, which is what a narrow window produces.
    static func bleed(availableWidth: Double, availableHeight: Double) -> Double {
        let metrics = metrics(availableWidth: availableWidth, availableHeight: availableHeight)
        return max(0, (metrics.width - columnWidth(availableWidth: availableWidth)) / 2)
    }
}
