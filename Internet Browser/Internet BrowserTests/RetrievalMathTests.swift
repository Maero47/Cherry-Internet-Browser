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
}
