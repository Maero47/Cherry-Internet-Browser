//
//  TextChunkerTests.swift
//  Internet BrowserTests
//

import XCTest
@testable import Cherry

final class TextChunkerTests: XCTestCase {

    /// A paragraph of distinct, numbered sentences so tests can tell exactly
    /// which sentences landed in which chunk.
    private func numberedSentences(_ count: Int) -> String {
        (1...count).map { "This is sentence number \($0) of the test document." }.joined(separator: " ")
    }

    // MARK: - sentenceUnits

    func testSentenceUnitsSplitAfterTerminatorAndWhitespace() {
        let units = TextChunker.sentenceUnits("First sentence. Second one! Third?")
        XCTAssertEqual(units, ["First sentence. ", "Second one! ", "Third?"])
    }

    func testSentenceUnitsConcatenateBackToOriginalText() {
        let text = "Heading\nA sentence with 3.14 in it. Another!  And a trailing fragment"
        XCTAssertEqual(TextChunker.sentenceUnits(text).joined(), text)
    }

    func testSentenceUnitsDoNotSplitInsideDecimals() {
        let units = TextChunker.sentenceUnits("Pi is 3.14159 exactly. Next sentence.")
        XCTAssertEqual(units.first, "Pi is 3.14159 exactly. ")
    }

    func testSentenceUnitsTreatNewlinesAsBoundaries() {
        let units = TextChunker.sentenceUnits("A heading\nBody line one\nBody line two")
        XCTAssertEqual(units, ["A heading\n", "Body line one\n", "Body line two"])
    }

    // MARK: - retrievalChunks

    func testShortTextIsOneChunkAndEmptyTextIsNone() {
        XCTAssertEqual(TextChunker.retrievalChunks("Short text.", targetChars: 700, overlapChars: 100), ["Short text."])
        XCTAssertEqual(TextChunker.retrievalChunks("", targetChars: 700, overlapChars: 100), [])
    }

    func testLongTextSplitsIntoMultipleChunksWithinBudget() {
        let text = numberedSentences(60)
        let chunks = TextChunker.retrievalChunks(text, targetChars: 700, overlapChars: 100)
        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.count, 700 + 100, "no chunk may exceed target plus carried overlap")
        }
    }

    func testAdjacentChunksOverlap() {
        let text = numberedSentences(60)
        let chunks = TextChunker.retrievalChunks(text, targetChars: 700, overlapChars: 100)
        for (previous, next) in zip(chunks, chunks.dropFirst()) {
            // The next chunk must START with the tail of the previous one:
            // its first sentence appears near the end of the previous chunk.
            let firstUnit = TextChunker.sentenceUnits(next).first!.trimmingCharacters(in: .whitespaces)
            XCTAssertTrue(
                previous.hasSuffix(firstUnit) || previous.contains(firstUnit),
                "chunk starting with \"\(firstUnit.prefix(40))…\" should share its opening with the previous chunk's tail"
            )
        }
    }

    func testChunksBreakOnSentenceBoundariesNotMidWord() {
        let text = numberedSentences(60)
        let chunks = TextChunker.retrievalChunks(text, targetChars: 700, overlapChars: 100)
        for chunk in chunks {
            XCTAssertTrue(chunk.hasSuffix("."), "with sentence-sized input every chunk should end at a sentence boundary")
        }
    }

    func testEverySentenceSurvivesChunkingIntact() {
        let count = 40
        let text = numberedSentences(count)
        let chunks = TextChunker.retrievalChunks(text, targetChars: 700, overlapChars: 100)
        for n in 1...count {
            let sentence = "This is sentence number \(n) of the test document."
            XCTAssertTrue(chunks.contains { $0.contains(sentence) }, "sentence \(n) must appear whole in at least one chunk")
        }
    }

    func testPathologicalUnbrokenTextFallsBackToHardSplitting() {
        let text = String(repeating: "x", count: 3000)
        let chunks = TextChunker.retrievalChunks(text, targetChars: 700, overlapChars: 100)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.map(\.count).max().map { $0 <= 800 }, true)
        XCTAssertEqual(chunks.joined().count, 3000, "hard-split pieces have no sentence overlap to carry, so nothing duplicates")
    }

    func testOverlapZeroProducesDisjointChunks() {
        let text = numberedSentences(60)
        let chunks = TextChunker.retrievalChunks(text, targetChars: 700, overlapChars: 0)
        XCTAssertEqual(
            chunks.map { $0.count }.reduce(0, +),
            chunks.joined().count
        )
        // Without overlap, concatenated chunks reproduce the text (modulo
        // the whitespace trimmed at each chunk edge).
        let rejoined = chunks.joined(separator: " ")
        XCTAssertEqual(rejoined, text)
    }
}
