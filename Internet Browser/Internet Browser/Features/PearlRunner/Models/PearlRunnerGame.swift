//
//  PearlRunnerGame.swift
//  Cherry Browser
//
//  The whole game, with no screen in it.
//
//  ## Why the simulation is a struct of numbers
//
//  Screenshot verification is banned in this codebase, so the game's rules are
//  provable only one way: step the model frame by frame in a test and read the
//  state. Everything that decides anything — positions, velocities, the spawn
//  schedule, collision, scoring, the speed ramp, day and night — lives here in
//  plain value types. The one source of time is `step()`, the one source of
//  chance is `PearlRNG` behind a caller-supplied seed, and the struct is
//  `Equatable`, so "the same seed and the same inputs produce the same run"
//  is a single `XCTAssertEqual`.
//
//  `PearlRunnerView` is a renderer over a value of this type and adds no rules
//  of its own.
//
//  ## Units and tuning
//
//  The world is measured in logical points at 1x (the sprite contract's
//  sizes), stepped at a fixed 60 frames per second; speeds are points per
//  frame, matching the Chrome runner's own units so its well-worn feel
//  numbers carry over. The tuned values, and what each one was tuned
//  against, live in `PearlTuning` with the reasoning attached — the jump
//  arithmetic in particular is load-bearing for `PearlRunnerGameTests`.
//

import Foundation

// MARK: - Deterministic randomness

/// SplitMix64. Chosen because it is tiny, fast, statistically fine for
/// arranging cherry trees, and — the actual requirement — a pure value type:
/// copying the game copies the generator, so replays cannot drift.
nonisolated struct PearlRNG: Equatable {

    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func nextRaw() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in `range`. 53 bits, the full precision of a `Double` mantissa.
    mutating func double(in range: ClosedRange<Double>) -> Double {
        let unit = Double(nextRaw() >> 11) * (1.0 / 9_007_199_254_740_992.0)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }

    /// Uniform integer. Modulo bias is irrelevant at the range sizes used here
    /// (spans of 2 and 3 against 2^64).
    mutating func int(in range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(nextRaw() % span)
    }

    mutating func bool() -> Bool {
        nextRaw() & 1 == 1
    }
}

// MARK: - The world's fixed geometry

nonisolated enum PearlWorld {
    /// The stage, in logical points. 560 is `FailureColumn`'s measure, so the
    /// game fills the same column the failure copy sits in; 150 is the Chrome
    /// runner's height, which the sprite sizes are proportioned for.
    static let width = 560.0
    static let height = 150.0
    /// Where feet meet the ground. The 12pt ground strip's bottom edge.
    static let feetLine = 140.0
    /// Pearl's fixed leading edge. The game scrolls; the cat does not.
    static let pearlX = 30.0
    static let framesPerSecond = 60.0
    static let frameDuration = 1.0 / framesPerSecond
}

// MARK: - Tuning

/// Every number that decides how the game feels, and what it was tuned
/// against. Speeds are points per frame at 60fps, accelerations points per
/// frame squared.
nonisolated enum PearlTuning {

    // ## The run
    /// Start/ceiling/ramp carried over from the Chrome runner (6 / 13 /
    /// 0.001), whose pacing a decade of stranded commuters has already
    /// play-tested. Top speed arrives at frame 7000, just under two minutes in.
    static let initialSpeed = 6.0
    static let maxSpeed = 13.0
    static let acceleration = 0.001

    // ## The jump
    /// Gravity 0.6 with take-off -10 gives a held jump an apex of ~74pt —
    /// clears a large tree (50pt) with 18 frames to spare at starting speed.
    static let gravity = 0.6
    static let jumpVelocity = -10.0
    /// Releasing early caps the rise at -6.5, an apex of ~44pt: enough to
    /// clear a small tree (35pt, ~13 frames of timing slack) and provably not
    /// a large one (50pt) at any press timing — the tap/hold distinction
    /// `PearlRunnerGameTests` steps out frame by frame.
    static let tapJumpVelocityCap = -6.5
    /// Holding ↓ in the air triples gravity, the Chrome runner's "speed drop":
    /// a jump can be cancelled into a duck instead of floating into a gull.
    static let fastFallMultiplier = 3.0

    // ## Scoring, day and night
    /// Score is distance × this: ~9 points per second at starting speed,
    /// matching the cadence dino players expect.
    static let pointsPerDistance = 0.025
    /// The sky flips at every multiple of 700 points, the Chrome runner's
    /// milestone.
    static let nightFlipScore = 700

    // ## The spawn schedule
    /// The first obstacle enters at 500pt of scroll — with the crossing time
    /// from the right edge that is just under three seconds of grace.
    static let firstObstacleDistance = 500.0
    /// Gap after an obstacle: its width × speed + this base × 0.6, then a
    /// random stretch up to 1.5×. Faster world, longer gaps, same reaction
    /// time — the Chrome runner's formula and constants.
    static let treeGapBase = 120.0
    static let gullGapBase = 150.0
    static let gapCoefficient = 0.6
    static let maxGapStretch = 1.5
    /// Gulls join at 8.5, once the player has proven they can steer.
    static let gullMinimumSpeed = 8.5
    /// A gull flies at world speed ± this, so two gulls never feel identical.
    static let gullSpeedOffset = 0.8
    /// No more than two consecutive obstacles of the same type.
    static let maxSameKindRun = 2

    // ## Clouds (decoration, but deterministic decoration)
    static let cloudSpeedFactor = 0.3
    static let firstCloudDistance = 200.0
    static let cloudGap = 150.0...400.0
    static let cloudAltitude = 20.0...70.0

    // ## Fairness insets
    //
    // Collision uses boxes smaller than the sprites. Tuned by stepping graze
    // scenarios: a box the full size of the art makes Pearl's tail and the
    // gull's wingtip lethal, and a death by wingtip is the moment collision
    // becomes unfair.
    /// Pearl: 5pt off each side (tail and nose), 4 off the top (ears), 1 off
    /// the feet.
    static let pearlSideInset = 5.0
    static let pearlTopInset = 4.0
    static let pearlFootInset = 1.0
    /// While ducking the silhouette is already low and flat; only 3 comes off
    /// the top, which sets the duck-under clearance the gull heights are
    /// spaced against.
    static let duckTopInset = 3.0
    /// Trees: 2pt for leaf fringe.
    static let treeInset = 2.0
    /// Gulls: 6pt all round for wing feathers.
    static let gullInset = 6.0

    /// `advance(by:)` never steps more than this many frames per call: after
    /// a long stall the game resumes instead of replaying the stall as a
    /// lethal fast-forward.
    static let maxFrameDebt = 10
}

// MARK: - Boxes

nonisolated struct PearlBox: Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var maxX: Double { x + width }
    var maxY: Double { y + height }

    func intersects(_ other: PearlBox) -> Bool {
        x < other.maxX && other.x < maxX && y < other.maxY && other.y < maxY
    }

    func inset(sides: Double, top: Double, bottom: Double) -> PearlBox {
        PearlBox(
            x: x + sides,
            y: y + top,
            width: max(0, width - sides * 2),
            height: max(0, height - top - bottom)
        )
    }
}

// MARK: - Obstacles

/// The three lanes a gull flies in, as the top edge of its 40pt-tall box.
///
/// Spaced against Pearl's two silhouettes (standing top 93, ducking top 110,
/// after insets 97 and 113):
///
///     lane      box bottom (after 6pt inset)   standing   ducking
///     high      50 + 40 - 6 =  84              clears     clears
///     middle    75 + 40 - 6 = 109              hit        clears by 4pt
///     low      100 + 40 - 6 = 134              hit        hit — jump it
nonisolated enum PearlGullLane: Double, CaseIterable, Equatable {
    case high = 50
    case middle = 75
    case low = 100
}

nonisolated enum PearlObstacleKind: Equatable {
    /// 1...3 small cherry trees planted shoulder to shoulder.
    case smallTrees(Int)
    /// 1...2 large cherry trees.
    case largeTrees(Int)
    case gull(PearlGullLane)

    /// Footprint in logical points — the sprite contract's sizes, so the art
    /// and the collision geometry cannot disagree.
    var size: (width: Double, height: Double) {
        switch self {
        case .smallTrees(let count):
            return (PearlSpriteContract.treeSmall.width * Double(count),
                    PearlSpriteContract.treeSmall.height)
        case .largeTrees(let count):
            return (PearlSpriteContract.treeLarge.width * Double(count),
                    PearlSpriteContract.treeLarge.height)
        case .gull:
            return (PearlSpriteContract.gull.width, PearlSpriteContract.gull.height)
        }
    }

    /// Top edge: trees stand on the ground, gulls fly in their lane.
    var topY: Double {
        switch self {
        case .smallTrees, .largeTrees:
            return PearlWorld.feetLine - size.height
        case .gull(let lane):
            return lane.rawValue
        }
    }
}

nonisolated struct PearlObstacle: Equatable {
    var kind: PearlObstacleKind
    /// Leading (left) edge.
    var x: Double
    /// Gulls fly at world speed plus this; trees are rooted at 0.
    var speedOffset: Double

    var bounds: PearlBox {
        let size = kind.size
        return PearlBox(x: x, y: kind.topY, width: size.width, height: size.height)
    }

    var collisionBox: PearlBox {
        switch kind {
        case .smallTrees, .largeTrees:
            return bounds.inset(sides: PearlTuning.treeInset, top: PearlTuning.treeInset, bottom: 0)
        case .gull:
            return bounds.inset(
                sides: PearlTuning.gullInset,
                top: PearlTuning.gullInset,
                bottom: PearlTuning.gullInset
            )
        }
    }
}

/// Scenery. Takes no part in collision, but spawns from the same seeded
/// generator so a replay reproduces the sky along with everything else.
nonisolated struct PearlCloud: Equatable {
    var x: Double
    var y: Double
}

// MARK: - Input

/// What the player is holding this frame. State, not events: the game finds
/// its own edges by comparing against the previous frame, so a test's input
/// script is just an array of these.
nonisolated struct PearlInput: Equatable {
    var jump = false
    var duck = false

    init(jump: Bool = false, duck: Bool = false) {
        self.jump = jump
        self.duck = duck
    }
}

// MARK: - The game

nonisolated struct PearlRunnerGame: Equatable {

    enum Phase: Equatable {
        case running
        case crashed
    }

    // ## Pearl
    private(set) var phase: Phase = .running
    /// Where the feet are. `feetLine` on the ground, smaller in the air.
    private(set) var feetY = PearlWorld.feetLine
    /// Points per frame, positive downward, like the y axis.
    private(set) var verticalVelocity = 0.0
    private(set) var isDucking = false

    // ## The world
    //
    // `speed`, `distance`, `obstacles` and the two schedules are internal
    // rather than private so the frame-stepping tests can place the world in
    // a known state (a single tree at a known x, a speed past the gull
    // threshold) instead of fishing for one in the spawn stream.
    var speed = PearlTuning.initialSpeed
    var distance = 0.0
    var obstacles: [PearlObstacle] = []
    var clouds: [PearlCloud] = []
    var nextObstacleDistance = PearlTuning.firstObstacleDistance
    var nextCloudDistance = PearlTuning.firstCloudDistance

    private(set) var frame = 0
    private var rng: PearlRNG
    private var previousInput = PearlInput()
    /// The same-type-run guard: which kind came last, and how many in a row.
    private var lastKindTag = -1
    private var sameKindRun = 0
    /// Unconsumed real time, for `advance(by:)`.
    private var timeDebt = 0.0

    init(seed: UInt64) {
        rng = PearlRNG(seed: seed)
    }

    // MARK: Derived state

    var score: Int {
        Int(distance * PearlTuning.pointsPerDistance)
    }

    /// Night after 700, day again after 1400, and so on.
    var isNight: Bool {
        (score / PearlTuning.nightFlipScore) % 2 == 1
    }

    var isAirborne: Bool {
        feetY < PearlWorld.feetLine
    }

    /// The silhouette: standing 44×47, ducking 59×30 — the contract's sizes.
    var pearlBounds: PearlBox {
        let size = isDucking ? PearlSpriteContract.duck : PearlSpriteContract.run
        return PearlBox(
            x: PearlWorld.pearlX,
            y: feetY - size.height,
            width: size.width,
            height: size.height
        )
    }

    var pearlCollisionBox: PearlBox {
        pearlBounds.inset(
            sides: PearlTuning.pearlSideInset,
            top: isDucking ? PearlTuning.duckTopInset : PearlTuning.pearlTopInset,
            bottom: PearlTuning.pearlFootInset
        )
    }

    // MARK: Time

    /// The renderer's entry point: hand over wall-clock time, get whole
    /// simulation frames. The remainder is kept, so 60Hz of slightly uneven
    /// ticks still yields exactly 60 steps per second; a long stall is
    /// forgiven rather than replayed (`maxFrameDebt`).
    mutating func advance(by elapsed: TimeInterval, input: PearlInput) {
        timeDebt = min(
            timeDebt + max(0, elapsed),
            Double(PearlTuning.maxFrameDebt) * PearlWorld.frameDuration
        )
        while timeDebt >= PearlWorld.frameDuration {
            timeDebt -= PearlWorld.frameDuration
            step(input: input)
        }
    }

    /// One frame. The only place anything moves.
    mutating func step(input: PearlInput) {
        // A crashed game is FROZEN — not even the input memory moves, so
        // "stepping a crashed game changes nothing" is literally true and
        // testable with one equality.
        guard phase == .running else { return }
        defer { previousInput = input }
        frame += 1

        let jumpPressed = input.jump && !previousInput.jump
        let jumpReleased = !input.jump && previousInput.jump

        // ## Pearl
        if !isAirborne && jumpPressed {
            verticalVelocity = PearlTuning.jumpVelocity
        }
        if isAirborne || verticalVelocity != 0 {
            // Let go early and the rise is capped: tap for a short hop, hold
            // for the full arc.
            if jumpReleased && verticalVelocity < PearlTuning.tapJumpVelocityCap {
                verticalVelocity = PearlTuning.tapJumpVelocityCap
            }
            let gravity = input.duck
                ? PearlTuning.gravity * PearlTuning.fastFallMultiplier
                : PearlTuning.gravity
            verticalVelocity += gravity
            feetY += verticalVelocity
            if feetY >= PearlWorld.feetLine {
                feetY = PearlWorld.feetLine
                verticalVelocity = 0
            }
            isDucking = false
        } else {
            isDucking = input.duck
        }

        // ## The world scrolls
        speed = min(speed + PearlTuning.acceleration, PearlTuning.maxSpeed)
        distance += speed

        for index in obstacles.indices {
            obstacles[index].x -= speed + obstacles[index].speedOffset
        }
        obstacles.removeAll { $0.bounds.maxX < 0 }

        for index in clouds.indices {
            clouds[index].x -= speed * PearlTuning.cloudSpeedFactor
        }
        clouds.removeAll { $0.x < -PearlSpriteContract.cloud.width }

        if distance >= nextObstacleDistance {
            spawnObstacle()
        }
        if distance >= nextCloudDistance {
            spawnCloud()
        }

        // ## Collision
        let pearl = pearlCollisionBox
        if obstacles.contains(where: { $0.collisionBox.intersects(pearl) }) {
            phase = .crashed
        }
    }

    /// Back to the start line. The generator is NOT reseeded: a session's
    /// randomness is one stream, so a replay that includes a restart is still
    /// a replay.
    mutating func reset() {
        phase = .running
        feetY = PearlWorld.feetLine
        verticalVelocity = 0
        isDucking = false
        speed = PearlTuning.initialSpeed
        distance = 0
        obstacles = []
        clouds = []
        nextObstacleDistance = PearlTuning.firstObstacleDistance
        nextCloudDistance = PearlTuning.firstCloudDistance
        frame = 0
        lastKindTag = -1
        sameKindRun = 0
        timeDebt = 0
        // The restart key is usually still held on the first frame back; it
        // must not read as a fresh press and launch Pearl off the line.
        previousInput = PearlInput(jump: true, duck: false)
    }

    /// Test hook: a known obstacle at a known place, bypassing the schedule.
    mutating func place(_ kind: PearlObstacleKind, at x: Double) {
        obstacles.append(PearlObstacle(kind: kind, x: x, speedOffset: 0))
    }

    // MARK: Spawning

    private mutating func spawnObstacle() {
        let kind = chooseKind()
        let speedOffset: Double
        if case .gull = kind {
            speedOffset = rng.bool() ? PearlTuning.gullSpeedOffset : -PearlTuning.gullSpeedOffset
        } else {
            speedOffset = 0
        }
        obstacles.append(PearlObstacle(kind: kind, x: PearlWorld.width, speedOffset: speedOffset))

        let gapBase: Double
        if case .gull = kind {
            gapBase = PearlTuning.gullGapBase
        } else {
            gapBase = PearlTuning.treeGapBase
        }
        let minimumGap = kind.size.width * speed + gapBase * PearlTuning.gapCoefficient
        let gap = rng.double(in: minimumGap...(minimumGap * PearlTuning.maxGapStretch))
        nextObstacleDistance = distance + gap
    }

    private mutating func chooseKind() -> PearlObstacleKind {
        let typeCount = speed >= PearlTuning.gullMinimumSpeed ? 3 : 2
        var tag = rng.int(in: 0...(typeCount - 1))
        if tag == lastKindTag && sameKindRun >= PearlTuning.maxSameKindRun {
            tag = (tag + 1) % typeCount
        }
        if tag == lastKindTag {
            sameKindRun += 1
        } else {
            lastKindTag = tag
            sameKindRun = 1
        }
        switch tag {
        case 0: return .smallTrees(rng.int(in: 1...3))
        case 1: return .largeTrees(rng.int(in: 1...2))
        default: return .gull(PearlGullLane.allCases[rng.int(in: 0...2)])
        }
    }

    private mutating func spawnCloud() {
        clouds.append(PearlCloud(
            x: PearlWorld.width,
            y: rng.double(in: PearlTuning.cloudAltitude)
        ))
        nextCloudDistance = distance + rng.double(in: PearlTuning.cloudGap)
    }
}
