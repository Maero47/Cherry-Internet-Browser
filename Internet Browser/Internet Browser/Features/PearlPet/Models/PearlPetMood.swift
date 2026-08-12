//
//  PearlPetMood.swift
//  Cherry Browser
//
//  What Pearl is doing right now, as arithmetic.
//
//  ## Why this is a pure value and not a pile of timers
//
//  A desktop pet is a thing that changes on its own, and the obvious way to
//  build one is a timer per behaviour: a blink timer, a groom timer, a
//  fall-asleep timer, each cancelling and rescheduling the others. That is
//  four things to leak when a window closes and four things to get wrong when
//  the setting is switched off — and this project has already been bitten by a
//  timer outliving its view (see `ThemeAnimationClock`, whose whole design is
//  the same lesson).
//
//  So there are no behaviour timers. Which pose she is showing is a PURE
//  FUNCTION of two numbers — the current time and the time she was last
//  disturbed — exactly the way `ThemeAnimationClock.frameIndex` makes the
//  showing frame a pure function of elapsed time. One repeating tick asks this
//  function what to draw and stops as soon as nothing can change. Nothing
//  accumulates, so nothing can drift, and a mood that is never ticked is not a
//  mood that is stuck: it is simply the mood that time says it should be.
//
//  ## Her day
//
//  Left alone she runs a 24-second loop: sits and breathes, blinks twice,
//  grooms once. After two minutes with nobody touching her she falls asleep
//  and stays asleep until she is disturbed. A click or a fish interrupts
//  everything for as long as the reaction lasts.
//
//  The loop's phase is offset per pet, so two windows side by side do not
//  blink in lockstep like a pair of animatronics.
//

import Foundation

/// A pose Pearl can be in, named for the frame in the shared sprite sheet.
///
/// The raw values are manifest frame names, and `PearlPetSpriteTests` checks
/// every one of them against `PearlSpriteContract.frameCounts` — so a pose
/// invented here without art behind it fails a test rather than drawing
/// nothing at runtime.
enum PearlPetPose: String, CaseIterable {
    case sitting = "pet_sit"
    case blinking = "pet_blink"
    case grooming = "pet_groom"
    case delighted = "pet_happy"
    case eating = "pet_eat"
    case sleeping = "pet_sleep"

    var frameName: String { rawValue }

    /// Asleep she is a different shape, so she is drawn in a different box.
    var logicalSize: PearlSpriteContract.LogicalSize {
        self == .sleeping ? PearlSpriteContract.petSleeping : PearlSpriteContract.petStanding
    }
}

/// One drawable instant: which frame of which pose.
struct PearlPetAppearance: Equatable {
    var pose: PearlPetPose
    var frame: Int
}

/// Pearl's behaviour, as a value.
struct PearlPetMood: Equatable {

    // MARK: - The dial settings

    /// How often the view asks this value what to draw. Ten times a second is
    /// enough for a two-frame breath and a 0.2s blink, and is two orders of
    /// magnitude cheaper than a display link; see `PearlPetCostTests` for what
    /// one tick actually costs.
    static let tickInterval: TimeInterval = 0.1

    /// The idle loop, in seconds. A prime-ish number so the blink and the
    /// breath do not land on the same instant every time round.
    static let idleLoop: TimeInterval = 24

    /// Undisturbed for this long, she sleeps. Two minutes: long enough that
    /// she is awake while you are actually reading and settling in, short
    /// enough that a tab you left open has a sleeping cat on it rather than a
    /// cat staring at you for an hour.
    static let sleepsAfter: TimeInterval = 120

    /// How long a petting and a fish last.
    static let delightDuration: TimeInterval = 1.1
    static let mealDuration: TimeInterval = 2.4

    // MARK: - State

    /// Where in the idle loop this particular Pearl is, so two windows are not
    /// synchronised.
    var phaseOffset: TimeInterval = 0

    /// When she was last clicked, fed, dragged, or otherwise noticed.
    var lastDisturbed: TimeInterval = 0

    /// The reaction she is in the middle of, if any, and when it ends.
    private(set) var reaction: PearlPetPose?
    private(set) var reactionEnds: TimeInterval = 0

    /// True when she is a still picture: the user asked for less motion and
    /// nothing she was asked to do is still running. The view stops its tick
    /// entirely on this, which is the difference between "she stops moving"
    /// and "she disappears".
    func isStill(at now: TimeInterval, reduceMotion: Bool) -> Bool {
        guard reduceMotion else { return false }
        return reaction == nil || now >= reactionEnds
    }

    // MARK: - Being noticed

    /// Clicked. Hearts are the view's business; the pose is this one's.
    mutating func delight(at now: TimeInterval) {
        lastDisturbed = now
        reaction = .delighted
        reactionEnds = now + Self.delightDuration
    }

    /// Fed a fish.
    mutating func feed(at now: TimeInterval) {
        lastDisturbed = now
        reaction = .eating
        reactionEnds = now + Self.mealDuration
    }

    /// Picked up and moved, or otherwise interfered with: she wakes, but she
    /// does not celebrate. A reaction already in the air is left alone — being
    /// carried across the window while eating is not a reason to stop eating.
    mutating func disturb(at now: TimeInterval) {
        lastDisturbed = now
    }

    // MARK: - What she looks like

    /// The pose and frame showing at `now`.
    ///
    /// Under Reduce Motion she is a sitting cat and nothing else, EXCEPT while
    /// a reaction the user explicitly asked for is running: a fish that
    /// produces no visible reply reads as a broken menu item, and a pose swap
    /// with no animation is not the motion the setting is about.
    func appearance(at now: TimeInterval, reduceMotion: Bool = false) -> PearlPetAppearance {
        if let reaction, now < reactionEnds {
            let step = reaction == .eating ? 0.3 : 0.5
            let frame = frameCount(for: reaction) > 1
                ? Int((now - (reactionEnds - duration(of: reaction))) / step) % frameCount(for: reaction)
                : 0
            return PearlPetAppearance(pose: reaction, frame: max(frame, 0))
        }

        guard !reduceMotion else { return PearlPetAppearance(pose: .sitting, frame: 0) }

        if now - lastDisturbed >= Self.sleepsAfter {
            // Slow breathing, 1.4s a frame. Nothing else happens while she is
            // asleep: no blinking (her eyes are shut), no grooming.
            return PearlPetAppearance(pose: .sleeping, frame: Int((now / 1.4).rounded(.down)) % 2)
        }

        var phase = (now + phaseOffset).truncatingRemainder(dividingBy: Self.idleLoop)
        if phase < 0 { phase += Self.idleLoop }

        switch phase {
        case 5.6..<5.8, 19.0..<19.2:
            return PearlPetAppearance(pose: .blinking, frame: 0)
        case 11.4..<13.4:
            return PearlPetAppearance(pose: .grooming, frame: Int((phase - 11.4) / 0.25) % 2)
        default:
            // Breathing: a pixel of rise and fall, slower than a blink.
            return PearlPetAppearance(pose: .sitting, frame: Int(phase / 0.9) % 2)
        }
    }

    private func frameCount(for pose: PearlPetPose) -> Int {
        PearlSpriteContract.frameCounts[pose.frameName] ?? 1
    }

    private func duration(of pose: PearlPetPose) -> TimeInterval {
        pose == .eating ? Self.mealDuration : Self.delightDuration
    }
}
