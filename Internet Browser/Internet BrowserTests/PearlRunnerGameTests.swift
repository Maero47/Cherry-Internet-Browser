//
//  PearlRunnerGameTests.swift
//  Internet BrowserTests
//
//  The game's rules, proven the only way this codebase allows: by stepping
//  the simulation frame by frame and reading the state. No screen, no
//  screenshots — a seeded `PearlRunnerGame` plus an input script IS the run,
//  so every claim below ("a tap clears a small tree and can never clear a
//  large one") is checked against the same arithmetic the player feels.
//

import XCTest
@testable import Cherry

@MainActor
final class PearlRunnerGameTests: XCTestCase {

    // MARK: - Harness

    /// A game with the spawn schedules pushed out of reach, so a test owns
    /// the obstacle field completely.
    private func quietGame(seed: UInt64 = 7) -> PearlRunnerGame {
        var game = PearlRunnerGame(seed: seed)
        game.nextObstacleDistance = .infinity
        game.nextCloudDistance = .infinity
        return game
    }

    private func step(_ game: inout PearlRunnerGame, frames: Int, input: PearlInput = PearlInput()) {
        for _ in 0..<frames {
            game.step(input: input)
        }
    }

    /// Places one obstacle, coasts until its leading edge is `pressDistance`
    /// ahead of Pearl's nose, holds jump for `holdFrames`, and plays the
    /// encounter out. True when Pearl is still running afterwards.
    private func survivesJump(
        over kind: PearlObstacleKind,
        holdFrames: Int,
        pressDistance: Double
    ) -> Bool {
        var game = quietGame()
        game.place(kind, at: 400)

        let nose = PearlWorld.pearlX + PearlSpriteContract.run.width
        while let first = game.obstacles.first, first.x - nose > pressDistance {
            game.step(input: PearlInput())
            if game.phase == .crashed { return false }
        }

        var framesHeld = 0
        while game.phase == .running && !game.obstacles.isEmpty && game.frame < 2000 {
            game.step(input: PearlInput(jump: framesHeld < holdFrames))
            framesHeld += 1
        }
        return game.phase == .running && game.obstacles.isEmpty
    }

    /// Plays one obstacle with a constant input held throughout.
    private func survives(_ kind: PearlObstacleKind, holding input: PearlInput) -> Bool {
        var game = quietGame()
        game.place(kind, at: 400)
        while game.phase == .running && !game.obstacles.isEmpty && game.frame < 2000 {
            game.step(input: input)
        }
        return game.phase == .running && game.obstacles.isEmpty
    }

    // MARK: - Determinism
    //
    // Dies when any rule consults randomness outside the seeded generator
    // (a stray `Int.random`, a reseed, iteration over an unordered
    // collection): the two runs stop matching.

    func testTheSameSeedAndScriptProduceTheSameRunExactly() {
        var first = PearlRunnerGame(seed: 99)
        var second = PearlRunnerGame(seed: 99)

        // A busy script: periodic jumps, periodic ducks, sometimes both.
        func input(at frame: Int) -> PearlInput {
            PearlInput(
                jump: frame % 120 < 10,
                duck: frame % 300 >= 200 && frame % 300 < 240
            )
        }

        for frame in 0..<2500 {
            first.step(input: input(at: frame))
            second.step(input: input(at: frame))
            if frame % 100 == 0 {
                XCTAssertEqual(first, second, "the runs diverged by frame \(frame)")
            }
        }
        XCTAssertEqual(first, second)
    }

    func testDifferentSeedsProduceDifferentRuns() {
        var first = PearlRunnerGame(seed: 1)
        var second = PearlRunnerGame(seed: 2)
        step(&first, frames: 600)
        step(&second, frames: 600)
        XCTAssertNotEqual(first, second, "two seeds should lay out the world differently")
    }

    // MARK: - The jump arc
    //
    // The tuned claim (see `PearlTuning`): a TAP tops out around 41pt, which
    // clears a 35pt small tree and can never clear a 50pt large one; a HOLD
    // tops out around 74pt and clears the large tree with room. Dies when
    // `tapJumpVelocityCap` (or the release clamp itself), `jumpVelocity` or
    // `gravity` moves.

    func testATapJumpClearsASmallTree() {
        XCTAssertTrue(survivesJump(over: .smallTrees(1), holdFrames: 1, pressDistance: 38))
    }

    func testATapJumpNeverClearsALargeTreeAtAnyTiming() {
        for pressDistance in stride(from: 10.0, through: 110.0, by: 4.0) {
            XCTAssertFalse(
                survivesJump(over: .largeTrees(1), holdFrames: 1, pressDistance: pressDistance),
                "a tap should not clear a large tree, but did when pressed \(pressDistance)pt out"
            )
        }
    }

    func testAHeldJumpClearsALargeTreeAtTheSameSpeedAndTiming() {
        XCTAssertTrue(survivesJump(over: .largeTrees(1), holdFrames: 40, pressDistance: 38))
    }

    func testHoldingRisesHigherThanTapping() {
        func apex(holdFrames: Int) -> Double {
            var game = quietGame()
            var top = PearlWorld.feetLine
            for frame in 0..<120 {
                game.step(input: PearlInput(jump: frame < holdFrames))
                top = min(top, game.feetY)
            }
            return PearlWorld.feetLine - top
        }
        let tap = apex(holdFrames: 1)
        let hold = apex(holdFrames: 40)
        XCTAssertGreaterThan(tap, PearlSpriteContract.treeSmall.height,
                             "even a tap must out-jump a small tree")
        XCTAssertGreaterThan(hold, tap + 20, "holding should buy a visibly higher arc")
    }

    func testDuckInMidAirFallsFasterThanFloating() {
        func airtime(duckOnDescent: Bool) -> Int {
            var game = quietGame()
            var frames = 0
            for frame in 0..<200 {
                let rising = game.verticalVelocity < 0
                game.step(input: PearlInput(
                    jump: frame < 8,
                    duck: duckOnDescent && !rising && game.isAirborne
                ))
                if game.isAirborne { frames += 1 }
                if frame > 8 && !game.isAirborne { break }
            }
            return frames
        }
        XCTAssertLessThan(airtime(duckOnDescent: true), airtime(duckOnDescent: false),
                          "holding ↓ in the air is the fast way down")
    }

    // MARK: - Gulls and ducking
    //
    // The lane geometry from `PearlGullLane`: high sails over everything,
    // middle punishes standing but not ducking, low punishes ducking and
    // demands a jump. Dies when the lane heights, the duck silhouette, or
    // the fairness insets move.

    func testDuckingPassesUnderAMiddleGull() {
        XCTAssertTrue(survives(.gull(.middle), holding: PearlInput(duck: true)))
    }

    func testStandingUnderAMiddleGullCrashes() {
        XCTAssertFalse(survives(.gull(.middle), holding: PearlInput()))
    }

    func testDuckingUnderALowGullCrashes() {
        XCTAssertFalse(survives(.gull(.low), holding: PearlInput(duck: true)))
    }

    func testALowGullCanBeJumped() {
        XCTAssertTrue(survivesJump(over: .gull(.low), holdFrames: 40, pressDistance: 38))
    }

    func testAHighGullPassesOverARunningPearl() {
        XCTAssertTrue(survives(.gull(.high), holding: PearlInput()))
    }

    func testDuckingOnlyHappensOnTheGround() {
        var game = quietGame()
        game.step(input: PearlInput(jump: true))
        XCTAssertTrue(game.isAirborne)
        game.step(input: PearlInput(jump: true, duck: true))
        XCTAssertFalse(game.isDucking, "mid-air ↓ is a fast fall, not a duck")
        XCTAssertEqual(game.pearlBounds.height, PearlSpriteContract.run.height,
                       "the airborne silhouette is the standing one")
    }

    // MARK: - The speed ramp
    //
    // Dies when `acceleration`, `initialSpeed` or `maxSpeed` moves, or the
    // clamp inverts.

    // Literal numbers on purpose: a test that compares against
    // `PearlTuning.acceleration` moves when the constant moves and catches
    // nothing. These are the tuned values themselves.
    func testSpeedRampsLinearlyFromSix() {
        var game = quietGame()
        XCTAssertEqual(game.speed, 6.0)
        step(&game, frames: 80)
        XCTAssertEqual(game.speed, 6.08, accuracy: 1e-9)
    }

    func testSpeedTopsOutAtThirteenAndStaysThere() {
        var game = quietGame()
        step(&game, frames: 6900)
        XCTAssertLessThan(game.speed, 13.0, "the ceiling must not arrive early")
        step(&game, frames: 200)
        XCTAssertEqual(game.speed, 13.0)
        step(&game, frames: 900)
        XCTAssertEqual(game.speed, 13.0)
    }

    // MARK: - Score, day and night
    //
    // Dies when `pointsPerDistance` or the 700-point flip arithmetic moves.

    func testScoreIsDistanceTimesTheChromeCoefficient() {
        var game = quietGame()
        game.distance = 4000
        XCTAssertEqual(game.score, 100)
    }

    func testNightFallsAtSevenHundredAndDayReturnsAtFourteenHundred() {
        var game = quietGame()
        let distancePerPoint = 1 / PearlTuning.pointsPerDistance

        game.distance = 0
        XCTAssertFalse(game.isNight)
        game.distance = 699 * distancePerPoint
        XCTAssertFalse(game.isNight)
        game.distance = 700 * distancePerPoint
        XCTAssertTrue(game.isNight)
        game.distance = 1399 * distancePerPoint
        XCTAssertTrue(game.isNight)
        game.distance = 1400 * distancePerPoint
        XCTAssertFalse(game.isNight)
    }

    func testSteppingAcrossTheMilestoneFlipsTheSky() {
        var game = quietGame()
        game.distance = 700 / PearlTuning.pointsPerDistance - 3
        XCTAssertFalse(game.isNight)
        game.step(input: PearlInput())
        XCTAssertTrue(game.isNight, "one more frame of distance should cross 700 points")
    }

    // MARK: - The spawn schedule
    //
    // Dies when the gull speed gate, the same-kind guard, or the offscreen
    // sweep goes.

    /// Steps a game while harvesting freshly spawned kinds and clearing the
    /// field so nothing ever collides, with speed pinned so the ramp cannot
    /// cross a threshold mid-test.
    private func harvestSpawns(seed: UInt64, speed: Double, count: Int) -> [PearlObstacleKind] {
        var game = PearlRunnerGame(seed: seed)
        game.nextCloudDistance = .infinity
        var kinds: [PearlObstacleKind] = []
        while kinds.count < count && game.frame < 100_000 {
            game.speed = speed
            game.step(input: PearlInput())
            kinds.append(contentsOf: game.obstacles.map(\.kind))
            game.obstacles.removeAll()
        }
        return kinds
    }

    func testNoGullsBelowTheSpeedGate() {
        // 8.4 is a literal on purpose: just under the tuned 8.5 gate, so a
        // lowered gate spawns gulls here and fails.
        let kinds = harvestSpawns(seed: 5, speed: 8.4, count: 60)
        XCTAssertEqual(kinds.count, 60)
        for kind in kinds {
            if case .gull = kind {
                XCTFail("a gull spawned below speed 8.5")
            }
        }
    }

    func testGullsJoinOnceFastEnough() {
        let kinds = harvestSpawns(seed: 5, speed: PearlTuning.maxSpeed, count: 100)
        XCTAssertTrue(
            kinds.contains { if case .gull = $0 { return true } else { return false } },
            "at top speed a hundred spawns should include gulls"
        )
    }

    func testNeverThreeOfTheSameKindInARow() {
        let kinds = harvestSpawns(seed: 11, speed: PearlTuning.maxSpeed, count: 200)
        func tag(_ kind: PearlObstacleKind) -> Int {
            switch kind {
            case .smallTrees: return 0
            case .largeTrees: return 1
            case .gull: return 2
            }
        }
        var run = 0
        var last = -1
        for kind in kinds {
            run = tag(kind) == last ? run + 1 : 1
            last = tag(kind)
            XCTAssertLessThanOrEqual(run, PearlTuning.maxSameKindRun)
        }
    }

    func testTreeGroupSizesStayInsideTheContract() {
        let kinds = harvestSpawns(seed: 23, speed: PearlTuning.maxSpeed, count: 200)
        for kind in kinds {
            switch kind {
            case .smallTrees(let count):
                XCTAssertTrue((1...3).contains(count), "small trees come 1-3, got \(count)")
            case .largeTrees(let count):
                XCTAssertTrue((1...2).contains(count), "large trees come 1-2, got \(count)")
            case .gull:
                break
            }
        }
    }

    func testPassedObstaclesAreSweptOffTheField() {
        var game = quietGame()
        game.place(.smallTrees(1), at: 5)
        step(&game, frames: 30)
        XCTAssertEqual(game.phase, .running, "a tree behind Pearl cannot hit her")
        XCTAssertTrue(game.obstacles.isEmpty, "offscreen obstacles must be removed")
    }

    // MARK: - Crash and restart

    func testCrashingFreezesTheWorldAndResetStartsOver() {
        var game = quietGame()
        // Directly in Pearl's path, at ground level.
        game.place(.smallTrees(1), at: PearlWorld.pearlX + 10)
        game.step(input: PearlInput())
        XCTAssertEqual(game.phase, .crashed)

        let frozen = game
        step(&game, frames: 10, input: PearlInput(jump: true))
        XCTAssertEqual(game, frozen, "nothing may move after a crash")

        game.reset()
        XCTAssertEqual(game.phase, .running)
        XCTAssertEqual(game.score, 0)
        XCTAssertEqual(game.speed, PearlTuning.initialSpeed)
        XCTAssertTrue(game.obstacles.isEmpty)
    }

    func testTheRestartKeyStillHeldDoesNotLaunchPearl() {
        var game = quietGame()
        game.place(.smallTrees(1), at: PearlWorld.pearlX + 10)
        game.step(input: PearlInput(jump: true))
        XCTAssertEqual(game.phase, .crashed)

        game.reset()
        game.step(input: PearlInput(jump: true))
        XCTAssertFalse(game.isAirborne,
                       "a held space bar is not a fresh press; jumping needs an edge")
        game.step(input: PearlInput())
        game.step(input: PearlInput(jump: true))
        XCTAssertTrue(game.isAirborne, "release and press again is a fresh jump")
    }

    // MARK: - The injected clock
    //
    // Dies when the fixed-timestep accumulator goes (one step per call
    // regardless of elapsed time) or the stall cap goes (a minute of
    // background time replayed as a lethal fast-forward).

    func testAdvanceConvertsElapsedTimeIntoWholeFrames() {
        var game = quietGame()
        game.advance(by: 0.01, input: PearlInput())
        XCTAssertEqual(game.frame, 0, "10ms is less than a frame; it must be saved, not stepped")
        game.advance(by: 0.008, input: PearlInput())
        XCTAssertEqual(game.frame, 1, "the remainder plus 8ms crosses one frame exactly")

        var uneven = quietGame()
        for _ in 0..<10 {
            uneven.advance(by: 0.1001, input: PearlInput())
        }
        XCTAssertEqual(uneven.frame, 60, "uneven ticks must not lose or invent frames")
    }

    func testALongStallIsForgivenNotReplayed() {
        var game = quietGame()
        game.advance(by: 100, input: PearlInput())
        XCTAssertLessThanOrEqual(game.frame, PearlTuning.maxFrameDebt,
                                 "a stall must not fast-forward the run")
        XCTAssertGreaterThan(game.frame, 0)
    }

    // MARK: - Geometry sanity shared with the sprite contract

    func testObstacleFootprintsComeFromTheContract() {
        XCTAssertEqual(PearlObstacleKind.smallTrees(3).size.width,
                       PearlSpriteContract.treeSmall.width * 3)
        XCTAssertEqual(PearlObstacleKind.largeTrees(2).size.width,
                       PearlSpriteContract.treeLarge.width * 2)
        XCTAssertEqual(PearlObstacleKind.gull(.low).size.height,
                       PearlSpriteContract.gull.height)
        XCTAssertEqual(PearlObstacleKind.smallTrees(1).topY,
                       PearlWorld.feetLine - PearlSpriteContract.treeSmall.height)
    }

    func testPearlSilhouettesComeFromTheContract() {
        var game = quietGame()
        XCTAssertEqual(game.pearlBounds.width, PearlSpriteContract.run.width)
        XCTAssertEqual(game.pearlBounds.height, PearlSpriteContract.run.height)
        game.step(input: PearlInput(duck: true))
        XCTAssertEqual(game.pearlBounds.width, PearlSpriteContract.duck.width)
        XCTAssertEqual(game.pearlBounds.height, PearlSpriteContract.duck.height)
        XCTAssertEqual(game.pearlBounds.maxY, PearlWorld.feetLine,
                       "feet stay on the feet line in both poses")
    }
}
