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
        pressDistance: Double,
        atSpeed speed: Double? = nil
    ) -> Bool {
        var game = quietGame()
        if let speed { game.speed = speed }
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

    /// The same seed and the same INPUTS, fed through wall-clock time in
    /// wildly uneven slices instead of whole frames, still lands on exactly
    /// the same run. This is what says the ramp, the jump's scale and the
    /// milestone count are functions of the simulation and not of when a timer
    /// happened to fire.
    ///
    /// Dies on the fixed-timestep accumulator in `advance` going — one step
    /// per call instead of one per frame owed — which is the mutation that
    /// makes the ramp, the sky and the milestone count all functions of how
    /// often a timer happened to fire.
    func testUnevenWallClockSlicesReachTheIdenticalRun() {
        func input(at frame: Int) -> PearlInput {
            PearlInput(jump: frame % 90 < 12, duck: frame % 210 >= 150 && frame % 210 < 190)
        }

        // Held per lump on both sides, because a key held across five frames
        // is what a lump of wall-clock time actually delivers. The field is
        // empty so the run reaches all fifty seconds instead of ending in the
        // first tree — what is under test is the curve, not the trees.
        var stepped = quietGame(seed: 41)
        for lump in 0..<600 {
            for _ in 0..<5 { stepped.step(input: input(at: lump * 5)) }
        }

        // The same 3000 frames delivered as 1/12th-second lumps of wall clock,
        // which is nothing like a 60Hz tick.
        var advanced = quietGame(seed: 41)
        for lump in 0..<600 {
            advanced.advance(by: 5 * PearlWorld.frameDuration, input: input(at: lump * 5))
        }

        XCTAssertEqual(advanced.frame, 3000, "the accumulator lost or invented frames")
        XCTAssertEqual(advanced.speed, stepped.speed, accuracy: 1e-12,
                       "the ramp is not a function of frames")
        XCTAssertEqual(advanced.milestonesPassed, stepped.milestonesPassed)
        XCTAssertEqual(advanced.sky, stepped.sky)
        XCTAssertEqual(advanced.feetY, stepped.feetY, accuracy: 1e-12,
                       "the jump's scale drifted with the clock")
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

    /// The opening. 4.2 is Chrome's own slow-mode starting speed, and the
    /// whole point of the change: the game used to begin at 6.0, which is
    /// where Chrome's NORMAL mode begins, so there was no opening at all.
    ///
    /// Dies on `initialSpeed` going back to 6.0, and on the first frame
    /// accelerating out of the opening at anything but 0.001.
    func testTheRunOpensAtChromesSlowModeSpeed() {
        var game = quietGame()
        XCTAssertEqual(game.speed, 4.2)
        step(&game, frames: 80)
        XCTAssertEqual(game.speed, 4.28, accuracy: 1e-9)
    }

    /// The curve at four points along it, by frame count and by the score the
    /// player is actually looking at when they get there. One acceleration all
    /// the way — 4.2 + 0.001 × frame — so the whole ramp is these four rows.
    ///
    /// Dies on a second ramp being bolted under the first (any two-rate curve
    /// misses at least one row), on `acceleration` moving, and on the ceiling
    /// moving.
    func testTheWholeCurveIsOneLineFromFourPointTwoToThirteen() {
        var game = quietGame()
        // frame, expected speed, expected score
        let curve: [(Int, Double, Int)] = [
            (600, 4.8, 67),      // ten seconds in
            (1800, 6.0, 229),    // thirty seconds: what used to be frame zero
            (5400, 9.6, 931),    // ninety seconds
            (8800, 13.0, 1892),  // the ceiling, 146.7 seconds in
        ]
        var frame = 0
        for (target, speed, score) in curve {
            step(&game, frames: target - frame)
            frame = target
            XCTAssertEqual(game.speed, speed, accuracy: 1e-9,
                           "the curve is wrong at frame \(target)")
            XCTAssertEqual(game.score, score, "the score is wrong at frame \(target)")
        }
    }

    func testSpeedTopsOutAtThirteenAndStaysThere() {
        var game = quietGame()
        step(&game, frames: 8700)
        XCTAssertLessThan(game.speed, 13.0, "the ceiling must not arrive early")
        step(&game, frames: 200)
        XCTAssertEqual(game.speed, 13.0)
        step(&game, frames: 900)
        XCTAssertEqual(game.speed, 13.0)
    }

    /// The grace before the first obstacle, in seconds rather than in points,
    /// because seconds is what Chrome's `clearTime: 3000` is measured in and
    /// what the player experiences. It used to be 1.4 seconds.
    ///
    /// Dies on `firstObstacleDistance` going back to 500, and on the opening
    /// speed rising underneath it (which would shorten the same distance).
    func testNothingIsSpawnedForChromesThreeSecondsOfGrace() throws {
        var game = PearlRunnerGame(seed: 3)
        game.nextCloudDistance = .infinity
        var firstSpawnFrame: Int?
        for _ in 0..<600 where firstSpawnFrame == nil {
            game.step(input: PearlInput())
            if !game.obstacles.isEmpty { firstSpawnFrame = game.frame }
        }
        let frame = try XCTUnwrap(firstSpawnFrame, "nothing spawned in ten seconds")
        let seconds = Double(frame) * PearlWorld.frameDuration
        XCTAssertEqual(seconds, 3.0, accuracy: 0.1,
                       "the first obstacle enters after \(seconds)s, not Chrome's 3")
    }

    // MARK: - The jump, over the whole opening ramp
    //
    // A jump is a fixed number of FRAMES in the air, so a slower world is a
    // harder one: the same tree spends more frames beside Pearl. Left alone,
    // the tuned claim "a tap clears a small tree" simply stops being true
    // below about 4.27pt per frame — which is above the new opening speed.
    //
    // `PearlTuning.jumpScale` is the answer, and it is Chrome's answer too
    // (its slow mode swaps gravity 0.6 → 0.25 and take-off -10 → -20). These
    // are what say it worked: the tuned contract, re-asked at every speed the
    // opening ramp passes through rather than only at the one it used to
    // start at.

    /// Dies on `jumpScale` returning a constant 1 (the tap stops clearing a
    /// small tree at the bottom of the ramp) and on it being applied to
    /// take-off without being squared into gravity (the arc stops being the
    /// same shape and the clearance drifts).
    func testATapStillClearsASmallTreeEverywhereOnTheOpeningRamp() {
        for speed in stride(from: 4.2, through: 6.0, by: 0.1) {
            XCTAssertTrue(
                survivesJump(over: .smallTrees(1), holdFrames: 1,
                             pressDistance: 38, atSpeed: speed),
                "a tap no longer clears a small tree at speed \(speed)"
            )
        }
    }

    /// The other half of the same contract, which a stronger jump would break
    /// in the opposite direction. Dies on the scale being applied to gravity
    /// but not to the tap cap, which lets a tap float over a large tree at the
    /// bottom of the ramp.
    func testATapStillNeverClearsALargeTreeAnywhereOnTheOpeningRamp() {
        for speed in stride(from: 4.2, through: 6.0, by: 0.2) {
            for pressDistance in stride(from: 10.0, through: 110.0, by: 8.0) {
                XCTAssertFalse(
                    survivesJump(over: .largeTrees(1), holdFrames: 1,
                                 pressDistance: pressDistance, atSpeed: speed),
                    "a tap cleared a large tree at speed \(speed), pressed \(pressDistance)pt out"
                )
            }
        }
    }

    func testAHeldJumpStillClearsALargeTreeEverywhereOnTheOpeningRamp() {
        for speed in stride(from: 4.2, through: 6.0, by: 0.1) {
            XCTAssertTrue(
                survivesJump(over: .largeTrees(1), holdFrames: 40,
                             pressDistance: 38, atSpeed: speed),
                "a held jump no longer clears a large tree at speed \(speed)"
            )
        }
    }

    /// What the scaling is FOR, stated directly: the arc covers the same
    /// ground whatever the world speed, and takes proportionally longer to do
    /// it. Dies on the scale being dropped, and on it being applied to gravity
    /// linearly instead of squared.
    func testTheJumpCoversTheSameGroundAtEverySpeedAndOnlyTakesLonger() {
        func arc(atSpeed speed: Double) -> (apex: Double, airborneFrames: Int) {
            var game = quietGame()
            game.speed = speed
            var top = PearlWorld.feetLine
            var frames = 0
            for frame in 0..<200 {
                game.step(input: PearlInput(jump: frame < 40))
                top = min(top, game.feetY)
                if game.isAirborne { frames += 1 }
                if frame > 2 && !game.isAirborne { break }
            }
            return (PearlWorld.feetLine - top, frames)
        }
        let slow = arc(atSpeed: 4.2)
        let tuned = arc(atSpeed: 6.0)
        XCTAssertEqual(slow.apex, tuned.apex, accuracy: 2.0,
                       "the arc changed height, not just duration")
        XCTAssertEqual(
            Double(slow.airborneFrames) * 4.2,
            Double(tuned.airborneFrames) * 6.0,
            accuracy: 6.0,
            "the arc no longer covers the same ground at the two speeds"
        )
        XCTAssertGreaterThan(slow.airborneFrames, tuned.airborneFrames,
                             "a slower world should give a longer-lasting jump")
    }

    /// Above the reference speed nothing was touched at all. Dies on the
    /// scale being applied upwards as well, which would make the late game a
    /// different game from the one that shipped.
    func testTheJumpIsUntouchedAtAndAboveTheSpeedItWasTunedAt() {
        for speed in [6.0, 8.5, 13.0] {
            XCTAssertEqual(PearlTuning.jumpScale(atSpeed: speed), 1.0)
        }
        XCTAssertEqual(PearlTuning.jumpScale(atSpeed: 4.2), 0.7, accuracy: 1e-9)
    }

    // MARK: - Groups, gated by speed the way Chrome gates them
    //
    // Chrome's `multipleSpeed`: a drawn group of two or three is planted as
    // one until the world is fast enough to jump it. Cherry never had it, and
    // the slower opening is exactly where it matters — two large trees need
    // 80pt of clearance and a held jump buys 11.3 frames of it, so below
    // 7.07pt per frame they are a wall. Chrome's gate is 7.0.

    /// The gate that matters, at both ends of the range it covers: the whole
    /// opening ramp, and one frame under Chrome's 7.0. Dies on the large
    /// gate going, and on it being shared with the small one.
    func testNoPairOfLargeTreesBeforeTheWorldCanJumpThem() {
        for speed in [4.2, 4.5, 6.9] {
            for kind in harvestSpawns(seed: 31, speed: speed, count: 150) {
                if case .largeTrees(let count) = kind {
                    XCTAssertEqual(count, 1, "a pair of large trees spawned at speed \(speed)")
                }
                if case .gull = kind { XCTFail("a gull spawned far below its own gate") }
            }
        }
    }

    /// And small groups are NOT gated with them: they are jumpable from the
    /// opening speed (three small trees need 81pt of clearance and a held jump
    /// buys 151pt at 4.2), so gating them too would have made the opening
    /// emptier than it needed to be. Chrome draws the same line — its small
    /// gate is 4.0 and its large one is 7.0.
    func testSmallGroupsAreAllowedFromTheOpeningSpeed() {
        var sawSmallGroup = false
        for kind in harvestSpawns(seed: 31, speed: PearlTuning.initialSpeed, count: 200) {
            if case .smallTrees(let count) = kind, count > 1 { sawSmallGroup = true }
        }
        XCTAssertTrue(sawSmallGroup, "small groups should already be allowed at 4.2")
    }

    /// The small gate itself, asked below a speed the ramp never reaches —
    /// Cherry opens at 4.2 and Chrome's small gate is 4.0, so this one never
    /// binds in a real run. It is here because the gate exists, and a gate
    /// that is never exercised is a gate that quietly stops working before
    /// the opening speed is ever lowered again.
    func testTheSmallGateWouldStillBiteBelowTheOpeningSpeed() {
        for kind in harvestSpawns(seed: 31, speed: 3.9, count: 120) {
            if case .smallTrees(let count) = kind {
                XCTAssertEqual(count, 1, "a group of \(count) small trees spawned at speed 3.9")
            }
        }
    }

    func testLargeGroupsArriveOnceTheWorldCanJumpThem() {
        let kinds = harvestSpawns(seed: 31, speed: PearlTuning.maxSpeed, count: 200)
        XCTAssertTrue(
            kinds.contains { if case .largeTrees(let n) = $0 { return n > 1 } else { return false } },
            "at top speed two hundred spawns should include a pair of large trees"
        )
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

    // MARK: - The four skies
    //
    // Dies when `skyPhaseScore` moves, when the phase order is rotated, and
    // when `isNight` stops agreeing with the 700 it has always been.

    /// Every boundary, named. The first colour change now happens at 350,
    /// halfway to a nightfall that has not moved.
    func testTheSkyTurnsAtEveryThreeHundredAndFifty() {
        let expected: [(Int, PearlSky)] = [
            (0, .day), (349, .day),
            (350, .dusk), (699, .dusk),
            (700, .night), (1049, .night),
            (1050, .dawn), (1399, .dawn),
            (1400, .day), (1750, .dusk), (2100, .night),
        ]
        for (score, sky) in expected {
            XCTAssertEqual(PearlSky.at(score: score), sky, "score \(score) got the wrong sky")
        }
    }

    /// The new states may not have moved the old one. Checked as arithmetic
    /// over a whole three cycles rather than at a handful of points, because
    /// "night is still exactly the second 700" is the claim, not "night still
    /// happens somewhere".
    ///
    /// Dies on `skyPhaseScore` becoming anything but half of `nightFlipScore`,
    /// and on the phase order being rotated so dawn lands in daylight.
    func testNightIsStillExactlyTheSameSevenHundredItAlwaysWas() {
        for score in 0...2100 {
            XCTAssertEqual(
                PearlSky.at(score: score).isNight,
                (score / 700) % 2 == 1,
                "score \(score) disagrees with the old day/night arithmetic"
            )
        }
    }

    /// The sky is a function of the simulation and of nothing else — set the
    /// distance, get the sky, with no frames stepped and no clock consulted.
    func testTheSkyIsReadStraightOffTheScore() {
        var game = quietGame()
        for (score, sky) in [(0, PearlSky.day), (350, .dusk), (700, .night), (1050, .dawn)] {
            game.distance = Double(score) / PearlTuning.pointsPerDistance
            XCTAssertEqual(game.score, score)
            XCTAssertEqual(game.sky, sky)
        }
    }

    // MARK: - Milestones
    //
    // Dies when `milestoneScore` moves off Chrome's 100, and when
    // `milestonesPassed` starts counting something other than crossings.

    func testEveryHundredPointsIsOneMilestoneAndNoMore() {
        var game = quietGame()
        XCTAssertEqual(game.milestonesPassed, 0)
        for (score, passed) in [(99, 0), (100, 1), (199, 1), (200, 2), (1000, 10)] {
            game.distance = Double(score) / PearlTuning.pointsPerDistance
            XCTAssertEqual(game.score, score)
            XCTAssertEqual(game.milestonesPassed, passed, "score \(score)")
        }
    }

    /// Stepping over a hundred raises the count exactly once, on the frame
    /// that crosses it. Dies on the count being derived from the frame or
    /// from elapsed time instead of from the score.
    func testTheCountRisesOnTheFrameThatCrossesTheHundred() {
        var game = quietGame()
        game.distance = 100 / PearlTuning.pointsPerDistance - 3
        XCTAssertEqual(game.milestonesPassed, 0)
        game.step(input: PearlInput())
        XCTAssertEqual(game.milestonesPassed, 1)
        var raised = 0
        for _ in 0..<200 {
            let before = game.milestonesPassed
            game.step(input: PearlInput())
            if game.milestonesPassed > before { raised += 1 }
        }
        XCTAssertEqual(raised, 0, "200 more frames should not reach another hundred yet")
    }

    /// A restart puts the milestones back too, so the second run rings from
    /// its own first hundred rather than never ringing again.
    func testResettingPutsTheMilestonesBack() {
        var game = quietGame()
        game.distance = 450 / PearlTuning.pointsPerDistance
        XCTAssertEqual(game.milestonesPassed, 4)
        game.reset()
        XCTAssertEqual(game.milestonesPassed, 0)
        XCTAssertEqual(game.sky, .day)
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
