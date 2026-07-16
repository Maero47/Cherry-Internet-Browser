//
//  TabsResearchService.swift
//  Cherry Browser
//
//  On-device HYBRID retrieval (RAG) over MULTIPLE open tabs at once: chunk
//  every eligible tab's extracted text (each chunk tagged with the tab it
//  came from), index all chunks together both densely (embeddings) and
//  lexically (BM25), then rank a question across ALL tabs by fusing the two
//  rankings with Reciprocal Rank Fusion — so an answer can pull the most
//  relevant passages from wherever they live, with each passage traceable
//  back to its source tab.
//
//  Mirrors `PageRetriever`'s single-page shape (chunk -> index -> cache ->
//  fuse-rank, BM25-only when embeddings are unavailable) and reuses its pure
//  math (`RetrievalMath`, `BM25Index`) and chunker (`TextChunker`) unchanged;
//  only the indexing unit changes from "one page" to "one tab per source,
//  many tabs per index". Each chunk is indexed under its own tab's title as
//  the contextual prefix.
//

import Foundation

/// One eligible open tab, as gathered by the caller (private/internal/home/
/// sleeping tabs are expected to already be filtered out before this reaches
/// the service). `tabID` is `Tab.id`, kept so a citation can later be used to
/// re-select the originating tab.
struct ResearchTabInput: Equatable {
    let tabID: UUID
    let title: String
    let url: URL?
    let text: String
}

/// One open tab's identity as a citable source. `index` is the stable 1-based
/// number shown to the model and in the UI as `[N]` for the lifetime of one
/// built index (i.e. until the panel gathers tabs again).
struct ResearchSource: Identifiable, Equatable {
    var id: Int { index }
    let index: Int
    let tabID: UUID
    let title: String
    let url: URL?
}

/// One retrieval-sized passage of a single tab's text, tagged with the
/// source it came from so a synthesized answer can cite it.
struct ResearchChunk: Equatable {
    let source: ResearchSource
    let text: String
}

/// On-device multi-tab retrieval. Callers call `buildIndex(tabs:)` once per
/// "snapshot" of open tabs, then `retrieve(query:)` per question; the index
/// (chunks + embeddings, tagged per source) is cached by exact tab-snapshot
/// match so follow-up questions in the same session don't re-embed.
///
/// Deliberately NOT a shared singleton: the app is multi-window, and each
/// window has its own `TabManager`/`TabsResearchSession` with its own set of
/// open tabs. A single process-wide instance would let one window's
/// `buildIndex` overwrite another window's cached chunks/embeddings mid-flight
/// (this actor is reentrant across the `await embedAll` suspension in
/// `buildIndex`/`retrieve`), so `TabsResearchSession` owns its own instance
/// instead — no two windows ever share state, so the race can't happen.
///
/// A plain (non-`MainActor`) actor, same rationale as `PageRetriever`: the
/// embedding work is real CPU inference and must never block the main thread.
actor TabsResearchService {
    /// Same per-chunk budget as `PageRetriever`, since the same embedder
    /// (`NLContextualEmbedding`, 256-token-per-request limit) does the work
    /// regardless of how many sources feed the index.
    static let chunkTargetChars = PageRetriever.chunkTargetChars
    static let chunkOverlapChars = PageRetriever.chunkOverlapChars
    /// Kept comfortably under the 4096-token context window once source
    /// labels, instructions, and the question are added on top: ~6 chunks of
    /// up to `chunkTargetChars` + carried overlap (~200 tokens each) is
    /// ~1200 tokens of raw excerpts, leaving generous headroom for
    /// everything else in the prompt.
    static let defaultTopK = 6

    private var indexedTabs: [ResearchTabInput] = []
    private var chunks: [ResearchChunk] = []
    /// `nil` when the index was built without embeddings (assets not ready /
    /// model failure) — retrieval then runs BM25-only until an upgrade
    /// attempt on a later `buildIndex` call succeeds. Same shape as
    /// `PageRetriever.chunkEmbeddings`.
    private var chunkEmbeddings: [[Float]]?
    private var bm25: BM25Index?

    /// (Re)builds the multi-tab index from `tabs` if this snapshot differs
    /// from the currently cached one. Returns `false` — leaving any
    /// previously cached index untouched — only when there's nothing to
    /// index at all: no tabs with real text. An embedding failure no longer
    /// fails the build — the BM25 half needs no model, so the index is
    /// stored lexical-only and later builds try to add embeddings once
    /// assets become available. Callers should treat `false` as "retrieval
    /// isn't usable" and fall back to a graceful message, never a crash.
    @discardableResult
    func buildIndex(tabs: [ResearchTabInput]) async -> Bool {
        let nonEmptyTabs = tabs.filter { !$0.text.isEmpty }
        guard !nonEmptyTabs.isEmpty else { return false }
        if indexedTabs == nonEmptyTabs, !chunks.isEmpty {
            if chunkEmbeddings == nil {
                // Same upgrade path and post-await identity re-check as
                // `PageRetriever.index`: a concurrent rebuild for a newer
                // tab snapshot must not receive this snapshot's vectors.
                let indexTexts = chunks.map(Self.indexText(for:))
                if let embeddings = await PageRetriever.embedAll(indexTexts),
                   indexedTabs == nonEmptyTabs, chunkEmbeddings == nil {
                    chunkEmbeddings = embeddings
                }
            }
            return true
        }

        let newChunks = Self.makeChunks(from: nonEmptyTabs)
        guard !newChunks.isEmpty else { return false }

        // Both halves of the hybrid index are built over the SAME
        // title-prefixed index text (each chunk under its own tab's title),
        // so lexical and dense retrieval see identical documents.
        let indexTexts = newChunks.map(Self.indexText(for:))
        let newBM25 = BM25Index(corpus: indexTexts.map(RetrievalMath.tokenize))
        let newEmbeddings = await PageRetriever.embedAll(indexTexts)

        indexedTabs = nonEmptyTabs
        chunks = newChunks
        chunkEmbeddings = newEmbeddings
        bm25 = newBM25
        return true
    }

    /// The text a chunk is indexed under: its source tab's title as the
    /// contextual prefix + the chunk body. The chunk text handed to the
    /// model (and cited in the UI) stays clean.
    private static func indexText(for chunk: ResearchChunk) -> String {
        RetrievalMath.indexableText(title: chunk.source.title, chunk: chunk.text)
    }

    /// Chunks every tab's text and tags each chunk with its source, in tab
    /// order (source 1 is `tabs[0]`, etc.). Pure and embedding-free, so it's
    /// unit-testable on its own — `buildIndex` just adds the embedding step
    /// on top of this. Assumes `tabs` has already been filtered to non-empty
    /// text, same as `buildIndex` does before calling this.
    static func makeChunks(from tabs: [ResearchTabInput]) -> [ResearchChunk] {
        var result: [ResearchChunk] = []
        for (offset, tab) in tabs.enumerated() {
            let source = ResearchSource(index: offset + 1, tabID: tab.tabID, title: tab.title, url: tab.url)
            let pieces = TextChunker.retrievalChunks(
                tab.text,
                targetChars: Self.chunkTargetChars,
                overlapChars: Self.chunkOverlapChars
            )
            result.append(contentsOf: pieces.map { ResearchChunk(source: source, text: $0) })
        }
        return result
    }

    /// Retrieves the top-K chunks across ALL indexed tabs most relevant to
    /// `query`, ranked by the same hybrid fusion as `PageRetriever.retrieve`
    /// (dense cosine + BM25, fused with RRF over the whole chunk pool, then
    /// trimmed to the fused top-K in document order) and each tagged with
    /// its source tab. BM25-only when embeddings are unavailable. Returns
    /// `nil` when retrieval isn't usable: no index built yet, `query` is
    /// empty, or neither ranking produced a signal — callers should show a
    /// graceful fallback.
    func retrieve(query: String, topK: Int = defaultTopK) async -> [ResearchChunk]? {
        guard !query.isEmpty, !chunks.isEmpty else { return nil }

        // Snapshot now, synchronously, before the only await below — same
        // race-safety rationale as `PageRetriever.retrieve`: a concurrent
        // `buildIndex` for a newer tab snapshot cannot corrupt this call's
        // ranking or return a mix of old and new chunks.
        let localChunks = chunks
        let localEmbeddings = chunkEmbeddings
        let localBM25 = bm25

        let bm25Ranking = localBM25?.rankedIndices(query: RetrievalMath.tokenize(query)) ?? []

        var denseRanking: [Int] = []
        if let localEmbeddings,
           let queryEmbeddings = await PageRetriever.embedAll([query]),
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

        let topPositions = Set(fused.prefix(topK))
        return localChunks.indices.filter { topPositions.contains($0) }.map { localChunks[$0] }
    }

    /// Drops the cached index, freeing the embeddings of a tab snapshot the
    /// panel no longer needs (e.g. dismissed, or gathering tabs again).
    func reset() {
        indexedTabs = []
        chunks = []
        chunkEmbeddings = nil
        bm25 = nil
    }
}

extension TabsResearchService {
    /// The distinct sources referenced by `chunks`, in order of first
    /// appearance (which is document order per source, since `chunks` is
    /// built tab-by-tab). Used to populate a "Sources" list before an answer
    /// even names which of them it actually used.
    static func distinctSources(in chunks: [ResearchChunk]) -> [ResearchSource] {
        var seen = Set<Int>()
        var result: [ResearchSource] = []
        for chunk in chunks where !seen.contains(chunk.source.index) {
            seen.insert(chunk.source.index)
            result.append(chunk.source)
        }
        return result
    }

    /// Sources actually cited in `answer` via a `[N]` marker, in order of
    /// first citation, matched against `candidates` (the sources that were
    /// actually offered to the model for this answer — a citation to any
    /// other number is ignored as a hallucinated reference). Falls back to
    /// returning all of `candidates` when the answer contains no recognizable
    /// citation, so the "Sources" list is never empty for a grounded answer.
    static func citedSources(inAnswer answer: String, candidates: [ResearchSource]) -> [ResearchSource] {
        guard let regex = try? NSRegularExpression(pattern: "\\[(\\d+)\\]") else { return candidates }
        let nsAnswer = answer as NSString
        let matches = regex.matches(in: answer, range: NSRange(location: 0, length: nsAnswer.length))

        var seen = Set<Int>()
        var result: [ResearchSource] = []
        for match in matches {
            guard match.numberOfRanges > 1 else { continue }
            let numberString = nsAnswer.substring(with: match.range(at: 1))
            guard let number = Int(numberString),
                  !seen.contains(number),
                  let source = candidates.first(where: { $0.index == number }) else { continue }
            seen.insert(number)
            result.append(source)
        }
        return result.isEmpty ? candidates : result
    }
}
