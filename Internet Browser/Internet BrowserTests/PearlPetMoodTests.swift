//
//  PearlPetMoodTests.swift
//  Internet BrowserTests
//
//  Her day, marched through by hand.
//
//  `PearlPetMood` is a pure value: what she is doing is a function of the
//  clock and of when she was last noticed. That is what makes a desktop pet's
//  behaviour testable at all — no timers to wait on, no rendering to inspect,
//  just arithmetic asked at chosen instants.
//

import XCTest
@testable import Cherry

@MainActor
final class PearlPetMoodTests: XCTestCase {

    private func mood(disturbedAt: TimeInterval = 0) -> PearlPetMood {
        var mood = PearlPetMood()
        mood.lastDisturbed = disturbedAt
        return mood
    }

    // MARK: - Idling

    /// Left alone she sits, and the sitting itself is a two-frame breath
    /// rather than a frozen picture.
    func testSheSitsAndBreathes() {
        let mood = self.mood()
        let frames = Set(stride(from: 0.0, to: 5.0, by: 0.1).map {
            mood.appearance(at: $0).frame
        })
        XCTAssertEqual(mood.appearance(at: 0.2).pose, .sitting)
        XCTAssertEqual(frames, [0, 1], "her sit is one frame — she is not breathing")
    }

    /// She blinks, twice a loop, and briefly.
    func testSheBlinksTwiceALoopAndBriefly() {
        let mood = self.mood()
        var blinking: [TimeInterval] = []
        for step in stride(from: 0.0, to: PearlPetMood.idleLoop, by: 0.05) {
            if mood.appearance(at: step).pose == .blinking { blinking.append(step) }
        }
        XCTAssertFalse(blinking.isEmpty, "she never blinks")
        let total = Double(blinking.count) * 0.05
        XCTAssertLessThan(total, 1.0, "she blinks for \(total)s a loop — that is a stare")

        // Two separate blinks, not one long one.
        let gaps = zip(blinking, blinking.dropFirst()).filter { $1 - $0 > 1 }
        XCTAssertEqual(gaps.count, 1, "expected exactly two blinks in the loop")
    }

    /// She grooms, once a loop, and the groom is animated.
    func testSheGroomsOnceALoop() {
        let mood = self.mood()
        let grooming = stride(from: 0.0, to: PearlPetMood.idleLoop, by: 0.05)
            .filter { mood.appearance(at: $0).pose == .grooming }
        XCTAssertFalse(grooming.isEmpty, "she never grooms")
        XCTAssertEqual(
            Set(grooming.map { mood.appearance(at: $0).frame }), [0, 1],
            "the groom is a still frame"
        )
    }

    /// The loop is a loop: the same instant one loop later is the same pose.
    func testHerDayRepeats() {
        let mood = self.mood()
        for step in stride(from: 0.0, to: PearlPetMood.idleLoop, by: 0.37) {
            XCTAssertEqual(
                mood.appearance(at: step).pose,
                mood.appearance(at: step + PearlPetMood.idleLoop).pose,
                "the loop does not close at \(step)"
            )
        }
    }

    /// Two Pearls in two windows are not animatronics: their loops start at
    /// different places.
    func testTwoPearlsDoNotBlinkInUnison() {
        var first = mood(), second = mood()
        first.phaseOffset = 0
        second.phaseOffset = 9
        let differ = stride(from: 0.0, to: PearlPetMood.idleLoop, by: 0.1).contains {
            first.appearance(at: $0).pose != second.appearance(at: $0).pose
        }
        XCTAssertTrue(differ, "two pets with different phases were identical all day")
    }

    // MARK: - Sleeping

    func testSheFallsAsleepWhenNobodyHasTouchedHer() {
        let mood = self.mood(disturbedAt: 0)
        XCTAssertNotEqual(mood.appearance(at: PearlPetMood.sleepsAfter - 1).pose, .sleeping)
        XCTAssertEqual(mood.appearance(at: PearlPetMood.sleepsAfter + 1).pose, .sleeping)
        XCTAssertEqual(mood.appearance(at: PearlPetMood.sleepsAfter + 600).pose, .sleeping,
                       "she woke up on her own")
    }

    func testSheBreathesInHerSleep() {
        let mood = self.mood(disturbedAt: 0)
        let frames = Set(stride(from: PearlPetMood.sleepsAfter + 1, to: PearlPetMood.sleepsAfter + 9, by: 0.2)
            .map { mood.appearance(at: $0).frame })
        XCTAssertEqual(frames, [0, 1])
    }

    func testBeingNoticedWakesHer() {
        var mood = self.mood(disturbedAt: 0)
        let late = PearlPetMood.sleepsAfter + 30
        XCTAssertEqual(mood.appearance(at: late).pose, .sleeping)
        mood.disturb(at: late)
        XCTAssertNotEqual(mood.appearance(at: late + 0.1).pose, .sleeping, "she slept through being moved")
    }

    // MARK: - Reactions

    func testAClickDelightsHerAndThenWearsOff() {
        var mood = self.mood()
        mood.delight(at: 100)
        XCTAssertEqual(mood.appearance(at: 100).pose, .delighted)
        XCTAssertEqual(mood.appearance(at: 100 + PearlPetMood.delightDuration - 0.05).pose, .delighted)
        XCTAssertNotEqual(mood.appearance(at: 100 + PearlPetMood.delightDuration + 0.05).pose, .delighted,
                          "she is permanently delighted")
    }

    func testAFishIsEatenAndTheMealEnds() {
        var mood = self.mood()
        mood.feed(at: 50)
        XCTAssertEqual(mood.appearance(at: 50).pose, .eating)
        XCTAssertEqual(
            Set(stride(from: 50.0, to: 50 + PearlPetMood.mealDuration, by: 0.1)
                .map { mood.appearance(at: $0).frame }),
            [0, 1],
            "she eats a still frame"
        )
        XCTAssertNotEqual(mood.appearance(at: 50 + PearlPetMood.mealDuration + 0.1).pose, .eating)
    }

    /// A fish beats a nap: she is asleep, she is fed, she eats.
    func testAFishWakesASleepingCat()  {
        var mood = self.mood(disturbedAt: 0)
        let late = PearlPetMood.sleepsAfter + 5
        XCTAssertEqual(mood.appearance(at: late).pose, .sleeping)
        mood.feed(at: late)
        XCTAssertEqual(mood.appearance(at: late + 0.1).pose, .eating)
    }

    /// A reaction is not a queue: a second one replaces the first.
    func testASecondReactionReplacesTheFirst() {
        var mood = self.mood()
        mood.feed(at: 10)
        mood.delight(at: 10.5)
        XCTAssertEqual(mood.appearance(at: 10.6).pose, .delighted)
    }

    // MARK: - Reduce Motion

    /// She stops moving. She does not disappear, and she does not freeze
    /// mid-groom either: she is a sitting cat.
    func testUnderReduceMotionSheIsASittingCat() {
        let mood = self.mood()
        for step in stride(from: 0.0, to: PearlPetMood.idleLoop * 2, by: 0.13) {
            XCTAssertEqual(
                mood.appearance(at: step, reduceMotion: true),
                PearlPetAppearance(pose: .sitting, frame: 0),
                "she moved at \(step) with Reduce Motion on"
            )
        }
        XCTAssertEqual(
            mood.appearance(at: PearlPetMood.sleepsAfter + 60, reduceMotion: true).pose,
            .sitting,
            "she is still awake with Reduce Motion on; sleeping is a change too"
        )
    }

    /// And nothing is ticking, which is what makes "she stops moving" free.
    func testUnderReduceMotionThereIsNothingToTick() {
        var mood = self.mood()
        XCTAssertTrue(mood.isStill(at: 0, reduceMotion: true))
        XCTAssertFalse(mood.isStill(at: 0, reduceMotion: false), "she is alive when motion is allowed")

        mood.feed(at: 0)
        XCTAssertFalse(mood.isStill(at: 0.1, reduceMotion: true), "the meal has nothing carrying it")
        XCTAssertTrue(
            mood.isStill(at: PearlPetMood.mealDuration + 0.1, reduceMotion: true),
            "the tick outlived the meal"
        )
    }
}
