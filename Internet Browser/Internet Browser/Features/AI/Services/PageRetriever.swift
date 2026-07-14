//
//  PageRetriever.swift
//  Cherry Browser
//
//  On-device retrieval (RAG) over a single page's extracted text: chunk it
//  into embedder-sized passages, embed each chunk once with Apple's
//  NLContextualEmbedding, and rank chunks against a question by cosine
//  similarity so answer paths can ground the model on the most relevant
//  sections instead of a blind prefix of the page.
//
//  NLContextualEmbedding itself only needs macOS 14+ / NaturalLanguage, so
//  this layer is deliberately independent of Foundation Models and macOS 26
//  — it's usable on its own and degrades gracefully (returns nil/false)
//  rather than throwing, so callers can always fall back to their existing
//  truncation behavior.
//

import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// One retrieval-sized passage of a page's extracted text. `index` preserves
/// the passage's position in the original document so results can be
/// returned in reading order rather than similarity order.
struct PageChunk: Equatable {
    let index: Int
    let text: String
}

/// The pure vector math retrieval ranking relies on, kept free of
/// NaturalLanguage types so it can be unit-tested without an on-device model.
enum RetrievalMath {
    /// Mean-pools a sequence of per-token embedding vectors (as returned by
    /// `NLContextualEmbeddingResult`) into a single vector representing the
    /// whole chunk.
    static func meanPool(_ vectors: [[Double]]) -> [Float] {
        guard let width = vectors.first?.count, width > 0 else { return [] }
        var sums = [Double](repeating: 0, count: width)
        for vector in vectors where vector.count == width {
            for i in 0..<width { sums[i] += vector[i] }
        }
        let count = Double(vectors.count)
        return sums.map { Float($0 / count) }
    }

    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        guard normA > 0, normB > 0 else { return 0 }
        return dot / (normA.squareRoot() * normB.squareRoot())
    }

    /// Ranks chunk embeddings against a query embedding, most similar first,
    /// returning the original chunk indices (not the chunks themselves) so
    /// callers can re-sort into document order afterwards.
    static func rankIndices(chunkEmbeddings: [[Float]], query: [Float]) -> [Int] {
        chunkEmbeddings.indices
            .map { ($0, cosineSimilarity(chunkEmbeddings[$0], query)) }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
    }
}

/// Retrieval passages are sized well under `NLContextualEmbedding`'s
/// 256-token-per-request limit (~4 chars/token for English, fewer for
/// denser scripts), leaving headroom so a single embedding call covers the
/// whole chunk without silent truncation.
private let ragChunkMaxChars = 900
private let defaultRetrievalTopK = 5

/// On-device retrieval over one page's text at a time. Callers `index(pageText:)`
/// once per page (results are cached by exact text match, so repeated
/// questions about the same page don't re-embed) then `retrieve(query:)` per
/// question.
///
/// A plain (non-`MainActor`) actor so the embedding work — which is real CPU
/// inference, even if Neural-Engine accelerated — never blocks the main
/// thread; callers already `await` into it from async contexts.
actor PageRetriever {
    static let shared = PageRetriever()

    static let chunkMaxChars = ragChunkMaxChars
    static let defaultTopK = defaultRetrievalTopK

    private var indexedPageText: String?
    private var chunks: [PageChunk] = []
    private var chunkEmbeddings: [[Float]] = []

    private init() {}

    /// Chunks and embeds `pageText` if it isn't already cached. Returns
    /// `false` — leaving any previously cached index untouched — when
    /// retrieval isn't usable: embedding assets unavailable, embedding
    /// failed, or the page is short enough that chunking wouldn't help
    /// (a single chunk gives retrieval nothing to rank).
    @discardableResult
    func index(pageText: String) async -> Bool {
        if indexedPageText == pageText, !chunks.isEmpty { return true }

        let newChunks = TextChunker.chunk(pageText, maxChars: Self.chunkMaxChars)
            .enumerated()
            .map { PageChunk(index: $0.offset, text: $0.element) }
        guard newChunks.count > 1 else { return false }

        guard let embeddings = await Self.embedAll(newChunks.map(\.text)) else { return false }

        indexedPageText = pageText
        chunks = newChunks
        chunkEmbeddings = embeddings
        return true
    }

    /// Ranks the currently indexed chunks against `query` and returns the
    /// top-K, in original document order for readability. `nil` means
    /// retrieval isn't usable right now (nothing indexed, or embedding the
    /// query failed) — callers should fall back to their existing
    /// truncation path.
    func retrieve(query: String, topK: Int = defaultRetrievalTopK) async -> [PageChunk]? {
        guard !chunks.isEmpty, !query.isEmpty else { return nil }
        guard let queryEmbeddings = await Self.embedAll([query]), let queryVector = queryEmbeddings.first else {
            return nil
        }

        let ranked = RetrievalMath.rankIndices(chunkEmbeddings: chunkEmbeddings, query: queryVector)
        let topIndices = Set(ranked.prefix(topK))
        return chunks.filter { topIndices.contains($0.index) }
    }

    /// Drops the cached index. Not required for correctness (a page-text
    /// change already invalidates the cache), but frees the embeddings of a
    /// page the user has navigated away from.
    func reset() {
        indexedPageText = nil
        chunks = []
        chunkEmbeddings = []
    }

    /// Embeds each string in `texts` (mean-pooled to one 512-dim vector per
    /// string). Returns `nil` — rather than a partial result — if the model
    /// is unavailable or any single embedding fails, since a partial index
    /// would silently rank chunks against missing vectors.
    private static func embedAll(_ texts: [String]) async -> [[Float]]? {
        #if canImport(NaturalLanguage)
        guard #available(macOS 14.0, *) else { return nil }
        guard let embedder = latinEmbedder, await ensureAssetsLoaded(embedder) else { return nil }

        var results: [[Float]] = []
        results.reserveCapacity(texts.count)
        for text in texts {
            guard let vector = embed(text, with: embedder) else { return nil }
            results.append(vector)
        }
        return results
        #else
        return nil
        #endif
    }

    #if canImport(NaturalLanguage)
    @available(macOS 14.0, *)
    private static let latinEmbedder: NLContextualEmbedding? = NLContextualEmbedding(script: .latin)

    @available(macOS 14.0, *)
    private static func ensureAssetsLoaded(_ embedder: NLContextualEmbedding) async -> Bool {
        if !embedder.hasAvailableAssets {
            guard let result = try? await embedder.requestAssets(), result == .available else {
                return false
            }
        }
        return (try? embedder.load()) != nil
    }

    /// Embeds one chunk of text: runs the contextual embedding to get a
    /// per-token vector sequence, then mean-pools it into a single 512-dim
    /// vector representing the whole chunk.
    @available(macOS 14.0, *)
    private static func embed(_ text: String, with embedder: NLContextualEmbedding) -> [Float]? {
        guard !text.isEmpty, let result = try? embedder.embeddingResult(for: text, language: nil) else {
            return nil
        }
        var tokenVectors: [[Double]] = []
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
            tokenVectors.append(vector)
            return true
        }
        guard !tokenVectors.isEmpty else { return nil }
        return RetrievalMath.meanPool(tokenVectors)
    }
    #endif
}
