//
//  OmniboxHistoryCostTests.swift
//  Internet BrowserTests
//
//  What one keystroke in the address bar costs the main thread, measured
//  against 20,000 history rows.
//
//  This is a gate, not a note. `SearchSuggestService.fetch` calls
//  `matchHistory` synchronously and undebounced — deliberately, so history
//  matches appear the instant you type — so whatever this measures happens
//  between one keypress and the next, on the main actor, while the user is
//  typing. The plan's rule: under 50 ms it ships, over 50 ms it gets fixed
//  before merge.
//
//  Three numbers are printed, because the interesting thing is not the total
//  but where it went:
//
//   * `fold-per-call scan`   — the scan as it was written before this work,
//                              case-folding both fields of every row on every
//                              call and comparing with `String.contains`.
//                              Reproduced here rather than remembered, so the
//                              "before" number in the report is measured on
//                              the same machine, in the same run, against the
//                              same rows.
//   * `searchHistory`        — the same question, answered by a byte search
//                              over the fold `HistoryItem` now does once when
//                              the row is built (`OmniboxSearchText`).
//   * `rankedSuggestions`    — the whole omnibox path: that scan, plus
//                              deciding where each match landed, scoring it,
//                              deduplicating and sorting.
//
//  Runs against `PersistenceController(inMemory: true)`, so it neither reads
//  nor writes the developer's real history.
//

import XCTest
@testable import Cherry

@MainActor
final class OmniboxHistoryCostTests: XCTestCase {

    /// The plan's threshold for the whole main-actor cost of one keystroke.
    private static let budgetSeconds = 0.050

    /// The plan's floor.
    private static let rowCount = 20_000

    /// Built once: inserting the rows costs far more than the scans being
    /// measured, and it is not what is under test.
    private static let repository = makeRepository(rows: rowCount)

    /// Shaped like the `MCPHistorySearchCostTests` fixture so the two
    /// measurements are comparable: 977 distinct hosts, a unique path per row,
    /// and a term that matches a fifth of them.
    private static func makeRepository(rows: Int) -> HistoryRepository {
        let store = PersistenceController(inMemory: true)
        let context = store.viewContext
        let now = Date()
        for index in 0..<rows {
            let entity = HistoryEntity(context: context)
            entity.id = UUID()
            entity.url = "https://host\(index % 977).example.com/section-\(index)/page?q=\(index)"
            entity.title = "Article \(index) — \(["Swift", "Kotlin", "Rust", "Zig", "Elm"][index % 5]) notes"
            entity.visitDate = now.addingTimeInterval(-Double(index) * 37)
            entity.visitCount = Int32(index % 9 + 1)
        }
        try? context.save()
        return HistoryRepository(persistence: store)
    }

    /// Fastest of `attempts`, which is the number that reflects the code rather
    /// than whatever else the machine was doing.
    private func fastest(_ attempts: Int = 5, _ body: () -> Void) -> TimeInterval {
        var best = TimeInterval.greatestFiniteMagnitude
        for _ in 0..<attempts {
            let started = CFAbsoluteTimeGetCurrent()
            body()
            best = min(best, CFAbsoluteTimeGetCurrent() - started)
        }
        return best
    }

    func testTwentyThousandRowsAreLoadedForTheMeasurement() {
        XCTAssertEqual(
            Self.repository.historyItems.count, Self.rowCount,
            "the fixture did not load, so any timing below is meaningless"
        )
    }

    /// The number that goes in the report.
    func testOneKeystrokeOverTwentyThousandRowsStaysUnderTheBudget() {
        let repository = Self.repository
        let items = repository.historyItems

        // The scan exactly as it read before this work: `lowercased()` on both
        // fields of every row, every call.
        let foldPerCall = fastest {
            let query = "swift"
            _ = items.filter { item in
                item.title.lowercased().contains(query) ||
                item.url.absoluteString.lowercased().contains(query)
            }
        }

        var matches: [HistoryItem] = []
        let scan = fastest {
            matches = repository.searchHistory(query: "swift")
        }

        var ranked: [RankedOmniboxCandidate] = []
        let whole = fastest {
            ranked = repository.rankedSuggestions(query: "swift", limit: 4)
        }

        XCTAssertEqual(matches.count, Self.rowCount / 5, "the fixture stopped matching")
        XCTAssertEqual(ranked.count, 4)

        print("""
            [omnibox] over \(Self.rowCount) rows, one keystroke matching \
            \(matches.count) of them:
            [omnibox]   fold-per-call scan (was): \(Self.ms(foldPerCall))
            [omnibox]   searchHistory      (now): \(Self.ms(scan))
            [omnibox]   rankedSuggestions  (now): \(Self.ms(whole)) \
            — budget \(Int(Self.budgetSeconds * 1000)) ms
            """)

        XCTAssertLessThan(
            whole, Self.budgetSeconds,
            "one keystroke took \(Self.ms(whole)) on the main actor over \(Self.rowCount) rows. "
                + "Over \(Int(Self.budgetSeconds * 1000)) ms this needs an NSFetchRequest "
                + "predicate path instead of scanning historyItems."
        )
    }

    /// The worst realistic case for the scan: a query that matches nothing
    /// still touches every row, and pays none of the ranking.
    func testAQueryThatMatchesNothingAlsoStaysUnderTheBudget() {
        let repository = Self.repository
        var ranked: [RankedOmniboxCandidate] = []
        let elapsed = fastest {
            ranked = repository.rankedSuggestions(query: "zzzz-no-such-term", limit: 4)
        }
        XCTAssertTrue(ranked.isEmpty)
        print("[omnibox] miss over \(Self.rowCount) rows: \(Self.ms(elapsed))")
        XCTAssertLessThan(elapsed, Self.budgetSeconds)
    }

    /// The pathological shape for the RANKING half rather than the scan: a
    /// query that matches almost every row, so a candidate is built and scored
    /// for nearly all 20,000.
    func testAQueryThatMatchesAlmostEveryRowStaysUnderTheBudget() {
        let repository = Self.repository
        var ranked: [RankedOmniboxCandidate] = []
        let elapsed = fastest(3) {
            ranked = repository.rankedSuggestions(query: "example.com", limit: 4)
        }
        XCTAssertEqual(ranked.count, 4)
        print("[omnibox] near-total match over \(Self.rowCount) rows: \(Self.ms(elapsed))")
        XCTAssertLessThan(elapsed, Self.budgetSeconds)
    }

    /// Ranking has to be worth what it costs, so this checks the order actually
    /// changed. `searchHistory` returns `historyItems` order — most recently
    /// visited first — which is what the omnibox used to show. The fixture's
    /// newest matching row (`section-0`) has one visit; a slightly older one
    /// has nine, and frecency should prefer it.
    func testTheRankedListIsOrderedRatherThanWhateverTheStoreReturned() {
        let unranked = Self.repository.searchHistory(query: "swift")
        let ranked = Self.repository.rankedSuggestions(query: "swift", limit: 4)

        let scores = ranked.map(\.score)
        XCTAssertEqual(scores, scores.sorted(by: >))

        XCTAssertEqual(unranked.first?.visitCount, 1, "the fixture changed shape")
        XCTAssertNotEqual(
            ranked.first?.candidate.url, unranked.first?.url,
            "ranking returned the same first row the unranked scan did"
        )
        XCTAssertEqual(
            ranked.first?.candidate.visitCount, 9,
            "a recent row visited nine times should lead a recent row visited once"
        )
    }

    private static func ms(_ seconds: TimeInterval) -> String {
        String(format: "%.2f ms", seconds * 1000)
    }
}
