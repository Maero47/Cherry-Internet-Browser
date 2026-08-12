//
//  PearlRunnerChimeTests.swift
//  Internet BrowserTests
//
//  The first sound Cherry has ever made, and every way it can be told not to.
//
//  There is no way to assert that a Mac was quiet, so the shape of this file
//  is the other one: the thing that would make the noise is a protocol, the
//  test hands it a spy, and "it refused" is `spy.plays == 0`. Every refusal in
//  `PearlChime.Reason` gets both halves — the pure rule, which is where the
//  decision lives, and the controller, which is what actually asks.
//

import AppKit
import XCTest
@testable import Cherry

// MARK: - Doubles

@MainActor
private final class ChimeSpy: PearlChimePlaying {
    private(set) var volumes: [Double] = []
    var plays: Int { volumes.count }

    func play(volume: Double) {
        volumes.append(volume)
    }
}

@MainActor
private final class HandCrankedDriver: PearlFrameDriving {
    private(set) var isRunning = false
    private(set) var tick: (() -> Void)?

    func start(_ tick: @escaping () -> Void) {
        self.tick = tick
        isRunning = true
    }

    func stop() {
        tick = nil
        isRunning = false
    }
}

@MainActor
private final class Clock {
    private(set) var now: TimeInterval = 1000
    func advance(_ interval: TimeInterval) { now += interval }
}

// MARK: - The rule

final class PearlChimeRuleTests: XCTestCase {

    /// Everything permitting: the chime plays, at the alert volume.
    private func audible(
        gameIsRunning: Bool = true,
        surfaceIsAlive: Bool = true,
        isFrontmost: Bool = true,
        playerWantsSound: Bool = true,
        systemPlaysInterfaceSounds: Bool = true,
        alertVolume: Double = 0.7
    ) -> PearlChime.Conditions {
        PearlChime.Conditions(
            gameIsRunning: gameIsRunning,
            surfaceIsAlive: surfaceIsAlive,
            isFrontmost: isFrontmost,
            playerWantsSound: playerWantsSound,
            systemPlaysInterfaceSounds: systemPlaysInterfaceSounds,
            alertVolume: alertVolume
        )
    }

    func testItPlaysAtTheAlertVolumeWhenNothingObjects() {
        XCTAssertEqual(PearlChime.verdict(for: audible()), .play(volume: 0.7))
    }

    /// One row per refusal, so removing any single guard fails exactly one
    /// assertion and names itself.
    ///
    /// Dies on any `guard` in `PearlChime.verdict` being deleted or inverted.
    func testEveryRefusalIsItsOwnReason() {
        let cases: [(String, PearlChime.Conditions, PearlChime.Reason)] = [
            ("the surface is gone", audible(surfaceIsAlive: false), .tornDown),
            ("the run has crashed", audible(gameIsRunning: false), .gameOver),
            ("Cherry is not frontmost", audible(isFrontmost: false), .notFrontmost),
            ("the player pressed M", audible(playerWantsSound: false), .muted),
            ("macOS interface sounds are off",
             audible(systemPlaysInterfaceSounds: false), .systemSilenced),
            ("the alert slider is at the bottom", audible(alertVolume: 0), .volumeZero),
        ]
        for (name, conditions, reason) in cases {
            XCTAssertEqual(PearlChime.verdict(for: conditions), .silent(reason),
                           "\(name) did not silence the chime")
        }
    }

    /// A torn-down surface is silent even if every other condition would ring,
    /// and a crashed game is silent even if the surface is alive — the order
    /// is part of the rule, so the reason a log or a test reads back is the
    /// strongest true one rather than whichever guard happened to be first.
    func testTheStrongestReasonWins() {
        XCTAssertEqual(
            PearlChime.verdict(for: audible(gameIsRunning: false, surfaceIsAlive: false)),
            .silent(.tornDown)
        )
        XCTAssertEqual(
            PearlChime.verdict(for: audible(gameIsRunning: false, isFrontmost: false)),
            .silent(.gameOver)
        )
    }

    /// A corrupt or out-of-range slider cannot make the game louder than the
    /// user asked. Dies on the clamp going.
    func testTheVolumeIsClampedToTheSlidersOwnRange() {
        XCTAssertEqual(PearlChime.verdict(for: audible(alertVolume: 12)), .play(volume: 1))
        XCTAssertEqual(PearlChime.verdict(for: audible(alertVolume: -3)), .silent(.volumeZero))
    }
}

// MARK: - The chime, and the controller that rings it

@MainActor
final class PearlRunnerChimeTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "PearlRunnerChimeTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeChime(
        spy: ChimeSpy,
        frontmost: Bool = true,
        systemSounds: Bool = true,
        alertVolume: Double = 0.6
    ) -> PearlRunnerChime {
        PearlRunnerChime(
            player: spy,
            store: PearlChimeMuteStore(defaults: defaults),
            systemPlaysInterfaceSounds: { systemSounds },
            alertVolume: { alertVolume },
            frontmost: { frontmost }
        )
    }

    /// A controller wound to just under a hundred points, with a driver the
    /// test cranks by hand.
    private func makeController(
        chime: PearlRunnerChime,
        driver: HandCrankedDriver,
        clock: Clock
    ) -> PearlRunnerController {
        PearlRunnerController(
            seed: 9,
            driver: driver,
            clock: { clock.now },
            store: PearlHighScoreStore(defaults: defaults),
            chime: chime
        )
    }

    // MARK: The wiring

    /// The chime is rung by crossing a hundred points, once. Dies on the
    /// controller ringing per tick, per frame, or not at all.
    func testCrossingAHundredRingsExactlyOnce() {
        let spy = ChimeSpy()
        let chime = makeChime(spy: spy)
        let driver = HandCrankedDriver()
        let clock = Clock()
        let controller = makeController(chime: chime, driver: driver, clock: clock)
        controller.begin()

        // Straight to the milestone, with the field emptied so nothing can
        // crash into Pearl on the way.
        controller.windForTesting {
            $0.nextObstacleDistance = .infinity
            $0.distance = 100 / PearlTuning.pointsPerDistance - 2
        }
        XCTAssertEqual(spy.plays, 0)

        crank(driver, clock, frames: 3)
        XCTAssertEqual(spy.plays, 1, "crossing 100 should ring once")
        XCTAssertEqual(spy.volumes, [0.6], "the chime should ring at the alert volume")

        crank(driver, clock, frames: 120)
        XCTAssertEqual(spy.plays, 1, "two more seconds is not another hundred")
    }

    /// Every hundred, not just the first. Dies on the count being latched
    /// rather than compared.
    func testItRingsAgainAtEveryFurtherHundred() {
        let spy = ChimeSpy()
        let controller = ring(spy: spy) { controller, driver, clock in
            for hundred in 1...4 {
                controller.windForTesting {
                    $0.distance = Double(hundred) * 100 / PearlTuning.pointsPerDistance - 2
                }
                crank(driver, clock, frames: 3)
            }
        }
        XCTAssertEqual(controller.game.phase, .running)
        XCTAssertEqual(spy.plays, 4)
    }

    // MARK: The refusals, through the controller

    /// The one the task named first: a run that crossed a hundred and hit a
    /// tree in the same batch of frames is over, and a game that is over does
    /// not ring.
    ///
    /// Dies on the controller asking `gameIsRunning` BEFORE the step instead
    /// of after it, which is the natural way to write it and the wrong one.
    func testAMilestoneReachedOnTheFrameThatCrashesDoesNotRing() {
        let spy = ChimeSpy()
        let chime = makeChime(spy: spy)
        let driver = HandCrankedDriver()
        let clock = Clock()
        let controller = makeController(chime: chime, driver: driver, clock: clock)
        controller.begin()

        // A tree already touching Pearl, so the same frame that crosses the
        // hundred is the frame that ends the run.
        controller.windForTesting {
            $0.nextObstacleDistance = .infinity
            $0.distance = 100 / PearlTuning.pointsPerDistance - 2
            $0.place(.largeTrees(1), at: PearlWorld.pearlX + 10)
        }

        crank(driver, clock, frames: 3)
        XCTAssertEqual(controller.game.phase, .crashed, "the fixture did not crash")
        XCTAssertGreaterThanOrEqual(controller.game.milestonesPassed, 1,
                                    "the fixture did not reach the hundred")
        XCTAssertEqual(spy.plays, 0, "a game that is over rang anyway")
        XCTAssertEqual(chime.lastVerdict, .silent(.gameOver))
    }

    /// Nothing after the surface has gone, ever. Dies on `shutDown()` not
    /// tearing the chime down.
    func testNothingRingsAfterTheSurfaceIsTornDown() {
        let spy = ChimeSpy()
        let chime = makeChime(spy: spy)
        chime.tearDown()
        XCTAssertEqual(chime.milestoneReached(gameIsRunning: true), .silent(.tornDown))
        XCTAssertEqual(spy.plays, 0)
    }

    func testShutDownIsWhatTearsItDown() {
        let spy = ChimeSpy()
        let chime = makeChime(spy: spy)
        let controller = makeController(chime: chime, driver: HandCrankedDriver(), clock: Clock())
        controller.begin()
        controller.shutDown()
        chime.milestoneReached(gameIsRunning: true)
        XCTAssertEqual(spy.plays, 0, "the runner made a noise after its surface went away")
    }

    /// Dies on the frontmost check being dropped from `PearlRunnerChime`.
    func testNothingRingsWhileCherryIsNotFrontmost() {
        let spy = ChimeSpy()
        let chime = makeChime(spy: spy, frontmost: false)
        XCTAssertEqual(chime.milestoneReached(gameIsRunning: true), .silent(.notFrontmost))
        XCTAssertEqual(spy.plays, 0)
    }

    /// And that "frontmost" means the runner's own window, not merely that
    /// some window of Cherry's is up. Dies on `observe(window:)` being
    /// ignored, or on the window check being dropped once a window is known.
    func testAnActiveAppIsNotEnoughIfTheRunnersWindowIsNotTheKeyOne() {
        let spy = ChimeSpy()
        let chime = makeChime(spy: spy, frontmost: true)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        XCTAssertFalse(window.isKeyWindow, "the fixture's window should not be key")
        chime.observe(window: window)
        XCTAssertEqual(chime.milestoneReached(gameIsRunning: true), .silent(.notFrontmost))
        XCTAssertEqual(spy.plays, 0)
    }

    /// The system's own switch, honoured. Dies on
    /// `com.apple.sound.uiaudio.enabled` no longer being consulted.
    func testNothingRingsWhenMacOSInterfaceSoundsAreOff() {
        let spy = ChimeSpy()
        let chime = makeChime(spy: spy, systemSounds: false)
        XCTAssertEqual(chime.milestoneReached(gameIsRunning: true), .silent(.systemSilenced))
        XCTAssertEqual(spy.plays, 0)
    }

    func testNothingRingsWhenTheAlertVolumeIsAtTheBottom() {
        let spy = ChimeSpy()
        let chime = makeChime(spy: spy, alertVolume: 0)
        XCTAssertEqual(chime.milestoneReached(gameIsRunning: true), .silent(.volumeZero))
        XCTAssertEqual(spy.plays, 0)
    }

    // MARK: Silenceable, and it stays silenced

    /// Dies on `toggleMute` not reaching the rule, and on the controller's M
    /// not reaching `toggleMute`.
    func testTheMuteKeySilencesItThroughTheController() {
        let spy = ChimeSpy()
        let chime = makeChime(spy: spy)
        let controller = makeController(chime: chime, driver: HandCrankedDriver(), clock: Clock())

        XCTAssertFalse(controller.chime.isMuted)
        controller.toggleMute()
        XCTAssertTrue(controller.chime.isMuted)
        XCTAssertEqual(chime.milestoneReached(gameIsRunning: true), .silent(.muted))
        XCTAssertEqual(spy.plays, 0)

        controller.toggleMute()
        XCTAssertEqual(chime.milestoneReached(gameIsRunning: true), .play(volume: 0.6))
        XCTAssertEqual(spy.plays, 1)
    }

    /// A sound the user turned off must stay off across launches. Dies on the
    /// mute not being written, or being written under a key the next launch
    /// does not read.
    func testMutingSurvivesARelaunch() {
        let first = makeChime(spy: ChimeSpy())
        first.toggleMute()
        XCTAssertTrue(PearlChimeMuteStore(defaults: defaults).load())

        let relaunched = makeChime(spy: ChimeSpy())
        XCTAssertTrue(relaunched.isMuted, "the game came back noisy")
    }

    /// The store treats what it reads as untrusted, the way the high score's
    /// does: a mangled plist must not be able to silence the game with no way
    /// for the user to find out why.
    func testAnUnreadableStoredValueMeansNotMuted() {
        defaults.set("yes please", forKey: PearlChimeMuteStore.key)
        XCTAssertFalse(PearlChimeMuteStore(defaults: defaults).load())
    }

    // MARK: What it actually plays

    /// The sound is a system one rather than a shipped asset, and this is what
    /// says it is still there to be found. Nothing is played: `NSSound(named:)`
    /// loads it, and a nil means the app is pointed at a sound macOS does not
    /// have. The name comes from the APP, not from this file — asking for
    /// "Tink" here would prove only that this Mac has a Tink.
    func testTheSoundItPlaysIsAMacOSSystemSound() {
        let name = PearlSystemChime.soundName
        XCTAssertNotNil(NSSound(named: PearlSystemChime.soundName),
                        "the runner is pointed at \(name), which is not a sound this Mac has")
    }

    /// The two fallbacks, so an unwritten preference is not read as silence.
    /// macOS leaves both keys absent until the user moves them.
    func testAnUnsetSystemPreferenceIsReadAsAudibleAtHalfVolume() {
        XCTAssertTrue(PearlRunnerChime.systemSoundsDefault)
        XCTAssertEqual(PearlRunnerChime.alertVolumeDefault, 0.5)
    }

    // MARK: Cranking

    private func crank(_ driver: HandCrankedDriver, _ clock: Clock, frames: Int) {
        for _ in 0..<frames {
            clock.advance(PearlWorld.frameDuration)
            driver.tick?()
        }
    }

    @discardableResult
    private func ring(
        spy: ChimeSpy,
        _ body: (PearlRunnerController, HandCrankedDriver, Clock) -> Void
    ) -> PearlRunnerController {
        let driver = HandCrankedDriver()
        let clock = Clock()
        let controller = makeController(chime: makeChime(spy: spy), driver: driver, clock: clock)
        controller.begin()
        controller.windForTesting { $0.nextObstacleDistance = .infinity }
        body(controller, driver, clock)
        return controller
    }
}
