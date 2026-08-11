//
//  OmniboxRealHistoryTests.swift
//  Internet BrowserTests
//
//  Prints what the omnibox used to show and what it shows now, for the same
//  queries, against the REAL history on this machine.
//
//  The unit tests next door pin the ranking against fixtures, which proves the
//  function is what it claims to be. They cannot show whether it improves the
//  address bar, because that depends on the shape of somebody's actual
//  browsing. This does: it runs both orders side by side and prints them.
//
//  Read-only. It opens `HistoryRepository.shared` — the test host IS the app
//  bundle, so that is the user's real store — and calls two query methods.
//  Nothing here writes, deletes or reorders anything.
//
//  Opt-in, and off by default for exactly that reason: an ordinary test run
//  must not print somebody's browsing history into a build log.
//
//      TEST_RUNNER_CHERRY_REAL_HISTORY=1 xcodebuild test \
//        -scheme "Internet Browser" -destination 'platform=macOS' \
//        -only-testing:"Internet BrowserTests/OmniboxRealHistoryTests"
//
//  `CHERRY_REAL_HISTORY_QUERIES` overrides the queries (comma separated).
//

import XCTest
@testable import Cherry

@MainActor
final class OmniboxRealHistoryTests: XCTestCase {

    private var queries: [String] = []

    override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        let enabled = environment["CHERRY_REAL_HISTORY"]
            ?? environment["TEST_RUNNER_CHERRY_REAL_HISTORY"]
        try XCTSkipIf(enabled == nil, "reading the real history is opt-in")

        let raw = environment["CHERRY_REAL_HISTORY_QUERIES"]
            ?? environment["TEST_RUNNER_CHERRY_REAL_HISTORY_QUERIES"]
        queries = (raw ?? "git,goog,you,app,claude,swift")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func testPrintTheOrderBeforeAndAfterOnThisMachinesHistory() throws {
        let repository = HistoryRepository.shared
        let rows = repository.historyItems
        print("[real] history rows on this machine: \(rows.count)")
        try XCTSkipIf(rows.isEmpty, "no history on this machine to rank")

        for query in queries {
            // What shipped: `searchHistory` order — `historyItems` order, which
            // is most-recently-visited-anything first — deduplicated by exact
            // URL, first four kept.
            var seen = Set<String>()
            var before: [HistoryItem] = []
            for item in repository.searchHistory(query: query) {
                guard seen.insert(item.url.absoluteString.lowercased()).inserted else { continue }
                before.append(item)
                if before.count == 4 { break }
            }

            let after = repository.rankedSuggestions(query: query, limit: 4)

            print("\n[real] query \"\(query)\" — \(repository.searchHistory(query: query).count) matching rows")
            print("[real]   before (repository order):")
            for (index, item) in before.enumerated() {
                print("[real]     \(index + 1). \(Self.describe(item))")
            }
            print("[real]   after (frecency):")
            for (index, ranked) in after.enumerated() {
                print("[real]     \(index + 1). \(Self.describe(ranked))")
            }
            if before.isEmpty && after.isEmpty {
                print("[real]     (no matches)")
            }
        }
    }

    private static func describe(_ item: HistoryItem) -> String {
        "\(item.url.absoluteString) — \(item.visitCount)× , last \(age(item.visitDate))"
    }

    private static func describe(_ ranked: RankedOmniboxCandidate) -> String {
        let candidate = ranked.candidate
        return "\(candidate.url.absoluteString) — \(candidate.visitCount)×, "
            + "last \(age(candidate.lastVisit)), "
            + "\(ranked.matchKind), score \(String(format: "%.3f", ranked.score))"
    }

    private static func age(_ date: Date) -> String {
        let days = Date().timeIntervalSince(date) / 86_400
        if days < 1 { return String(format: "%.1f h ago", days * 24) }
        return String(format: "%.1f d ago", days)
    }
}
