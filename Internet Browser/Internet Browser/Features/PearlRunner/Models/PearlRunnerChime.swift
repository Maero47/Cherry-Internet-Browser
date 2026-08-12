//
//  PearlRunnerChime.swift
//  Cherry Browser
//
//  The first sound Cherry has ever made, and every reason it refuses to.
//
//  ## What it is, and why it is not shipped
//
//  It is `Tink` — `/System/Library/Sounds/Tink.aiff`, played through
//  `NSSound`. Not an asset in the bundle, on purpose:
//
//  * It is already on every Mac this app can run on, so there is nothing to
//    download, nothing to license, and no growth in a browser's bundle for a
//    hundred milliseconds of an easter egg.
//  * The requirement that decided it is "small and pleasant at every repeat".
//    A run past 2000 points rings this twenty times. A sound the user has
//    heard ten thousand times already, in Finder and in every text field that
//    ever refused a keystroke, is a sound that does not announce itself on the
//    twentieth repeat — a custom one would.
//  * It is the shortest of the fourteen system sounds and the only one with no
//    tail, which is what keeps it a tick rather than a chord.
//
//  The Chrome runner ships its own instead (`sounds/score-reached.mp3`, 9.5kB,
//  base64'd into the page and decoded through WebAudio). It has to: a web page
//  cannot reach the system's sound set. Cherry can, so Cherry does.
//
//  ## Where it refuses
//
//  A game noise is the easiest thing in a browser to hate, so the decision is
//  a pure function with every refusal named — `PearlChime.verdict` — and the
//  class below is only the machinery that gathers the conditions. Six ways to
//  get silence:
//
//      tornDown        the surface has gone; the page came back
//      gameOver        the run has crashed
//      notFrontmost    Cherry is not the active app, or its window is not key
//      muted           the player pressed M (remembered across launches)
//      systemSilenced  "Play user interface sound effects" is off
//      volumeZero      the alert volume slider is at the bottom
//
//  The last two are the honest limit of what macOS will tell an app. There is
//  no public API for Do Not Disturb or for a Focus mode — `NSApplication`,
//  `NSWorkspace` and `UserNotifications` all decline to say — so the closest
//  thing to that convention that can actually be honoured is the pair of
//  global preferences the Sound settings pane writes, and they are honoured
//  here: `com.apple.sound.uiaudio.enabled` is the checkbox, and
//  `com.apple.sound.beep.volume` is the slider directly above it. This chime
//  is a user-interface sound effect by any reading, so it is governed by the
//  control that governs those, at the volume that control sets.
//

import AppKit
import Foundation

// MARK: - The rule

/// Whether the milestone chime may be heard, as a value. Pure and
/// `nonisolated` so every refusal above is one assertion in a test rather than
/// a scenario that has to be staged in a window.
nonisolated enum PearlChime {

    /// Everything the answer depends on. Gathered by `PearlRunnerChime`;
    /// nothing here reads the machine.
    struct Conditions: Equatable {
        /// The run is still going — `phase == .running`.
        var gameIsRunning: Bool
        /// The surface still exists. False after `shutDown()`.
        var surfaceIsAlive: Bool
        /// Cherry is the active application and the runner's window is key.
        var isFrontmost: Bool
        /// The player has not pressed M.
        var playerWantsSound: Bool
        /// System Settings ▸ Sound ▸ "Play user interface sound effects".
        var systemPlaysInterfaceSounds: Bool
        /// The alert-volume slider, 0...1.
        var alertVolume: Double
    }

    enum Reason: String, Equatable {
        case tornDown
        case gameOver
        case notFrontmost
        case muted
        case systemSilenced
        case volumeZero
    }

    enum Verdict: Equatable {
        case play(volume: Double)
        case silent(Reason)
    }

    /// Ordered from "there is nothing left to play into" outwards, so the
    /// reason a test reads back is the strongest true one.
    static func verdict(for conditions: Conditions) -> Verdict {
        guard conditions.surfaceIsAlive else { return .silent(.tornDown) }
        guard conditions.gameIsRunning else { return .silent(.gameOver) }
        guard conditions.isFrontmost else { return .silent(.notFrontmost) }
        guard conditions.playerWantsSound else { return .silent(.muted) }
        guard conditions.systemPlaysInterfaceSounds else { return .silent(.systemSilenced) }
        let volume = min(max(conditions.alertVolume, 0), 1)
        guard volume > 0 else { return .silent(.volumeZero) }
        return .play(volume: volume)
    }
}

// MARK: - The machine

/// What actually makes a noise. A protocol so the tests can prove the refusals
/// by counting: a spy that is never asked to play is the assertion.
@MainActor
protocol PearlChimePlaying: AnyObject {
    func play(volume: Double)
}

/// `Tink`, at the alert volume. `NSSound` is loaded once and re-used; a chime
/// that arrives while the last one is still sounding restarts it rather than
/// layering, which cannot happen at a hundred points apart but would be the
/// difference between a tick and a smear if the milestone ever moved.
@MainActor
final class PearlSystemChime: PearlChimePlaying {

    /// Named here rather than inline at the call below so a test can ask the
    /// APP which sound it plays. A test that names "Tink" itself proves only
    /// that this Mac has a Tink, and goes on passing after the runner has been
    /// pointed at something else.
    static let soundName = NSSound.Name("Tink")

    /// Optional all the way down: a Mac with its sound set removed gets a
    /// silent game, not a crash.
    private let sound: NSSound? = NSSound(named: PearlSystemChime.soundName)

    func play(volume: Double) {
        guard let sound else { return }
        sound.stop()
        sound.volume = Float(volume)
        sound.play()
    }
}

/// Whether the player has silenced the game, across launches. Treated as
/// untrusted input the way `PearlHighScoreStore` is: anything that is not a
/// boolean reads as "not muted", because the failure that costs the user
/// something is a game that has gone quiet for a reason they cannot find.
nonisolated struct PearlChimeMuteStore {

    static let key = "pearlRunnerChimeMuted"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> Bool {
        defaults.object(forKey: Self.key) as? Bool ?? false
    }

    func save(_ muted: Bool) {
        defaults.set(muted, forKey: Self.key)
    }
}

/// The chime, wired to the machine. Owns the mute switch, reads the system's
/// two sound preferences, and asks `PearlChime.verdict` before every single
/// noise it makes.
@MainActor
final class PearlRunnerChime {

    /// System Settings' own default when the key has never been written:
    /// interface sounds are on out of the box.
    static let systemSoundsDefault = true
    /// And the alert slider's, which macOS leaves unwritten until it is moved.
    static let alertVolumeDefault = 0.5

    private let player: PearlChimePlaying
    private let store: PearlChimeMuteStore
    private let systemPlaysInterfaceSounds: () -> Bool
    private let alertVolume: () -> Double
    private let frontmost: () -> Bool

    /// The window the runner is in, when one is known. Weak: a game must never
    /// be the reason a window outlives its tab.
    private weak var window: NSWindow?

    private(set) var isMuted: Bool
    /// False once the surface has gone. Never goes back to true: a torn-down
    /// runner is not restarted, it is rebuilt.
    private var surfaceIsAlive = true
    /// The last verdict, for the tests and for nothing else.
    private(set) var lastVerdict: PearlChime.Verdict?

    init(
        player: PearlChimePlaying? = nil,
        store: PearlChimeMuteStore = PearlChimeMuteStore(),
        systemPlaysInterfaceSounds: (() -> Bool)? = nil,
        alertVolume: (() -> Double)? = nil,
        frontmost: (() -> Bool)? = nil
    ) {
        // Not default arguments: those are evaluated in the caller's context,
        // which need not be the main actor these require.
        self.player = player ?? PearlSystemChime()
        self.store = store
        self.systemPlaysInterfaceSounds = systemPlaysInterfaceSounds ?? {
            UserDefaults.standard.object(forKey: "com.apple.sound.uiaudio.enabled") as? Bool
                ?? PearlRunnerChime.systemSoundsDefault
        }
        self.alertVolume = alertVolume ?? {
            UserDefaults.standard.object(forKey: "com.apple.sound.beep.volume") as? Double
                ?? PearlRunnerChime.alertVolumeDefault
        }
        self.isMuted = store.load()
        self.frontmost = frontmost ?? { NSApp?.isActive ?? false }
        // Assigned after `frontmost` so the default closure can be replaced
        // without the window check disappearing with it.
        self.window = nil
    }

    /// The section learned which window it is in.
    func observe(window: NSWindow?) {
        self.window = window
    }

    /// M. Persisted, because a sound the user turned off must stay off through
    /// the next power cut as well as the next page.
    func toggleMute() {
        isMuted.toggle()
        store.save(isMuted)
    }

    /// The surface is going away. Everything after this is silent.
    func tearDown() {
        surfaceIsAlive = false
    }

    /// The run passed a hundred. Consults the rule and, only if it says so,
    /// makes the noise.
    @discardableResult
    func milestoneReached(gameIsRunning: Bool) -> PearlChime.Verdict {
        let verdict = PearlChime.verdict(for: PearlChime.Conditions(
            gameIsRunning: gameIsRunning,
            surfaceIsAlive: surfaceIsAlive,
            isFrontmost: isFrontmost,
            playerWantsSound: !isMuted,
            systemPlaysInterfaceSounds: systemPlaysInterfaceSounds(),
            alertVolume: alertVolume()
        ))
        lastVerdict = verdict
        if case .play(let volume) = verdict {
            player.play(volume: volume)
        }
        return verdict
    }

    /// Frontmost means both halves of it: Cherry is the active app AND the
    /// runner's own window is the one holding the keyboard. The window is
    /// only consulted once one is known — before that the app-level answer is
    /// the whole answer, and a game with no window has not started.
    private var isFrontmost: Bool {
        guard frontmost() else { return false }
        guard let window else { return true }
        return window.isKeyWindow
    }
}
