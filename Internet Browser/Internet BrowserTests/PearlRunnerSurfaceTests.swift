//
//  PearlRunnerSurfaceTests.swift
//  Internet BrowserTests
//
//  Everything around the simulation: where the game is offered (the offline
//  family and nowhere else), that its frame driver provably dies with the
//  surface, and that the persisted high score can survive a relaunch but
//  never corrupt its way into a crash.
//

import SwiftUI
import XCTest
@testable import Cherry

// MARK: - Where the game appears

@MainActor
final class PearlRunnerOfferTests: XCTestCase {

    private let allFamilies: [NavigationFailure.Family] = [
        .offline, .hostNotFound, .connectionRefused, .connectionLost, .timedOut,
        .tooManyRedirects, .cancelled, .unsupportedScheme, .blockedPort,
        .secureConnectionFailed, .unrecognised,
    ]

    private func failure(_ family: NavigationFailure.Family) -> NavigationFailure {
        NavigationFailure(
            family: family,
            url: URL(string: "https://example.invalid/"),
            systemDescription: "system sentence",
            domain: NSURLErrorDomain,
            code: -1
        )
    }

    /// The rule itself: `.offline` is a wait, every other family is an
    /// instruction, and only the wait gets a game.
    func testOnlyTheOfflineFamilyOffersTheGame() {
        for family in allFamilies {
            XCTAssertEqual(
                failure(family).offersPearlRunner,
                family == .offline,
                "\(family) got the wrong answer about the game"
            )
        }
    }

    // The view, not just the rule. `NavigationFailureView.body` is a value
    // tree; walking it with Mirror finds the actual `PearlRunnerSection`
    // value when the branch is live and nothing when it is not. This is what
    // dies if the `if failure.offersPearlRunner` in the view is deleted,
    // inverted, or hardcoded — the model test above cannot see that.

    private func bodyContainsGameSection(for family: NavigationFailure.Family) -> Bool {
        let view = NavigationFailureView(
            failure: failure(family),
            isRetrying: false,
            canGoBack: false,
            onRetry: {},
            onBack: {}
        )
        return containsPearlRunnerSection(in: view.body)
    }

    private func containsPearlRunnerSection(in value: Any, depth: Int = 0) -> Bool {
        if value is PearlRunnerSection { return true }
        guard depth < 60 else { return false }
        return Mirror(reflecting: value).children.contains {
            containsPearlRunnerSection(in: $0.value, depth: depth + 1)
        }
    }

    func testTheOfflineScreenActuallyContainsTheGameSection() {
        XCTAssertTrue(bodyContainsGameSection(for: .offline))
    }

    func testEveryOtherScreenDoesNot() {
        for family in allFamilies where family != .offline {
            XCTAssertFalse(
                bodyContainsGameSection(for: family),
                "\(family) is an instruction screen; it must not carry a game"
            )
        }
    }

    // MARK: Placement — above the failure text, not below it

    // Presence is not placement. `FailureColumn`'s content is a tuple in
    // source order, and `Mirror` walks a tuple in that order, so "the runner
    // is reached before the title" is exactly "the runner is drawn above the
    // title". This is what dies if the section is moved back under the
    // actions, or under the address, or anywhere below the copy.

    private enum ColumnLandmark: Equatable {
        case runner
        case title
    }

    private func landmarks(in value: Any, title: String, depth: Int = 0) -> [ColumnLandmark] {
        if value is PearlRunnerSection { return [.runner] }
        if let text = value as? Text {
            return String(describing: text).contains(title) ? [.title] : []
        }
        guard depth < 60 else { return [] }
        return Mirror(reflecting: value).children.flatMap {
            landmarks(in: $0.value, title: title, depth: depth + 1)
        }
    }

    func testTheGameSitsAboveTheFailureCopy() {
        let offline = failure(.offline)
        let view = NavigationFailureView(
            failure: offline,
            isRetrying: false,
            canGoBack: false,
            onRetry: {},
            onBack: {}
        )

        let order = landmarks(in: view.body, title: offline.title)

        XCTAssertEqual(
            order.first, .runner,
            "the runner must be reached before the title: Chrome puts the dino above the copy"
        )
        XCTAssertTrue(
            order.contains(.title),
            "the title must still be in the column — a placement test that cannot see it proves nothing"
        )
    }
}

// MARK: - Lifecycle: nothing runs behind a page that came back

@MainActor
private final class SpyDriver: PearlFrameDriving {
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

/// A hand-cranked clock, so controller tests march through exact ticks.
@MainActor
private final class TestClock {
    private(set) var now: TimeInterval = 1000
    func tick(_ interval: TimeInterval = PearlWorld.frameDuration) {
        now += interval
    }
}

@MainActor
final class PearlRunnerLifecycleTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "PearlRunnerLifecycleTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeController(driver: PearlFrameDriving, clock: TestClock, seed: UInt64 = 42) -> PearlRunnerController {
        PearlRunnerController(
            seed: seed,
            driver: driver,
            clock: { clock.now },
            store: PearlHighScoreStore(defaults: defaults)
        )
    }

    func testNothingTicksUntilThePlayerAsks() {
        let driver = SpyDriver()
        let controller = makeController(driver: driver, clock: TestClock())
        XCTAssertFalse(driver.isRunning, "the offer alone must not start a driver")
        XCTAssertEqual(controller.game.frame, 0)
    }

    func testShutDownStopsTheDriver() {
        let driver = SpyDriver()
        let controller = makeController(driver: driver, clock: TestClock())
        controller.begin()
        XCTAssertTrue(driver.isRunning)

        controller.shutDown()

        XCTAssertFalse(driver.isRunning, "onDisappear must leave no driver running")
        XCTAssertNil(driver.tick, "and no tick closure retained")
    }

    func testPauseAndResumeAroundFocusLoss() {
        let driver = SpyDriver()
        let controller = makeController(driver: driver, clock: TestClock())
        controller.begin()
        controller.pause()
        XCTAssertFalse(driver.isRunning)
        controller.resume()
        XCTAssertTrue(driver.isRunning)
    }

    /// The injected clock reaching the simulation: sixty hand-cranked ticks
    /// of 1/60s are exactly sixty frames.
    func testTicksAdvanceTheGameByTheClockNotByCallCount() {
        let driver = SpyDriver()
        let clock = TestClock()
        let controller = makeController(driver: driver, clock: clock)
        controller.begin()

        for _ in 0..<60 {
            clock.tick()
            driver.tick?()
        }
        // ±1 for floating-point remainder carried between ticks.
        XCTAssertTrue((59...61).contains(controller.game.frame),
                      "sixty ticks of 1/60s should be about sixty frames, got \(controller.game.frame)")

        // Ticks that arrive with no time elapsed must not advance the game:
        // the clock is the authority, not the call count.
        let settled = controller.game.frame
        driver.tick?()
        driver.tick?()
        XCTAssertEqual(controller.game.frame, settled)
    }

    /// Left alone, Pearl runs into the first tree. The crash must stop the
    /// driver by itself and bank the high score.
    func testACrashStopsTheDriverAndBanksTheHighScore() {
        let driver = SpyDriver()
        let clock = TestClock()
        let controller = makeController(driver: driver, clock: clock)
        controller.begin()

        var safety = 0
        while driver.isRunning && safety < 5000 {
            clock.tick()
            driver.tick?()
            safety += 1
        }

        XCTAssertEqual(controller.game.phase, .crashed, "an unsteered run ends in the first tree")
        XCTAssertFalse(driver.isRunning, "nothing may tick behind the crash screen")
        XCTAssertGreaterThan(controller.highScore, 0)
        XCTAssertEqual(PearlHighScoreStore(defaults: defaults).load(), controller.highScore,
                       "the high score must actually reach the store")
    }

    func testRestartAfterACrashRunsAgain() {
        let driver = SpyDriver()
        let clock = TestClock()
        let controller = makeController(driver: driver, clock: clock)
        controller.begin()
        var safety = 0
        while driver.isRunning && safety < 5000 {
            clock.tick()
            driver.tick?()
            safety += 1
        }
        XCTAssertEqual(controller.game.phase, .crashed)

        controller.restart()

        XCTAssertEqual(controller.game.phase, .running)
        XCTAssertEqual(controller.game.score, 0)
        XCTAssertTrue(driver.isRunning)
    }

    // MARK: The real timer

    /// The production driver's whole contract: started means firing, stopped
    /// means silent, deallocated means silent. This is the "no timer survives
    /// teardown" test, run against the real `Timer`.
    func testTheRealTimerDriverStopsFiringWhenStoppedAndWhenDeallocated() {
        var ticks = 0
        let driver = PearlFrameTimerDriver()
        driver.start { ticks += 1 }
        XCTAssertTrue(driver.isRunning)

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        XCTAssertGreaterThan(ticks, 0, "a started driver must fire")

        driver.stop()
        XCTAssertFalse(driver.isRunning)
        let afterStop = ticks
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
        XCTAssertEqual(ticks, afterStop, "a stopped driver must never fire again")

        var dropped: PearlFrameTimerDriver? = PearlFrameTimerDriver()
        dropped?.start { ticks += 1 }
        let beforeDrop = ticks
        dropped = nil
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
        XCTAssertEqual(ticks, beforeDrop,
                       "a deallocated driver's timer must die with it — this is the leak the protocol exists to prevent")
    }

    func testShutDownWithTheRealDriverLeavesItStopped() {
        let clock = TestClock()
        let driver = PearlFrameTimerDriver()
        let controller = makeController(driver: driver, clock: clock)
        controller.begin()
        XCTAssertTrue(driver.isRunning)
        controller.shutDown()
        XCTAssertFalse(driver.isRunning)
    }
}

// MARK: - Space starts the run, and only where it is allowed to

/// The Chrome-dino path, tested where it can actually be tested. The host
/// cannot activate the app or post a trusted key event, so the rule for who
/// owns the space bar lives in `PearlSpaceKey` and is driven here through the
/// controller — the same call the key handler makes, with the same arguments.
@MainActor
final class PearlSpaceToStartTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    private let allFamilies: [NavigationFailure.Family] = [
        .offline, .hostNotFound, .connectionRefused, .connectionLost, .timedOut,
        .tooManyRedirects, .cancelled, .unsupportedScheme, .blockedPort,
        .secureConnectionFailed, .unrecognised,
    ]

    override func setUp() {
        super.setUp()
        suiteName = "PearlSpaceToStartTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeController(driver: PearlFrameDriving, clock: TestClock) -> PearlRunnerController {
        PearlRunnerController(
            seed: 42,
            driver: driver,
            clock: { clock.now },
            store: PearlHighScoreStore(defaults: defaults)
        )
    }

    private func offersRunner(_ family: NavigationFailure.Family) -> Bool {
        NavigationFailure(
            family: family,
            url: URL(string: "https://example.invalid/"),
            systemDescription: "system sentence",
            domain: NSURLErrorDomain,
            code: -1
        ).offersPearlRunner
    }

    /// One space bar and Pearl is running. No button was pressed first, and
    /// the press that started the run is not also her first jump.
    func testSpaceStartsARunOnTheOfflineSurface() {
        let driver = SpyDriver()
        let controller = makeController(driver: driver, clock: TestClock())
        XCTAssertFalse(controller.hasStarted)
        XCTAssertFalse(driver.isRunning)

        let meaning = controller.spacePressed(
            offersRunner: offersRunner(.offline),
            runnerHasKeyboardFocus: true
        )

        XCTAssertEqual(meaning, .start)
        XCTAssertTrue(controller.hasStarted, "space must be enough to ask for a run")
        XCTAssertTrue(driver.isRunning, "and the run must actually be ticking")
        XCTAssertFalse(controller.input.jump, "the starting press is not a held jump")
    }

    /// Every other family is an instruction screen. Space there belongs to the
    /// scroll view and comes back untouched.
    func testSpaceStartsNothingOnAnyOtherFailureFamily() {
        for family in allFamilies where family != .offline {
            let driver = SpyDriver()
            let controller = makeController(driver: driver, clock: TestClock())

            let meaning = controller.spacePressed(
                offersRunner: offersRunner(family),
                runnerHasKeyboardFocus: true
            )

            XCTAssertEqual(meaning, .notOurs, "\(family) claimed the space bar")
            XCTAssertFalse(controller.hasStarted, "\(family) started a game")
            XCTAssertFalse(driver.isRunning, "\(family) started ticking")
        }
    }

    /// The other half of the rule: a runner that does not hold the keyboard
    /// cannot take a keystroke that belongs to the omnibox, a sheet, the find
    /// bar or the page.
    func testSpaceIsNotOursWhenSomethingElseHoldsTheKeyboard() {
        let driver = SpyDriver()
        let controller = makeController(driver: driver, clock: TestClock())

        let meaning = controller.spacePressed(
            offersRunner: offersRunner(.offline),
            runnerHasKeyboardFocus: false
        )

        XCTAssertEqual(meaning, .notOurs)
        XCTAssertFalse(controller.hasStarted, "an unfocused runner must not start on someone else's key")
        XCTAssertFalse(driver.isRunning)
    }

    /// Once the run is going, space is the jump. It must not restart, reset or
    /// re-begin anything: the run in flight survives it, and Pearl leaves the
    /// ground.
    func testARunningGameTreatsSpaceAsJumpNotRestart() {
        let driver = SpyDriver()
        let clock = TestClock()
        let controller = makeController(driver: driver, clock: clock)
        controller.spacePressed(offersRunner: true, runnerHasKeyboardFocus: true)

        for _ in 0..<60 {
            clock.tick()
            driver.tick?()
        }
        let frameBefore = controller.game.frame
        let scoreBefore = controller.game.score
        XCTAssertGreaterThan(frameBefore, 0)
        XCTAssertGreaterThan(scoreBefore, 0)
        XCTAssertEqual(controller.game.phase, .running)

        let meaning = controller.spacePressed(offersRunner: true, runnerHasKeyboardFocus: true)

        XCTAssertEqual(meaning, .jump)
        XCTAssertTrue(controller.input.jump, "the press must reach the simulation as a jump")
        XCTAssertEqual(controller.game.frame, frameBefore, "a running game must not be restarted by space")
        XCTAssertEqual(controller.game.score, scoreBefore, "and must not lose the score it had")

        for _ in 0..<10 {
            clock.tick()
            driver.tick?()
        }
        XCTAssertTrue(controller.game.isAirborne, "space on a running game jumps")

        controller.spaceReleased()
        XCTAssertFalse(controller.input.jump, "releasing must let a tap jump be a tap")
    }

    /// The crash screen keeps its own meaning, and the press that clears it
    /// does not carry into the new run as a held jump.
    func testSpaceOnTheCrashScreenRunsAgain() {
        let driver = SpyDriver()
        let clock = TestClock()
        let controller = makeController(driver: driver, clock: clock)
        controller.spacePressed(offersRunner: true, runnerHasKeyboardFocus: true)

        var safety = 0
        while driver.isRunning && safety < 5000 {
            clock.tick()
            driver.tick?()
            safety += 1
        }
        XCTAssertEqual(controller.game.phase, .crashed)

        let meaning = controller.spacePressed(offersRunner: true, runnerHasKeyboardFocus: true)

        XCTAssertEqual(meaning, .restart)
        XCTAssertEqual(controller.game.phase, .running)
        XCTAssertEqual(controller.game.score, 0)
        XCTAssertTrue(driver.isRunning)
        XCTAssertFalse(controller.input.jump)
    }

    /// The rule itself, read straight: every combination that is not "offline,
    /// focused" is somebody else's key.
    func testTheRuleRefusesEverythingButTheFocusedOfflineSurface() {
        XCTAssertEqual(
            PearlSpaceKey.meaning(offersRunner: false, runnerHasKeyboardFocus: true,
                                  hasStarted: false, phase: .running),
            .notOurs
        )
        XCTAssertEqual(
            PearlSpaceKey.meaning(offersRunner: true, runnerHasKeyboardFocus: false,
                                  hasStarted: false, phase: .running),
            .notOurs
        )
        XCTAssertEqual(
            PearlSpaceKey.meaning(offersRunner: true, runnerHasKeyboardFocus: true,
                                  hasStarted: false, phase: .running),
            .start
        )
        XCTAssertEqual(
            PearlSpaceKey.meaning(offersRunner: true, runnerHasKeyboardFocus: true,
                                  hasStarted: true, phase: .running),
            .jump
        )
        XCTAssertEqual(
            PearlSpaceKey.meaning(offersRunner: true, runnerHasKeyboardFocus: true,
                                  hasStarted: true, phase: .crashed),
            .restart
        )
    }
}

// MARK: - The persisted high score

@MainActor
final class PearlHighScoreStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "PearlHighScoreStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testAScoreRoundTripsThroughTheStore() {
        let store = PearlHighScoreStore(defaults: defaults)
        store.save(432)
        XCTAssertEqual(PearlHighScoreStore(defaults: defaults).load(), 432)
    }

    func testAnEmptyStoreReadsAsZero() {
        XCTAssertEqual(PearlHighScoreStore(defaults: defaults).load(), 0)
    }

    /// The corruption suite: none of these may crash, and none may produce
    /// a believable score out of garbage.
    func testCorruptedValuesReadAsZeroInsteadOfCrashing() {
        let store = PearlHighScoreStore(defaults: defaults)

        defaults.set("nine thousand", forKey: PearlHighScoreStore.key)
        XCTAssertEqual(store.load(), 0, "a string is not a score")

        defaults.set(-500, forKey: PearlHighScoreStore.key)
        XCTAssertEqual(store.load(), 0, "a negative is not a score")

        defaults.set(1e300, forKey: PearlHighScoreStore.key)
        XCTAssertEqual(store.load(), 0, "an unrepresentable double is not a score")

        defaults.set(["score": 12], forKey: PearlHighScoreStore.key)
        XCTAssertEqual(store.load(), 0, "a dictionary is not a score")

        defaults.set(true, forKey: PearlHighScoreStore.key)
        XCTAssertEqual(store.load(), 1,
                       "a boolean bridges to 1; harmless, but pinned so a change is noticed")
    }

    func testAbsurdValuesAreClampedNotBelieved() {
        let store = PearlHighScoreStore(defaults: defaults)
        defaults.set(999_999_999, forKey: PearlHighScoreStore.key)
        XCTAssertEqual(store.load(), PearlHighScoreStore.ceiling)

        store.save(2_000_000)
        XCTAssertEqual(store.load(), PearlHighScoreStore.ceiling)

        store.save(-12)
        XCTAssertEqual(store.load(), 0)
    }

    /// A double that happens to be a whole number bridges to Int; that is a
    /// valid score arriving in the wrong coat, and it should be accepted.
    func testAWholeDoubleIsAcceptedAsItself() {
        defaults.set(12.0, forKey: PearlHighScoreStore.key)
        XCTAssertEqual(PearlHighScoreStore(defaults: defaults).load(), 12)
    }
}
