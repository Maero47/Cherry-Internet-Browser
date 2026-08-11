//
//  PearlRunnerController.swift
//  Cherry Browser
//
//  The seam between the pure simulation and the machine: a frame driver that
//  can be started, stopped, and — the part the tests hold onto — proven
//  stopped. The offline screen disappears the moment a retry succeeds, and a
//  60Hz timer surviving behind a page that came back is exactly the kind of
//  leak nobody notices until the fans do. So the driver is a protocol, the
//  production driver is a `Timer` whose whole lifecycle is inspectable, and
//  `PearlRunnerLifecycleTests` checks both that `shutDown()` kills it and
//  that a deallocated driver's timer stops firing.
//
//  Time reaches the simulation through an injected clock, so a test can march
//  the controller through exact ticks and the app can hand it wall time.
//

import Combine
import Foundation

// MARK: - The frame driver

@MainActor
protocol PearlFrameDriving: AnyObject {
    var isRunning: Bool { get }
    func start(_ tick: @escaping () -> Void)
    func stop()
}

/// The production driver: a repeating `Timer` on the main run loop in
/// `.common` mode, so the game does not freeze while a menu is open or the
/// window is being resized.
@MainActor
final class PearlFrameTimerDriver: PearlFrameDriving {

    private var timer: Timer?

    var isRunning: Bool {
        timer != nil
    }

    func start(_ tick: @escaping () -> Void) {
        stop()
        let timer = Timer(timeInterval: PearlWorld.frameDuration, repeats: true) { _ in
            // The timer is scheduled on the main run loop, so this closure
            // can only ever run on the main actor.
            MainActor.assumeIsolated(tick)
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        // A repeating timer retains its closure until invalidated; without
        // this, dropping the driver would leak the tick forever.
        timer?.invalidate()
    }
}

// MARK: - The controller

/// Owns one game, one driver, one high score. The view reads `game` and
/// writes `input`; everything else is lifecycle.
@MainActor
final class PearlRunnerController: ObservableObject {

    @Published private(set) var game: PearlRunnerGame
    @Published private(set) var highScore: Int
    /// Whether the player has asked for the game at all. The offline screen
    /// shows an offer until this flips; nothing simulates before it.
    @Published private(set) var hasStarted = false
    /// Distinguishes "paused because focus left" from "stopped because
    /// crashed" for the renderer's overlay text.
    @Published private(set) var isTicking = false

    /// What the player is holding. Written by the view's key handlers, read
    /// once per tick. Not published: keys must not trigger extra renders.
    var input = PearlInput()

    private let driver: PearlFrameDriving
    private let clock: () -> TimeInterval
    private let store: PearlHighScoreStore
    private var lastTickTime: TimeInterval?

    init(
        seed: UInt64 = UInt64(bitPattern: Int64(Date().timeIntervalSinceReferenceDate * 1000)),
        driver: PearlFrameDriving? = nil,
        clock: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate },
        store: PearlHighScoreStore = PearlHighScoreStore()
    ) {
        self.game = PearlRunnerGame(seed: seed)
        // Not a default argument: those are evaluated in the caller's
        // context, which need not be the main actor this driver requires.
        self.driver = driver ?? PearlFrameTimerDriver()
        self.clock = clock
        self.store = store
        self.highScore = store.load()
    }

    /// The player clicked or keyed the offer.
    func begin() {
        hasStarted = true
        resume()
    }

    /// Space on the crash screen.
    func restart() {
        guard game.phase == .crashed else { return }
        game.reset()
        resume()
    }

    /// Ticks stop but the picture stays: focus left the game.
    func pause() {
        driver.stop()
        isTicking = false
        lastTickTime = nil
    }

    func resume() {
        guard hasStarted, game.phase == .running, !driver.isRunning else { return }
        lastTickTime = nil
        isTicking = true
        driver.start { [weak self] in
            self?.tick()
        }
    }

    /// The surface is going away. After this returns the driver is not
    /// running — the guarantee `PearlRunnerLifecycleTests` pins.
    func shutDown() {
        pause()
    }

    private func tick() {
        let now = clock()
        let elapsed = lastTickTime.map { now - $0 } ?? PearlWorld.frameDuration
        lastTickTime = now

        game.advance(by: elapsed, input: input)

        if game.phase == .crashed {
            if game.score > highScore {
                highScore = game.score
                store.save(highScore)
            }
            // Nothing moves on the crash screen, so nothing should tick
            // behind it either.
            pause()
        }
    }
}
