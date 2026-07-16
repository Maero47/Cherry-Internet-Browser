//
//  WebAgentIndexBudgetTests.swift
//  Internet BrowserTests
//

import XCTest
@testable import Cherry

final class WebAgentIndexBudgetTests: XCTestCase {

    func testTextWithinLimitIsUntouched() {
        XCTAssertEqual(WebAgentIndexBudget.cappedText("short text", limit: 100), "short text")
        let exact = String(repeating: "a", count: 10)
        XCTAssertEqual(WebAgentIndexBudget.cappedText(exact, limit: 10), exact)
    }

    func testEmptyTextStaysEmpty() {
        XCTAssertEqual(WebAgentIndexBudget.cappedText("", limit: 100), "")
    }

    func testCapCutsAtAWordBoundaryWithinTheLimit() {
        let text = "alpha beta gamma delta"
        let capped = WebAgentIndexBudget.cappedText(text, limit: 13) // "alpha beta ga"
        XCTAssertEqual(capped, "alpha beta")
        XCTAssertLessThanOrEqual(capped.count, 13)
    }

    func testCapNeverSplitsAWordMidway() {
        let words = (1...100).map { "word\($0)" }
        let text = words.joined(separator: " ")
        let capped = WebAgentIndexBudget.cappedText(text, limit: 50)
        XCTAssertLessThanOrEqual(capped.count, 50)
        // Every emitted word must be one of the originals, whole.
        for word in capped.split(separator: " ") {
            XCTAssertTrue(words.contains(String(word)), "split word: \(word)")
        }
    }

    func testCapDropsTrailingWhitespaceRuns() {
        let capped = WebAgentIndexBudget.cappedText("alpha beta  \n\n gamma-is-long", limit: 18)
        XCTAssertEqual(capped, "alpha beta")
    }

    func testUnbrokenTokenFallsBackToTheRawWindow() {
        let text = String(repeating: "x", count: 100)
        let capped = WebAgentIndexBudget.cappedText(text, limit: 10)
        XCTAssertEqual(capped, String(repeating: "x", count: 10))
    }

    func testNonPositiveLimitYieldsEmpty() {
        XCTAssertEqual(WebAgentIndexBudget.cappedText("anything", limit: 0), "")
    }

    func testDefaultLimitBoundsTheEmbedWorkToAFewChunksPerTab() {
        // The agent's responsiveness rests on these staying in the same
        // ballpark: the per-tab budget is a couple of dozen chunks at most,
        // and the whole index build is hard-bounded under half a minute.
        XCTAssertLessThanOrEqual(WebAgentIndexBudget.perTabIndexCharacterLimit, 12_000)
        XCTAssertGreaterThanOrEqual(WebAgentIndexBudget.perTabIndexCharacterLimit, 4_000)
        XCTAssertLessThanOrEqual(WebAgentIndexBudget.prepareTimeout, .seconds(25))

        let page = String(repeating: "lorem ipsum dolor sit amet consectetur ", count: 2_000)
        let capped = WebAgentIndexBudget.cappedText(page)
        XCTAssertLessThanOrEqual(capped.count, WebAgentIndexBudget.perTabIndexCharacterLimit)
        let chunks = TextChunker.retrievalChunks(
            capped,
            targetChars: TabsResearchService.chunkTargetChars,
            overlapChars: TabsResearchService.chunkOverlapChars
        )
        XCTAssertLessThanOrEqual(chunks.count, 25)
        XCTAssertGreaterThan(chunks.count, 1)
    }
}
