//
//  OmniboxRankingTests.swift
//  Internet BrowserTests
//
//  Pins the omnibox's frecency ranking. The brief names four cases — same
//  frequency different recency, same recency different frequency, host prefix
//  versus substring, and a deterministic tie — and each has a test below with
//  that name. The rest guard the edges those four don't reach: the decay curve
//  itself, deduplication, and the ordering being total.
//
//  Every clock here is explicit. `Date()` never appears, so nothing in this
//  file can pass in the morning and fail at night.
//

import XCTest
@testable import Cherry

final class OmniboxRankingTests: XCTestCase {

    /// A fixed "now" so ages are exact.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func days(_ count: Double) -> Date {
        now.addingTimeInterval(-count * 86_400)
    }

    private func candidate(
        _ urlString: String,
        title: String = "",
        visits: Int = 1,
        ageDays: Double = 0
    ) -> OmniboxCandidate {
        OmniboxCandidate(
            url: URL(string: urlString)!,
            title: title,
            visitCount: visits,
            lastVisit: days(ageDays)
        )
    }

    private func rankedURLs(
        _ candidates: [OmniboxCandidate], query: String, limit: Int = 10
    ) -> [String] {
        OmniboxRanking.rank(candidates, query: query, now: now, limit: limit)
            .map(\.candidate.url.absoluteString)
    }

    // MARK: - The four cases the brief names

    /// Same frequency, different recency: recency decides.
    func testSameFrequencyDifferentRecency() {
        let fresh = candidate("https://alpha.example.com/", visits: 10, ageDays: 1)
        let stale = candidate("https://alpha-old.example.com/", visits: 10, ageDays: 120)
        // Deliberately fed in the wrong order, and matched the SAME way
        // (host prefix on both) so the only difference is age.
        XCTAssertEqual(
            rankedURLs([stale, fresh], query: "alpha"),
            [fresh.url.absoluteString, stale.url.absoluteString]
        )
    }

    /// Same recency, different frequency: frequency decides.
    func testSameRecencyDifferentFrequency() {
        let often = candidate("https://beta.example.com/", visits: 50, ageDays: 3)
        let once = candidate("https://beta-rare.example.com/", visits: 1, ageDays: 3)
        XCTAssertEqual(
            rankedURLs([once, often], query: "beta"),
            [often.url.absoluteString, once.url.absoluteString]
        )
    }

    /// Host prefix versus substring: where the query landed decides, when
    /// frecency cannot.
    func testHostPrefixBeatsHostSubstring() {
        let prefix = candidate("https://github.com/", visits: 5, ageDays: 2)
        let middle = candidate("https://mygithub.example.com/", visits: 5, ageDays: 2)
        XCTAssertEqual(
            rankedURLs([middle, prefix], query: "github"),
            [prefix.url.absoluteString, middle.url.absoluteString]
        )
    }

    /// The brief's exact phrasing: "a hit at the start of the host beats a hit
    /// in the middle of a query string".
    func testHostPrefixBeatsAHitInsideAQueryString() {
        let host = candidate("https://swift.org/", visits: 2, ageDays: 5)
        let inQuery = candidate("https://example.com/s?ref=swift&page=2", visits: 2, ageDays: 5)
        XCTAssertEqual(
            OmniboxRanking.matchKind(for: "swift", in: host), .hostPrefix
        )
        XCTAssertEqual(
            OmniboxRanking.matchKind(for: "swift", in: inQuery), .querySubstring
        )
        XCTAssertEqual(
            rankedURLs([inQuery, host], query: "swift"),
            [host.url.absoluteString, inQuery.url.absoluteString]
        )
    }

    /// A tie broken deterministically — and the same way every time, whatever
    /// order the store hands the rows back in.
    func testATieIsBrokenDeterministically() {
        // Identical in every ranked respect: same match kind, same visits,
        // same instant. Only the URL differs.
        let a = candidate("https://tie.example.com/a", title: "tie", visits: 4, ageDays: 7)
        let b = candidate("https://tie.example.com/b", title: "tie", visits: 4, ageDays: 7)
        let c = candidate("https://tie.example.com/c", title: "tie", visits: 4, ageDays: 7)

        let forward = rankedURLs([a, b, c], query: "tie.example.com")
        let backward = rankedURLs([c, b, a], query: "tie.example.com")
        let shuffled = rankedURLs([b, c, a], query: "tie.example.com")

        XCTAssertEqual(forward, backward)
        XCTAssertEqual(forward, shuffled)
        XCTAssertEqual(forward, [a, b, c].map(\.url.absoluteString),
                       "the documented tie-break is URL ascending")
    }

    // MARK: - The curve

    func testTheHalfLifeIsWhatTheCurveActuallyDoes() {
        let atHalfLife = OmniboxRanking.recencyWeight(
            lastVisit: days(OmniboxRanking.recencyHalfLifeDays), now: now
        )
        XCTAssertEqual(atHalfLife, 0.5, accuracy: 0.0001)

        let atTwoHalfLives = OmniboxRanking.recencyWeight(
            lastVisit: days(OmniboxRanking.recencyHalfLifeDays * 2), now: now
        )
        XCTAssertEqual(atTwoHalfLives, 0.25, accuracy: 0.0001)
    }

    func testAVisitHappeningNowWeighsOne() {
        XCTAssertEqual(OmniboxRanking.recencyWeight(lastVisit: now, now: now), 1.0)
    }

    /// A row timestamped in the future — clock skew, or an import from a
    /// browser with a different idea of time — must not outrank everything.
    func testAFutureTimestampIsClampedRatherThanRewarded() {
        let future = now.addingTimeInterval(86_400 * 30)
        XCTAssertEqual(OmniboxRanking.recencyWeight(lastVisit: future, now: now), 1.0)
    }

    func testTheCurveNeverReachesZeroSoAncientRowsStaySeparable() {
        let ancient = OmniboxRanking.recencyWeight(lastVisit: days(50_000), now: now)
        XCTAssertEqual(ancient, OmniboxRanking.recencyFloor)
        XCTAssertGreaterThan(ancient, 0)
    }

    /// The sentence the whole design is for: a site opened daily beats one
    /// opened forty times last year.
    func testADailySiteBeatsFortyVisitsLastYear() {
        let daily = candidate("https://daily.example.com/", visits: 300, ageDays: 0.5)
        let lastYear = candidate("https://lastyear.example.com/", visits: 40, ageDays: 365)
        XCTAssertEqual(
            rankedURLs([lastYear, daily], query: "example.com"),
            [daily.url.absoluteString, lastYear.url.absoluteString]
        )
    }

    /// Frequency is logarithmic, so a page hammered by a redirect loop cannot
    /// bury a page the user actually chose.
    func testFrequencyHasDiminishingReturns() {
        let one = OmniboxRanking.frequencyWeight(visitCount: 1)
        let ten = OmniboxRanking.frequencyWeight(visitCount: 10)
        let thousand = OmniboxRanking.frequencyWeight(visitCount: 1000)
        XCTAssertLessThan(ten - one, (thousand - ten) * 10)
        XCTAssertLessThan(thousand, one * 12)
    }

    func testAZeroVisitCountDoesNotProduceNaN() {
        let weight = OmniboxRanking.frequencyWeight(visitCount: 0)
        XCTAssertEqual(weight, 0)
        XCTAssertFalse(weight.isNaN)
    }

    // MARK: - Where the match landed

    func testTheMatchLadderIsOrderedBestFirst() {
        let weights = OmniboxMatchKind.allCases.map(\.weight)
        XCTAssertEqual(weights, weights.sorted(by: >),
                       "the ladder must decrease monotonically with the case order")
    }

    func testWWWIsIgnoredWhenDecidingAHostPrefix() {
        let apple = candidate("https://www.apple.com/mac", title: "Mac")
        XCTAssertEqual(OmniboxRanking.matchKind(for: "app", in: apple), .hostPrefix)
    }

    func testTheBestPlaceWins() {
        // "news" is in the host AND the title; the host answer is the one.
        let both = candidate("https://news.example.com/x", title: "news roundup")
        XCTAssertEqual(OmniboxRanking.matchKind(for: "news", in: both), .hostPrefix)
    }

    func testTitleMatchesAreFoundWhenTheHostHasNothing() {
        let page = candidate("https://example.com/1234", title: "Swift concurrency, explained")
        XCTAssertEqual(OmniboxRanking.matchKind(for: "swift", in: page), .titlePrefix)
        XCTAssertEqual(OmniboxRanking.matchKind(for: "concurrency", in: page), .titleSubstring)
    }

    func testPathMatchesAreFound() {
        let page = candidate("https://example.com/docs/networking", title: "Docs")
        XCTAssertEqual(OmniboxRanking.matchKind(for: "networking", in: page), .pathSubstring)
    }

    /// A query spanning host and path belongs to neither field alone; typing a
    /// URL out of history has to keep working.
    func testAQuerySpanningHostAndPathStillMatches() {
        let page = candidate("https://example.com/docs/networking", title: "Docs")
        XCTAssertNotNil(OmniboxRanking.matchKind(for: "example.com/docs", in: page))
    }

    func testANonMatchIsNil() {
        let page = candidate("https://example.com/docs", title: "Docs")
        XCTAssertNil(OmniboxRanking.matchKind(for: "kotlin", in: page))
    }

    func testAnEmptyQueryRanksNothing() {
        XCTAssertTrue(rankedURLs([candidate("https://example.com/")], query: "").isEmpty)
        XCTAssertTrue(rankedURLs([candidate("https://example.com/")], query: "   ").isEmpty)
    }

    func testMatchingIsCaseInsensitive() {
        let page = candidate("https://GitHub.com/Apple/Swift", title: "Apple/Swift")
        XCTAssertEqual(rankedURLs([page], query: "GITHUB").count, 1)
        XCTAssertEqual(rankedURLs([page], query: "github").count, 1)
    }

    // MARK: - Deduplication

    func testTheSamePageAppearsOnce() {
        // Trailing slash, missing slash, and a different scheme are one page.
        let rows = [
            candidate("https://example.com/docs", visits: 3, ageDays: 1),
            candidate("https://example.com/docs/", visits: 9, ageDays: 1),
            candidate("http://example.com/docs", visits: 1, ageDays: 40),
        ]
        let ranked = rankedURLs(rows, query: "example")
        XCTAssertEqual(ranked.count, 1)
        XCTAssertEqual(ranked.first, "https://example.com/docs/",
                       "the strongest row for the page is the one kept")
    }

    func testDifferentQueryStringsAreDifferentPages() {
        let rows = [
            candidate("https://example.com/s?q=swift", visits: 2),
            candidate("https://example.com/s?q=kotlin", visits: 2),
        ]
        XCTAssertEqual(rankedURLs(rows, query: "example.com").count, 2)
    }

    func testWhatTheUserHasAlreadyTypedIsNotOfferedBack() {
        let page = candidate("https://example.com/docs", visits: 5)
        XCTAssertTrue(rankedURLs([page], query: "https://example.com/docs").isEmpty)
    }

    // MARK: - The shape of the result

    func testTheLimitIsHonoured() {
        let rows = (0..<50).map { candidate("https://site\($0).example.com/", visits: $0 + 1) }
        XCTAssertEqual(rankedURLs(rows, query: "example", limit: 4).count, 4)
        XCTAssertTrue(rankedURLs(rows, query: "example", limit: 0).isEmpty)
    }

    func testTheResultIsSortedByScoreDescending() {
        let rows = (0..<20).map {
            candidate("https://site\($0).example.com/", visits: $0 + 1, ageDays: Double($0))
        }
        let scores = OmniboxRanking.rank(rows, query: "example", now: now, limit: 20).map(\.score)
        XCTAssertEqual(scores, scores.sorted(by: >))
    }

    func testNonMatchingRowsAreDropped() {
        let rows = [
            candidate("https://swift.org/", visits: 1),
            candidate("https://kotlinlang.org/", visits: 99),
        ]
        XCTAssertEqual(rankedURLs(rows, query: "swift"), ["https://swift.org/"])
    }

    /// `rank` keeps a bounded best-so-far rather than scoring every match and
    /// sorting, so this checks the bound does not change the answer: against a
    /// candidate set far larger than the buffer, it must return exactly what a
    /// brute-force score-everything-then-sort would.
    func testTheBoundedBufferReturnsTheSameTopRowsAsSortingEverything() {
        let rows = (0..<5_000).map { index in
            candidate(
                "https://site\(index).example.com/page",
                title: "example page \(index)",
                visits: (index * 7919) % 200 + 1,        // scattered, not monotonic
                ageDays: Double((index * 3571) % 400)
            )
        }

        // Scored and sorted with the same total order `rank` uses, so what is
        // being compared is the BOUND, not the tie-break. The fixture is full
        // of ties by construction, and "sort by score alone" would leave those
        // in whatever order the sort happened to produce.
        let bruteForce = rows
            .map { row -> RankedOmniboxCandidate in
                let kind = OmniboxRanking.matchKind(for: "example", in: row)!
                return RankedOmniboxCandidate(
                    candidate: row,
                    matchKind: kind,
                    score: OmniboxRanking.score(
                        visitCount: row.visitCount, lastVisit: row.lastVisit,
                        matchKind: kind, now: now
                    )
                )
            }
            .sorted(by: OmniboxRanking.isOrderedBefore)
            .prefix(8)
            .map(\.candidate.url.absoluteString)

        XCTAssertEqual(rankedURLs(rows, query: "example", limit: 8), Array(bruteForce))
    }

    /// The order is total: no two distinct rows can both claim to come first.
    func testTheOrderingIsAntisymmetric() {
        let rows = [
            candidate("https://a.example.com/", title: "example", visits: 4, ageDays: 7),
            candidate("https://b.example.com/", title: "example", visits: 4, ageDays: 7),
            candidate("https://c.example.com/", title: "example", visits: 9, ageDays: 1),
        ]
        let ranked = OmniboxRanking.rank(rows, query: "example", now: now, limit: 10)
        for lhs in ranked {
            for rhs in ranked where lhs != rhs {
                XCTAssertNotEqual(
                    OmniboxRanking.isOrderedBefore(lhs, rhs),
                    OmniboxRanking.isOrderedBefore(rhs, lhs),
                    "both rows claimed to precede the other"
                )
            }
        }
    }
}
