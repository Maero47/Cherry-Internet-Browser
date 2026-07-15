//
//  ReasoningSplitterTests.swift
//  Internet BrowserTests
//

import XCTest
@testable import Cherry

final class ReasoningSplitterTests: XCTestCase {

    // MARK: - No tag (Apple FM path / plain replies)

    func testPlainTextWithoutThinkTagPassesThroughUntouched() {
        let result = ReasoningSplitter.split("The answer is 42.")
        XCTAssertNil(result.reasoning)
        XCTAssertEqual(result.answer, "The answer is 42.")
    }

    func testEmptyStringPassesThroughUntouched() {
        let result = ReasoningSplitter.split("")
        XCTAssertNil(result.reasoning)
        XCTAssertEqual(result.answer, "")
    }

    /// A partially-arrived open tag must NOT be treated as reasoning — the
    /// literal match simply doesn't fire until the tag is complete. The
    /// partial tag text leaks into the answer for one snapshot, and the next
    /// cumulative snapshot (with the completed tag) reclassifies it.
    func testPartialOpenTagIsNotMatched() {
        let result = ReasoningSplitter.split("<thin")
        XCTAssertNil(result.reasoning)
        XCTAssertEqual(result.answer, "<thin")
    }

    // MARK: - Open tag only (mid-stream, still thinking)

    func testOpenTagOnlyYieldsReasoningAndEmptyAnswer() {
        let result = ReasoningSplitter.split("<think>Let me consider the page…")
        XCTAssertEqual(result.reasoning, "Let me consider the page…")
        XCTAssertEqual(result.answer, "")
    }

    func testOpenTagWithNothingAfterYieldsEmptyNonNilReasoning() {
        let result = ReasoningSplitter.split("<think>")
        XCTAssertEqual(result.reasoning, "")
        XCTAssertEqual(result.answer, "")
    }

    /// A partial CLOSE tag mid-stream stays inside the reasoning (trimmed) —
    /// it must not split the answer early.
    func testPartialCloseTagStaysInsideReasoning() {
        let result = ReasoningSplitter.split("<think>reasoning here</thi")
        XCTAssertEqual(result.reasoning, "reasoning here</thi")
        XCTAssertEqual(result.answer, "")
    }

    // MARK: - Both tags (thinking finished)

    func testClosedThinkBlockSplitsReasoningFromAnswer() {
        let result = ReasoningSplitter.split("<think>The user wants a summary.</think>\n\nHere is the summary.")
        XCTAssertEqual(result.reasoning, "The user wants a summary.")
        XCTAssertEqual(result.answer, "Here is the summary.")
    }

    func testReasoningAndAnswerWhitespaceIsTrimmed() {
        let result = ReasoningSplitter.split("  \n<think>\n  thoughts  \n</think>\n   answer")
        XCTAssertEqual(result.reasoning, "thoughts")
        XCTAssertEqual(result.answer, "answer")
    }

    /// Only the answer's LEADING whitespace is trimmed: a cumulative snapshot
    /// can legitimately end mid-sentence with trailing whitespace that the
    /// next snapshot extends.
    func testAnswerTrailingWhitespaceIsPreserved() {
        let result = ReasoningSplitter.split("<think>t</think>The answer so far ")
        XCTAssertEqual(result.answer, "The answer so far ")
    }

    func testEmptyReasoningBlockYieldsEmptyNonNilReasoning() {
        let result = ReasoningSplitter.split("<think></think>Answer.")
        XCTAssertEqual(result.reasoning, "")
        XCTAssertEqual(result.answer, "Answer.")
    }

    func testCaseInsensitiveTagsAreMatched() {
        let result = ReasoningSplitter.split("<THINK>upper</THINK>Answer.")
        XCTAssertEqual(result.reasoning, "upper")
        XCTAssertEqual(result.answer, "Answer.")
    }

    // MARK: - Text before the open tag

    func testTextBeforeOpenTagIsTreatedAsAnswerMidStream() {
        let result = ReasoningSplitter.split("Preamble <think>still thinking")
        XCTAssertEqual(result.reasoning, "still thinking")
        XCTAssertEqual(result.answer, "Preamble")
    }

    func testTextBeforeOpenTagIsKeptInAnswerWhenClosed() {
        let result = ReasoningSplitter.split("Preamble <think>thoughts</think> The rest.")
        XCTAssertEqual(result.reasoning, "thoughts")
        XCTAssertEqual(result.answer, "Preamble\nThe rest.")
    }

    func testTextBeforeOpenTagAloneBecomesAnswerWhenBlockClosedEmptyTail() {
        let result = ReasoningSplitter.split("Preamble <think>thoughts</think>")
        XCTAssertEqual(result.reasoning, "thoughts")
        XCTAssertEqual(result.answer, "Preamble")
    }

    // MARK: - Cumulative streaming sequence

    /// Simulates the real streaming shape: each snapshot is the previous one
    /// plus more text, and the split must move monotonically from
    /// "thinking" to "answering" without regressing.
    func testCumulativeSnapshotsProgressFromThinkingToAnswer() {
        let snapshots = [
            "<think>",
            "<think>Considering",
            "<think>Considering the page.",
            "<think>Considering the page.</think>",
            "<think>Considering the page.</think>\nThe page says",
            "<think>Considering the page.</think>\nThe page says X.",
        ]
        let results = snapshots.map { ReasoningSplitter.split($0) }

        XCTAssertEqual(results[0].reasoning, "")
        XCTAssertEqual(results[0].answer, "")
        XCTAssertEqual(results[2].reasoning, "Considering the page.")
        XCTAssertEqual(results[2].answer, "")
        XCTAssertEqual(results[3].answer, "")
        XCTAssertEqual(results[4].answer, "The page says")
        XCTAssertEqual(results[5].reasoning, "Considering the page.")
        XCTAssertEqual(results[5].answer, "The page says X.")
    }
}
