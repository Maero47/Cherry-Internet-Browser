//
//  RetrievalMathTests.swift
//  Internet BrowserTests
//

import XCTest
@testable import Cherry

final class RetrievalMathTests: XCTestCase {

    func testCosineSimilarityOfIdenticalVectorsIsOne() {
        let vector: [Float] = [1, 2, 3, 4]
        XCTAssertEqual(RetrievalMath.cosineSimilarity(vector, vector), 1, accuracy: 0.0001)
    }

    func testCosineSimilarityOfOrthogonalVectorsIsZero() {
        let a: [Float] = [1, 0]
        let b: [Float] = [0, 1]
        XCTAssertEqual(RetrievalMath.cosineSimilarity(a, b), 0, accuracy: 0.0001)
    }

    func testCosineSimilarityOfOppositeVectorsIsNegativeOne() {
        let a: [Float] = [1, 2, 3]
        let b: [Float] = [-1, -2, -3]
        XCTAssertEqual(RetrievalMath.cosineSimilarity(a, b), -1, accuracy: 0.0001)
    }

    func testCosineSimilarityIsScaleInvariant() {
        let a: [Float] = [1, 2, 3]
        let scaled: [Float] = [10, 20, 30]
        XCTAssertEqual(RetrievalMath.cosineSimilarity(a, scaled), 1, accuracy: 0.0001)
    }

    func testCosineSimilarityHandlesZeroVectorWithoutDivideByZero() {
        let zero: [Float] = [0, 0, 0]
        let other: [Float] = [1, 2, 3]
        XCTAssertEqual(RetrievalMath.cosineSimilarity(zero, other), 0)
    }

    func testMeanPoolAveragesPerDimension() {
        let vectors: [[Double]] = [[1, 2, 3], [3, 4, 5]]
        let pooled = RetrievalMath.meanPool(vectors)
        XCTAssertEqual(pooled, [2, 3, 4])
    }

    func testMeanPoolOfEmptySequenceIsEmpty() {
        XCTAssertEqual(RetrievalMath.meanPool([]), [])
    }

    /// A mismatched-width vector must be excluded from BOTH the sum and the
    /// denominator — dividing by the total input count (including the
    /// skipped vector) would silently understate the mean.
    func testMeanPoolExcludesMismatchedWidthVectorsFromDenominator() {
        let vectors: [[Double]] = [[1, 2, 3], [10, 20], [3, 4, 5]]
        let pooled = RetrievalMath.meanPool(vectors)
        XCTAssertEqual(pooled, [2, 3, 4], "should average only the two width-3 vectors, not divide by 3")
    }

    /// The core promise of retrieval: given a page's chunk embeddings and a
    /// query embedding, the chunk that's actually closest to the query
    /// (in this synthetic space, the one sharing its dominant direction)
    /// ranks first — and chunks are returned in original document order once
    /// the top-K is selected by the caller, not similarity order.
    func testRankIndicesOrdersMostSimilarChunkFirst() {
        // Chunk 0 is about "cats", chunk 1 about "cars", chunk 2 about "dogs" —
        // encoded as simple orthogonal-ish directions in a toy embedding space.
        let catsChunk: [Float] = [1, 0, 0]
        let carsChunk: [Float] = [0, 1, 0]
        let dogsChunk: [Float] = [0.9, 0, 0.1]

        let chunkEmbeddings = [catsChunk, carsChunk, dogsChunk]
        let query: [Float] = [1, 0, 0] // "cats"-like query

        let ranked = RetrievalMath.rankIndices(chunkEmbeddings: chunkEmbeddings, query: query)

        XCTAssertEqual(ranked.first, 0, "the cats chunk should rank most similar to a cats query")
        XCTAssertEqual(ranked.last, 1, "the unrelated cars chunk should rank least similar")
    }

    func testRankIndicesReturnsAllIndicesExactlyOnce() {
        let chunkEmbeddings: [[Float]] = [[1, 0], [0, 1], [1, 1], [-1, 0]]
        let query: [Float] = [1, 0]
        let ranked = RetrievalMath.rankIndices(chunkEmbeddings: chunkEmbeddings, query: query)
        XCTAssertEqual(Set(ranked), Set(0..<chunkEmbeddings.count))
        XCTAssertEqual(ranked.count, chunkEmbeddings.count)
    }

    /// Mirrors how `PageRetriever.retrieve` re-sorts a similarity-ranked
    /// top-K back into original document order for readability.
    func testTopKFilteredBackIntoDocumentOrderIsReadable() {
        let chunkEmbeddings: [[Float]] = [[0, 1], [1, 0], [0.9, 0.1], [0, -1]]
        let query: [Float] = [1, 0]
        let ranked = RetrievalMath.rankIndices(chunkEmbeddings: chunkEmbeddings, query: query)
        let topIndices = Set(ranked.prefix(2))

        let documentOrderTopK = chunkEmbeddings.indices.filter { topIndices.contains($0) }

        XCTAssertEqual(documentOrderTopK, [1, 2], "chunks 1 and 2 are the closest matches and should stay in reading order")
    }

    // MARK: - tokenize

    func testTokenizeLowercasesAndSplitsOnPunctuation() {
        XCTAssertEqual(
            RetrievalMath.tokenize("The XPS-13 weighs 1.2 kg, per Dell's spec sheet!"),
            ["the", "xps", "13", "weighs", "1", "2", "kg", "per", "dell", "s", "spec", "sheet"]
        )
    }

    func testTokenizeKeepsUnicodeLettersAndDigitsWhole() {
        XCTAssertEqual(
            RetrievalMath.tokenize("Türkçe ödeme: 42 TL"),
            ["türkçe", "ödeme", "42", "tl"]
        )
    }

    func testTokenizeOfEmptyOrPunctuationOnlyTextIsEmpty() {
        XCTAssertEqual(RetrievalMath.tokenize(""), [])
        XCTAssertEqual(RetrievalMath.tokenize("… — !!! ??? ,,,"), [])
    }

    func testTokenizeIsDeterministic() {
        let text = "Same input, same tokens — every time."
        XCTAssertEqual(RetrievalMath.tokenize(text), RetrievalMath.tokenize(text))
    }

    // MARK: - BM25

    private func corpus(_ documents: [String]) -> [[String]] {
        documents.map(RetrievalMath.tokenize)
    }

    func testBM25ScoresDocumentContainingQueryTermHighest() {
        let index = BM25Index(corpus: corpus([
            "cats are small pets",
            "cars need fuel and roads",
            "dogs are loyal pets",
        ]))
        let scores = index.scores(query: RetrievalMath.tokenize("cars"))
        XCTAssertEqual(scores.count, 3)
        XCTAssertGreaterThan(scores[1], scores[0])
        XCTAssertGreaterThan(scores[1], scores[2])
        XCTAssertEqual(scores[0], 0, "no query term appears in the cats document")
    }

    func testBM25RareTermOutweighsCommonTerm() {
        // "pets" appears in every document (near-zero IDF); "ferret" in one.
        let index = BM25Index(corpus: corpus([
            "cats are pets",
            "dogs are pets",
            "a ferret makes unusual pets",
        ]))
        let scores = index.scores(query: RetrievalMath.tokenize("ferret pets"))
        XCTAssertEqual(scores.max(), scores[2], "the document with the rare term should win")
    }

    func testBM25LengthNormalizationPrefersShorterDocumentAtEqualTermFrequency() {
        let index = BM25Index(corpus: corpus([
            "swift swift filler filler filler filler filler filler filler filler",
            "swift swift",
        ]))
        let scores = index.scores(query: ["swift"])
        XCTAssertGreaterThan(scores[1], scores[0], "same term count in a shorter document should score higher")
    }

    func testBM25RepeatedQueryTermCountsOnce() {
        let index = BM25Index(corpus: corpus(["swift code", "python code"]))
        XCTAssertEqual(
            index.scores(query: ["swift", "swift", "swift"]),
            index.scores(query: ["swift"])
        )
    }

    func testBM25EmptyCorpusAndEmptyQueryProduceNoScores() {
        XCTAssertEqual(BM25Index(corpus: []).scores(query: ["anything"]), [])
        let index = BM25Index(corpus: corpus(["some document here"]))
        XCTAssertEqual(index.scores(query: []), [0])
    }

    func testBM25RankedIndicesExcludesZeroScoreDocuments() {
        let index = BM25Index(corpus: corpus([
            "cats and dogs",
            "cars and fuel",
            "more cats here",
        ]))
        let ranked = index.rankedIndices(query: RetrievalMath.tokenize("cats"))
        XCTAssertEqual(Set(ranked), Set([0, 2]), "the cars document shares no term and must not be ranked")
    }

    // MARK: - RRF

    func testRRFWithSingleRankingPreservesItsOrder() {
        // Dense-only (or BM25-only) degenerate case: fusion of one list is that list.
        XCTAssertEqual(RetrievalMath.rrf(rankings: [[2, 0, 1]]), [2, 0, 1])
    }

    func testRRFAgreementKeepsTheAgreedOrder() {
        XCTAssertEqual(RetrievalMath.rrf(rankings: [[3, 1, 2], [3, 1, 2]]), [3, 1, 2])
    }

    func testRRFDisagreementFavorsIndexRankedWellInBothLists() {
        // Index 5 is top of one list and second of the other; index 0 and 9
        // are each top of only one list and absent from the other.
        let fused = RetrievalMath.rrf(rankings: [[0, 5], [9, 5]])
        XCTAssertEqual(fused.first, 5, "an index near the top of BOTH rankings beats one top of a single ranking")
    }

    func testRRFIndexMissingFromOneListStillRanksFromTheOther() {
        let fused = RetrievalMath.rrf(rankings: [[0, 1, 2], []])
        XCTAssertEqual(fused, [0, 1, 2])
    }

    func testRRFOfNoRankingsOrEmptyRankingsIsEmpty() {
        XCTAssertEqual(RetrievalMath.rrf(rankings: []), [])
        XCTAssertEqual(RetrievalMath.rrf(rankings: [[], []]), [])
    }

    func testRRFTiesBreakTowardLowerIndexDeterministically() {
        // [0, 1] and [1, 0] give both indices identical fused scores.
        XCTAssertEqual(RetrievalMath.rrf(rankings: [[0, 1], [1, 0]]), [0, 1])
    }

    func testRRFReturnsEachIndexExactlyOnce() {
        let fused = RetrievalMath.rrf(rankings: [[0, 1, 2, 3], [3, 2, 1, 0], [1, 3]])
        XCTAssertEqual(fused.count, 4)
        XCTAssertEqual(Set(fused), Set(0...3))
    }

    // MARK: - indexableText (contextual title prefix)

    func testIndexableTextPrefixesTitleInBrackets() {
        XCTAssertEqual(
            RetrievalMath.indexableText(title: "MacBook Air – Apple", chunk: "It weighs 1.24 kg."),
            "[MacBook Air – Apple] It weighs 1.24 kg."
        )
    }

    func testIndexableTextWithEmptyOrWhitespaceTitleReturnsChunkUnchanged() {
        XCTAssertEqual(RetrievalMath.indexableText(title: "", chunk: "Chunk body."), "Chunk body.")
        XCTAssertEqual(RetrievalMath.indexableText(title: "  \n ", chunk: "Chunk body."), "Chunk body.")
    }

    func testIndexableTextCapsPathologicallyLongTitles() {
        let longTitle = String(repeating: "t", count: 500)
        let indexed = RetrievalMath.indexableText(title: longTitle, chunk: "Body.")
        XCTAssertEqual(indexed, "[\(String(repeating: "t", count: 120))] Body.")
    }
}
