//
//  PageRetriever.swift
//  Cherry Browser
//
//  On-device HYBRID retrieval (RAG) over a single page's extracted text:
//  chunk it into overlapping, embedder-sized passages, index each chunk
//  both densely (one mean-pooled NLContextualEmbedding vector) and
//  lexically (Okapi BM25 over its tokens), then rank a question by fusing
//  the cosine ranking and the BM25 ranking with Reciprocal Rank Fusion —
//  dense retrieval carries the semantics, BM25 carries the exact terms
//  (names, numbers, code, rare words) embeddings are weak on.
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
        var matchingCount = 0
        for vector in vectors where vector.count == width {
            for i in 0..<width { sums[i] += vector[i] }
            matchingCount += 1
        }
        // Divide by the vectors actually summed, not the total input count —
        // any mismatched-width vectors were skipped above, and averaging
        // over the full count would understate the mean.
        guard matchingCount > 0 else { return [] }
        let count = Double(matchingCount)
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

    /// Deterministic lowercasing word tokenizer for BM25: splits on anything
    /// that isn't a letter or digit, keeping full Unicode letters/digits so
    /// Turkish and other accented Latin text tokenizes into whole words
    /// (matching the Latin-script embedder's coverage). Pure — no
    /// NaturalLanguage dependency, so lexical retrieval needs no model assets.
    nonisolated static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
    }

    /// Reciprocal Rank Fusion: fuses several ranked lists of chunk indices
    /// (e.g. a dense cosine ranking and a BM25 ranking) into one ranking by
    /// `sum(1 / (k + rank))` per index, best first. Operating on RANKS
    /// rather than raw scores is what makes the fusion robust to the
    /// incompatible scales of cosine (−1…1) and BM25 (unbounded). An index
    /// absent from a list simply gets no contribution from it; exact score
    /// ties break toward the lower (earlier-in-document) index so the result
    /// is deterministic.
    nonisolated static func rrf(rankings: [[Int]], k: Int = 60) -> [Int] {
        var scores: [Int: Double] = [:]
        for ranking in rankings {
            for (position, index) in ranking.enumerated() {
                scores[index, default: 0] += 1 / Double(k + position + 1)
            }
        }
        return scores.keys.sorted {
            let a = scores[$0]!, b = scores[$1]!
            return a == b ? $0 < $1 : a > b
        }
    }

    /// The text a chunk is INDEXED under (embedded + BM25-tokenized): the
    /// page/tab title prepended as a cheap contextual prefix, so a chunk
    /// that lost the document's subject during splitting still carries it.
    /// The chunk text callers return to the model stays clean — the prefix
    /// exists only inside the index. The title is trimmed and capped so a
    /// pathological title can't crowd the chunk out of the embedder's
    /// per-request token budget.
    nonisolated static func indexableText(title: String, chunk: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return chunk }
        return "[\(trimmed.prefix(120))] \(chunk)"
    }
}

/// Classic Okapi BM25 over a tokenized chunk corpus. Precomputes postings
/// (term → documents containing it, with counts), inverse document
/// frequencies, and length normalization at index time, so scoring a query
/// costs only its terms' posting lists — no per-query corpus scan. Pure and
/// model-free: this is the lexical half of hybrid retrieval, strong exactly
/// where dense embeddings are weak (names, numbers, code, rare words), and
/// it keeps working even when embedding assets aren't available.
nonisolated struct BM25Index {
    /// Standard Okapi parameters: `k1` bounds how quickly repeated term
    /// occurrences saturate; `b` sets how strongly longer documents are
    /// penalized.
    static let k1 = 1.5
    static let b = 0.75

    private let postings: [String: [(document: Int, count: Int)]]
    private let inverseDocumentFrequency: [String: Double]
    private let documentLengths: [Int]
    private let averageDocumentLength: Double

    var documentCount: Int { documentLengths.count }

    init(corpus: [[String]]) {
        documentLengths = corpus.map(\.count)
        let totalLength = documentLengths.reduce(0, +)
        averageDocumentLength = corpus.isEmpty ? 0 : Double(totalLength) / Double(corpus.count)

        var postings: [String: [(document: Int, count: Int)]] = [:]
        for (document, tokens) in corpus.enumerated() {
            var counts: [String: Int] = [:]
            for token in tokens { counts[token, default: 0] += 1 }
            for (term, count) in counts { postings[term, default: []].append((document, count)) }
        }
        self.postings = postings

        // The "+1" inside the log is the non-negative IDF variant (as used
        // by Lucene): a term present in most documents scores near zero
        // instead of going negative and actively repelling matches.
        let n = Double(corpus.count)
        inverseDocumentFrequency = postings.mapValues { posting in
            let df = Double(posting.count)
            return Foundation.log((n - df + 0.5) / (df + 0.5) + 1)
        }
    }

    /// One score per corpus document for `query` (already tokenized with the
    /// same tokenizer as the corpus). Duplicate query terms count once — a
    /// user repeating a word shouldn't double its weight.
    func scores(query: [String]) -> [Double] {
        var scores = [Double](repeating: 0, count: documentCount)
        guard averageDocumentLength > 0 else { return scores }
        for term in Set(query) {
            guard let posting = postings[term], let idf = inverseDocumentFrequency[term] else { continue }
            for (document, count) in posting {
                let tf = Double(count)
                let lengthNorm = 1 - Self.b + Self.b * Double(documentLengths[document]) / averageDocumentLength
                scores[document] += idf * (tf * (Self.k1 + 1)) / (tf + Self.k1 * lengthNorm)
            }
        }
        return scores
    }

    /// Document indices ranked best-first, INCLUDING only documents with a
    /// positive score — a document sharing no term with the query carries no
    /// lexical signal, and giving it an arbitrary tie rank would just inject
    /// noise into rank fusion. Ties break toward the lower index so the
    /// ranking is deterministic.
    func rankedIndices(query: [String]) -> [Int] {
        let scores = scores(query: query)
        return scores.indices
            .filter { scores[$0] > 0 }
            .sorted { scores[$0] == scores[$1] ? $0 < $1 : scores[$0] > scores[$1] }
    }
}

/// Retrieval passages are sized well under `NLContextualEmbedding`'s
/// 256-token-per-request limit (~4 chars/token for English, fewer for
/// denser scripts). The budget that has to stay under that limit is
/// target + carried overlap + the bracketed title prefix (capped at 120
/// chars by `RetrievalMath.indexableText`): 700 + 100 + ~125 ≈ 925 chars —
/// about the old 900-char single-chunk budget. The smaller 700-char target
/// (vs the old 900) also dilutes each chunk's mean-pooled vector less.
private let ragChunkTargetChars = 700
/// ~14% of the target: adjacent chunks carry the previous chunk's tail
/// sentences so an answer spanning a chunk boundary appears whole in at
/// least one chunk.
private let ragChunkOverlapChars = 100
private let defaultRetrievalTopK = 5

/// On-device retrieval over one page's text at a time. Callers call
/// `retrieve(pageText:query:)` per question; the index (chunks + embeddings)
/// is cached by exact page-text match so repeated questions about the same
/// page don't re-embed.
///
/// A plain (non-`MainActor`) actor so the embedding work — which is real CPU
/// inference, even if Neural-Engine accelerated — never blocks the main
/// thread; callers already `await` into it from async contexts.
actor PageRetriever {
    static let shared = PageRetriever()

    static let chunkTargetChars = ragChunkTargetChars
    static let chunkOverlapChars = ragChunkOverlapChars
    static let defaultTopK = defaultRetrievalTopK

    private var indexedPageText: String?
    private var indexedTitle: String?
    private var chunks: [PageChunk] = []
    /// `nil` when the index was built without embeddings (assets not ready /
    /// model failure) — retrieval then runs BM25-only until an upgrade
    /// attempt on a later call succeeds.
    private var chunkEmbeddings: [[Float]]?
    private var bm25: BM25Index?

    private init() {}

    /// Retrieves the chunks of `pageText` most relevant to `query`, ranked
    /// by HYBRID retrieval: the dense cosine ranking and the lexical BM25
    /// ranking over the whole chunk pool, fused with Reciprocal Rank Fusion,
    /// trimmed to the fused top-K, and returned in document order.
    /// `pageTitle` is threaded into the index as each chunk's contextual
    /// prefix (see `RetrievalMath.indexableText`); the returned chunk text
    /// itself stays clean.
    ///
    /// Atomic per call: this method (re)builds the index for `pageText` if
    /// needed, then snapshots the chunk/embedding/BM25 state into LOCAL
    /// constants before its only remaining suspension point (embedding the
    /// query). Ranking afterwards reads only that local snapshot, never the
    /// actor's mutable index — so a concurrent call for a DIFFERENT page
    /// (another tab, or a stale in-flight turn after navigating) that
    /// overwrites the shared index while this call's query is embedding
    /// cannot corrupt this call's ranking or return the wrong page's chunks.
    ///
    /// Degrades gracefully: if embeddings are unavailable, the BM25 ranking
    /// alone drives retrieval (lexical scoring needs no model assets).
    /// Returns `nil` only when NOTHING is usable: the page is too short to
    /// chunk, `query` is empty, or neither ranking produced a signal —
    /// callers should fall back to their existing truncation path.
    func retrieve(pageText: String, pageTitle: String = "", query: String, topK: Int = defaultRetrievalTopK) async -> [PageChunk]? {
        guard !query.isEmpty else { return nil }
        guard await index(pageText: pageText, title: pageTitle),
              indexedPageText == pageText, indexedTitle == pageTitle else { return nil }

        // Snapshot now, synchronously, before the only await below — no
        // other call can interleave between this line and the guard above.
        let localChunks = chunks
        let localEmbeddings = chunkEmbeddings
        let localBM25 = bm25

        let bm25Ranking = localBM25?.rankedIndices(query: RetrievalMath.tokenize(query)) ?? []

        var denseRanking: [Int] = []
        if let localEmbeddings,
           let queryEmbeddings = await Self.embedAll([query]),
           let queryVector = queryEmbeddings.first {
            denseRanking = RetrievalMath.rankIndices(chunkEmbeddings: localEmbeddings, query: queryVector)
        }

        let fused: [Int]
        switch (denseRanking.isEmpty, bm25Ranking.isEmpty) {
        case (true, true):
            return nil
        case (false, true):
            fused = denseRanking
        case (true, false):
            fused = bm25Ranking
        case (false, false):
            fused = RetrievalMath.rrf(rankings: [denseRanking, bm25Ranking])
        }

        let topIndices = Set(fused.prefix(topK))
        return localChunks.filter { topIndices.contains($0.index) }
    }

    /// Chunks and indexes `pageText` (BM25 always; embeddings when the model
    /// is usable) unless it's already cached under the same text + title.
    /// Returns `false` — leaving any previously cached index untouched —
    /// only when the page is short enough that chunking wouldn't help (a
    /// single chunk gives retrieval nothing to rank). An embedding failure
    /// no longer fails indexing: the BM25 side needs no model, so the index
    /// is stored without embeddings and later calls try to add them once
    /// assets become available.
    private func index(pageText: String, title: String) async -> Bool {
        if indexedPageText == pageText, indexedTitle == title, !chunks.isEmpty {
            if chunkEmbeddings == nil {
                // Assets may have become available since this index was
                // built BM25-only — try to upgrade it with embeddings. The
                // identity re-check after the await mirrors `retrieve`'s
                // snapshot discipline: a concurrent rebuild for a different
                // page must not receive this page's vectors.
                let indexTexts = chunks.map { RetrievalMath.indexableText(title: title, chunk: $0.text) }
                if let embeddings = await Self.embedAll(indexTexts),
                   indexedPageText == pageText, indexedTitle == title, chunkEmbeddings == nil {
                    chunkEmbeddings = embeddings
                }
            }
            return true
        }

        let newChunks = TextChunker.retrievalChunks(
            pageText,
            targetChars: Self.chunkTargetChars,
            overlapChars: Self.chunkOverlapChars
        )
        .enumerated()
        .map { PageChunk(index: $0.offset, text: $0.element) }
        guard newChunks.count > 1 else { return false }

        // Both halves of the hybrid index — the BM25 corpus and the chunk
        // embeddings — are built over the SAME title-prefixed index text,
        // so lexical and dense retrieval see identical documents.
        let indexTexts = newChunks.map { RetrievalMath.indexableText(title: title, chunk: $0.text) }
        let newBM25 = BM25Index(corpus: indexTexts.map(RetrievalMath.tokenize))
        let newEmbeddings = await Self.embedAll(indexTexts)

        indexedPageText = pageText
        indexedTitle = title
        chunks = newChunks
        chunkEmbeddings = newEmbeddings
        bm25 = newBM25
        return true
    }

    /// Drops the cached index. Not required for correctness (a page-text
    /// change already invalidates the cache), but frees the embeddings of a
    /// page the user has navigated away from.
    func reset() {
        indexedPageText = nil
        indexedTitle = nil
        chunks = []
        chunkEmbeddings = nil
        bm25 = nil
    }

    /// Embeds each string in `texts` (mean-pooled to one 512-dim vector per
    /// string). Returns `nil` — rather than a partial result — if the model
    /// is unavailable or any single embedding fails, since a partial index
    /// would silently rank chunks against missing vectors.
    ///
    /// Not `private`: `TabsResearchService` reuses this same embedding
    /// approach for its multi-tab index, so both retrievers share one
    /// `NLContextualEmbedding` code path instead of duplicating it.
    static func embedAll(_ texts: [String]) async -> [[Float]]? {
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
