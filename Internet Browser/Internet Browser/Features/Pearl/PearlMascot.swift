//
//  PearlMascot.swift
//  Cherry Browser
//
//  Pearl, drawn. Her poses, how big she is drawn in each place she appears,
//  the hearts she reacts with, and the one rule about when she is allowed to
//  react at all.
//
//  This is the mascot, NOT the game. `Features/PearlRunner` is the pixel-art
//  runner on the offline page and it owns its own sprite sheet and manifest;
//  nothing here reads that sheet and nothing there reads these imagesets.
//
//  ## Where she is, and where she deliberately is not
//
//  She earns four places:
//
//    - the wizard's welcome, where she introduces herself and is the page;
//    - the wizard's footer on the four question steps, small, where she is
//      the thing the hearts come out of when a choice is made;
//    - the wizard's last step, where she signs off;
//    - the three "you have none of these yet" library screens, asleep.
//
//  She is deliberately absent from: the homepage (a mascot on a surface the
//  user sees on every new tab, over a picture they chose, is wallpaper); the
//  "your search matched nothing" library states (the user is looking for
//  something, and a cat is not an answer); the toolbar; and the offline
//  failure page, where she already exists as a game and does not need a
//  second portrait above her own sprite.
//
//  ## Never in the way
//
//  Nothing here is hit-testable, nothing here delays a dismissal or a button,
//  and nothing here has to be dismissed. The hearts are an overlay with no
//  layout footprint; Pearl herself only ever occupies space a layout already
//  gave her.
//

import AppKit
import SwiftUI

enum PearlMascot {

    // MARK: - Poses

    /// The poses Pearl has been drawn in, and the ONE place their catalog
    /// names live. Every consumer resolves through here, so a renamed
    /// imageset is a compile-time rename rather than a picture that silently
    /// stops appearing — and `PearlPresenceTests` walks `allCases` to prove
    /// every one of them decodes out of the shipped catalog.
    enum Pose: String, CaseIterable {
        /// Sitting up, one paw raised, looking straight at you. The welcome.
        case waving = "PearlWave"
        /// Up on her back legs, paws lifted, mid-celebration. The last step.
        case delighted = "PearlDelighted"
        /// Compact, front-on, tail wrapped — drawn to survive being 34pt
        /// tall, which is why it is a separate drawing and not the hero
        /// shrunk down: the hero's raised paw and long tail turn to mush at
        /// that size.
        case sitting = "PearlSitting"
        /// Curled up asleep. The library screens that have nothing in them.
        case curled = "PearlCurled"
        /// The original hero: seated, gazing up and away. Kept because it is
        /// the drawing the art landed with and it is still the best portrait
        /// of her; not currently placed, because every screen that wanted a
        /// portrait wanted her looking at the reader instead.
        case gazing = "PearlHero"

        var assetName: String { rawValue }

        @MainActor var image: NSImage? { NSImage(named: rawValue) }
    }

    // MARK: - How big she is drawn

    /// The welcome step. She is the largest thing on the page — the page
    /// reads as her greeting rather than as a form with a picture on it — and
    /// still leaves the title, the paragraph and the footer un-scrolled
    /// inside the sheet's 560pt. Four points shorter than she first shipped,
    /// because the line under her grew from 24pt to 30pt and the picture is
    /// what pays for that, not the paragraph's breathing room.
    static let heroHeight: CGFloat = 196

    /// The wizard footer on the question steps. Small enough to be a
    /// companion rather than a participant, big enough that her ears and eyes
    /// still separate.
    static let companionHeight: CGFloat = 34

    /// The last step, where she comes back on stage to sign off beside the
    /// one card that step has.
    static let farewellHeight: CGFloat = 132

    /// A library screen with nothing in it yet.
    static let restingHeight: CGFloat = 104

    // MARK: - Compatibility with the wizard's first landing

    /// The welcome step's pose, still reachable under the name the wizard
    /// shipped with.
    static var heroAssetName: String { Pose.waving.assetName }

    @MainActor
    static var heroImage: NSImage? { Pose.waving.image }

    // MARK: - The hearts

    /// Her hearts are HERS, not the theme's.
    ///
    /// The obvious move is to tint them with the user's accent, and it is
    /// wrong twice: Cherry's accents run to yellows and greens, and a green
    /// heart is not a heart; and the accent is already spent on the progress
    /// rule and the controls right beside them. So they are drawn in the
    /// peach of her own inner ears, pushed to a rose deep enough (light) and
    /// light enough (dark) to clear the 3:1 graphical-object floor against
    /// the sheet's own material — measured in `PearlContrastTests`, not
    /// eyeballed.
    static let heartTint = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 1.00, green: 0.56, blue: 0.64, alpha: 1)
            : NSColor(srgbRed: 0.84, green: 0.26, blue: 0.37, alpha: 1)
    })
}

// MARK: - When she is allowed to react

/// Pearl's reactions, and the single rule that governs them.
///
/// Deliberately its own object rather than state on `SetupWizardModel`: that
/// model is pinned by a reflection test to hold navigation and nothing else,
/// because this codebase has twice been hurt by a second copy of a fact. A
/// heart burst is not navigation, so it lives here.
///
/// `pulse` is a monotonically rising counter rather than a bool, because that
/// is what makes a SECOND reaction to the same kind of event visible: the
/// burst view is `.id`-ed on it, so every increment builds a fresh set of
/// hearts and re-runs their animation. It is not a queue and it is not
/// cancellable — a reaction that arrives while the last one is still in the
/// air simply replaces it.
@MainActor
@Observable
final class PearlReactions {

    /// What she is reacting to. Carried so a test can say WHICH moment fired,
    /// not merely that something did.
    enum Reason: String, Equatable {
        /// The user picked something that was written to settings.
        case choice
        /// A step was completed and the wizard moved forward.
        case stepDone
        /// The wizard reached its last step.
        case arrived
    }

    private(set) var pulse = 0
    private(set) var lastReason: Reason?

    /// The one rule: **under Reduce Motion nothing fires at all.**
    ///
    /// Not "fires without animating" — the hearts ARE the animation, and a
    /// static rosette of hearts sitting permanently over the footer is worse
    /// than no reaction. So the counter does not move, the burst never
    /// enters the tree, and `lastReason` stays where it was. The caller
    /// passes the environment value rather than this object reading an
    /// AppKit global, so the accessibility setting under test is the one
    /// SwiftUI actually resolved for the view.
    func fire(_ reason: Reason, reduceMotion: Bool) {
        guard !reduceMotion else { return }
        lastReason = reason
        pulse += 1
    }
}

// MARK: - Drawing her

/// Pearl at a given size, and nothing else — no plate, no clip, no shadow of
/// ours. Every pose is a cut-out with its own alpha and its own cream rim
/// light; that rim is what separates her from the surface behind her, in both
/// appearances, and it is measured rather than assumed.
///
/// Resolved in `init` rather than in `body`, and STORED — which is not a
/// stylistic preference, it is what makes "Pearl is on this screen" checkable
/// without rendering a pixel.
///
/// A `Mirror` walk over a SwiftUI value tree stops at a child view's
/// boundary: it can see that a `PearlPortrait` is there, but it cannot look
/// inside that portrait's `body`, because a body is a function nobody has
/// called. Resolving in `init` puts the decoded `NSImage` and the `Image`
/// built from it into this struct's own stored properties, where the walk
/// finds them — so `SetupWizardPearlTests` still fails on a renamed imageset
/// or a stand-in creeping back, exactly as it did when the welcome step
/// inlined the resolution itself.
struct PearlPortrait: View {
    let pose: PearlMascot.Pose
    let height: CGFloat
    /// What VoiceOver says. She is a picture of a cat, so she says so — but
    /// the sentence differs by where she is, and a mascot that announces
    /// itself identically five times is noise.
    let label: String

    /// Her artwork, already decoded and already wrapped — nil only if the
    /// catalog has no such imageset, a branch nobody should ever see since
    /// these are compiled into the same bundle by the same build, and one that
    /// `PearlPoseTests` fails on.
    ///
    /// Exactly ONE image is stored, not the `NSImage` and an `Image` built
    /// from it: `Image(nsImage:)` carries the bitmap inside itself, so keeping
    /// both would put two `NSImage`s into the value tree and make "the welcome
    /// page draws one thing" read as two.
    let artwork: Image?

    @MainActor
    init(pose: PearlMascot.Pose, height: CGFloat, label: String) {
        self.pose = pose
        self.height = height
        self.label = label
        self.artwork = pose.image.map { Image(nsImage: $0) }
    }

    var body: some View {
        if let artwork {
            artwork
                .resizable()
                .scaledToFit()
                .frame(height: height)
                .accessibilityLabel(label)
        }
    }
}

/// The heart. Two lobes and a point, drawn rather than borrowed: an SF Symbol
/// `heart.fill` next to hand-painted artwork reads as a system glyph that
/// wandered in, and this one can be shaped to her — wider lobes, a shorter
/// point, softer than the symbol's.
struct PearlHeartShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + w * x, y: rect.minY + h * y)
        }

        var path = Path()
        path.move(to: point(0.5, 1.0))
        path.addCurve(to: point(0.0, 0.30),
                      control1: point(0.13, 0.80), control2: point(0.0, 0.55))
        path.addCurve(to: point(0.5, 0.23),
                      control1: point(0.0, 0.04), control2: point(0.40, 0.00))
        path.addCurve(to: point(1.0, 0.30),
                      control1: point(0.60, 0.00), control2: point(1.0, 0.04))
        path.addCurve(to: point(0.5, 1.0),
                      control1: point(1.0, 0.55), control2: point(0.87, 0.80))
        path.closeSubpath()
        return path
    }
}

/// Three hearts, rising and gone in under a second.
///
/// Always used as an `.overlay`, so it takes its geometry from whatever it is
/// over and contributes none of its own: nothing on screen moves when Pearl
/// reacts. Non-hit-testable, so it can never intercept a click meant for the
/// control the user is actually using. Callers `.id` it on
/// `PearlReactions.pulse`, which is what makes a second reaction build a fresh
/// set of hearts and re-run them rather than being swallowed.
///
/// Nothing here checks Reduce Motion, on purpose: the check happens once, in
/// `PearlReactions.fire`, and this view is only ever built from a pulse that
/// got past it. One rule, one place.
struct PearlHeartBurst: View {
    var body: some View {
        ZStack {
            heart(size: 11, drift: -13, delay: 0.00, rise: 30)
            heart(size: 15, drift: 2, delay: 0.07, rise: 37)
            heart(size: 9, drift: 12, delay: 0.15, rise: 27)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func heart(size: CGFloat, drift: CGFloat, delay: Double, rise: CGFloat) -> some View {
        PearlHeartShape()
            .fill(PearlMascot.heartTint)
            .frame(width: size, height: size)
            .keyframeAnimator(initialValue: Phase(), repeating: false) { view, phase in
                view
                    .opacity(phase.opacity)
                    .scaleEffect(phase.scale)
                    .offset(x: drift * phase.travel, y: -rise * phase.travel)
            } keyframes: { _ in
                // Held invisible through the stagger, popped on, carried up,
                // faded out over the last third. The whole thing is 0.86s at
                // the latest heart, which is short enough to be a reaction
                // rather than an animation the user watches.
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(0, duration: delay)
                    LinearKeyframe(1, duration: 0.10)
                    LinearKeyframe(1, duration: 0.32)
                    LinearKeyframe(0, duration: 0.29)
                }
                KeyframeTrack(\.scale) {
                    LinearKeyframe(0.3, duration: delay)
                    SpringKeyframe(1.0, duration: 0.24, spring: .bouncy)
                    LinearKeyframe(0.86, duration: 0.47)
                }
                KeyframeTrack(\.travel) {
                    LinearKeyframe(0, duration: delay)
                    CubicKeyframe(1, duration: 0.71)
                }
            }
    }

    private struct Phase {
        var opacity = 0.0
        var scale = 0.3
        var travel = 0.0
    }
}
