//
//  MCPHistorySearchCostTests.swift
//  Internet BrowserTests
//
//  The performance gate on `search_history`, and it is a gate rather than a note.
//
//  `HistoryRepository.fetchHistory()` loads the WHOLE history into memory
//  unbounded, and `searchHistory(query:)` linearly scans that array — on the main
//  actor, because the repository is main-actor-isolated by construction. So every
//  `search_history` call an external client makes is an O(n) main-thread stall in
//  the middle of the user's browsing. `n` is however many pages they have ever
//  visited.
//
//  The plan's rule: measured against ≥20,000 rows, under 50 ms it ships as it is;
//  over 50 ms it gets an `NSFetchRequest` predicate path before merge. This test
//  is the measurement, kept in the suite so the answer cannot quietly rot — the
//  budget below fails the build rather than printing a number nobody reads.
//
//  It runs against `PersistenceController(inMemory: true)`, so it neither reads
//  nor writes the developer's real history.
//

import XCTest
@testable import Cherry

@MainActor
final class MCPHistorySearchCostTests: XCTestCase {

    /// The plan's threshold. A main-thread scan slower than this is a UI hitch on
    /// every tool call, and the fix is a fetch-request predicate.
    private static let budgetSeconds = 0.050

    /// Above the plan's 20,000 floor.
    private static let rowCount = 20_000

    /// A quarter of the full fixture, for the linearity check below.
    private static let quarterRowCount = rowCount / 4

    /// Built once each: inserting the rows costs far more than the scan being
    /// measured, and it is not what is under test.
    private static let repository = makeRepository(rows: rowCount)
    private static let quarterRepository = makeRepository(rows: quarterRowCount)

    private static func makeRepository(rows: Int) -> HistoryRepository {
        let store = PersistenceController(inMemory: true)
        let context = store.viewContext
        let now = Date()
        // Varied enough that the scan cannot short-circuit on a shared prefix, and
        // shaped like real history: most rows are noise, a fifth match.
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

    private func bridge(over history: HistoryRepository) -> MCPBrowserBridge {
        MCPBrowserBridge(
            registeredViewModels: { [] },
            history: history,
            bookmarks: MCPRepositoryFixture.emptyBookmarks
        )
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
    ///
    /// Measures the tool's whole main-actor cost — `searchHistory` plus the
    /// `since_days` filter, the sort and the projection to DTOs — not just the
    /// repository call, because all of it holds the main actor for the duration of
    /// one `search_history`.
    func testSearchHistoryOverTwentyThousandRowsStaysUnderTheBudget() throws {
        let bridge = bridge(over: Self.repository)

        // A term that matches a fifth of the rows — the expensive shape, since
        // every match is also sorted and projected.
        var payload: MCPSearchHistoryPayload?
        let elapsed = fastest {
            payload = bridge.searchHistory(query: "swift", limit: 100, sinceDays: nil)
        }
        XCTAssertEqual(payload?.returned, 100, "the fixture stopped matching")
        XCTAssertEqual(payload?.totalMatches, Self.rowCount / 5)

        print("[MCP] search_history hit over \(Self.rowCount) rows: "
              + "\(String(format: "%.2f", elapsed * 1000)) ms "
              + "(budget \(Int(Self.budgetSeconds * 1000)) ms)")

        XCTAssertLessThan(
            elapsed, Self.budgetSeconds,
            "search_history took \(String(format: "%.1f", elapsed * 1000)) ms on the main actor over "
                + "\(Self.rowCount) rows. Over \(Int(Self.budgetSeconds * 1000)) ms this needs an "
                + "NSFetchRequest predicate path instead of scanning historyItems."
        )
    }

    /// The worst realistic case: a query that matches nothing still touches every
    /// row, so it is the pure scan with none of the projection.
    func testAQueryThatMatchesNothingAlsoStaysUnderTheBudget() {
        let bridge = bridge(over: Self.repository)

        var payload: MCPSearchHistoryPayload?
        let elapsed = fastest {
            payload = bridge.searchHistory(query: "zzzz-no-such-term", limit: 25, sinceDays: nil)
        }

        XCTAssertEqual(payload?.totalMatches, 0)
        print("[MCP] search_history miss over \(Self.rowCount) rows: "
              + "\(String(format: "%.2f", elapsed * 1000)) ms")
        XCTAssertLessThan(elapsed, Self.budgetSeconds)
    }

    /// The cost is linear in history size, which is what makes the 20,000-row
    /// number above an extrapolation point rather than a fact about one machine:
    /// a user with twice the history pays twice the main-thread stall.
    ///
    /// This is measured rather than assumed because it is the whole argument for
    /// why the budget matters — the scan `lowercased()`s both fields of every row,
    /// so there is no constant-factor escape as histories grow.
    func testTheScanCostGrowsWithTheHistory() {
        let quarter = fastest {
            _ = bridge(over: Self.quarterRepository)
                .searchHistory(query: "zzzz-no-such-term", limit: 25, sinceDays: nil)
        }
        let full = fastest {
            _ = bridge(over: Self.repository)
                .searchHistory(query: "zzzz-no-such-term", limit: 25, sinceDays: nil)
        }

        let perRowMicroseconds = full * 1_000_000 / Double(Self.rowCount)
        let rowsAtBudget = Int(Self.budgetSeconds / (full / Double(Self.rowCount)))
        print("""
            [MCP] scan scaling: \(Self.quarterRowCount) rows \
            \(String(format: "%.2f", quarter * 1000)) ms → \(Self.rowCount) rows \
            \(String(format: "%.2f", full * 1000)) ms \
            (\(String(format: "%.2f", perRowMicroseconds)) µs/row; \
            crosses the \(Int(Self.budgetSeconds * 1000)) ms budget at ~\(rowsAtBudget) rows)
            """)

        // Loose bounds: this asserts "roughly proportional", not a benchmark. It
        // exists so a change that made the scan super-linear would be caught.
        let ratio = full / quarter
        XCTAssertGreaterThan(ratio, 2.0, "the scan did not grow with the history at all")
        XCTAssertLessThan(ratio, 8.0, "4× the rows cost more than 8× the time — the scan is not linear")
    }
}
