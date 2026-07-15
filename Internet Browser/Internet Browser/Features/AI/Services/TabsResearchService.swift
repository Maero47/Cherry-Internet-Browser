//
//  TabsResearchService.swift
//  Cherry Browser
//
//  On-device retrieval (RAG) over MULTIPLE open tabs at once: chunk and embed
//  every eligible tab's extracted text (each chunk tagged with the tab it
//  came from), then rank chunks from ALL tabs together by cosine similarity
//  so a question can be answered by pulling the most relevant passages from
//  wherever they live, with each passage traceable back to its source tab.
//
//  Mirrors `PageRetriever`'s single-page shape (chunk -> embed -> cache ->
//  rank) and reuses its pure ranking math (`RetrievalMath`) and chunker
//  (`TextChunker`) unchanged; only the indexing unit changes from "one page"
//  to "one tab per source, many tabs per index".
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
    static let chunkMaxChars = PageRetriever.chunkMaxChars
    /// Kept comfortably under the 4096-token context window once source
    /// labels, instructions, and the question are added on top: ~6 chunks of
    /// up to `chunkMaxChars` (~225 tokens each) is ~1350 tokens of raw
    /// excerpts, leaving generous headroom for everything else in the prompt.
    static let defaultTopK = 6

    private var indexedTabs: [ResearchTabInput] = []
    private var chunks: [ResearchChunk] = []
    private var chunkEmbeddings: [[Float]] = []

    /// (Re)builds the multi-tab index from `tabs` if this snapshot differs
    /// from the currently cached one. Returns `false` — leaving any
    /// previously cached index untouched — when there's nothing usable to
    /// index: no tabs with real text, or embedding isn't available (assets
    /// not ready / model failure). Callers should treat `false` as "retrieval
    /// isn't usable" and fall back to a graceful message, never a crash.
    @discardableResult
    func buildIndex(tabs: [ResearchTabInput]) async -> Bool {
        let nonEmptyTabs = tabs.filter { !$0.text.isEmpty }
        guard !nonEmptyTabs.isEmpty else { return false }
        if indexedTabs == nonEmptyTabs, !chunks.isEmpty { return true }

        let newChunks = Self.makeChunks(from: nonEmptyTabs)
        guard !newChunks.isEmpty else { return false }

        guard let embeddings = await PageRetriever.embedAll(newChunks.map(\.text)) else { return false }

        indexedTabs = nonEmptyTabs
        chunks = newChunks
        chunkEmbeddings = embeddings
        return true
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
            let pieces = TextChunker.chunk(tab.text, maxChars: Self.chunkMaxChars)
            result.append(contentsOf: pieces.map { ResearchChunk(source: source, text: $0) })
        }
        return result
    }

    /// Retrieves the top-K chunks across ALL indexed tabs most relevant to
    /// `query`, each tagged with its source tab. Returns `nil` when
    /// retrieval isn't usable: no index built yet, embedding failed, or
    /// `query` is empty — callers should show a graceful fallback.
    func retrieve(query: String, topK: Int = defaultTopK) async -> [ResearchChunk]? {
        guard !query.isEmpty, !chunks.isEmpty else { return nil }

        // Snapshot now, synchronously, before the only await below — same
        // race-safety rationale as `PageRetriever.retrieve`: a concurrent
        // `buildIndex` for a newer tab snapshot cannot corrupt this call's
        // ranking or return a mix of old and new chunks.
        let localChunks = chunks
        let localEmbeddings = chunkEmbeddings

        guard let queryEmbeddings = await PageRetriever.embedAll([query]), let queryVector = queryEmbeddings.first else {
            return nil
        }

        let ranked = RetrievalMath.rankIndices(chunkEmbeddings: localEmbeddings, query: queryVector)
        let topPositions = Set(ranked.prefix(topK))
        return localChunks.indices.filter { topPositions.contains($0) }.map { localChunks[$0] }
    }

    /// Drops the cached index, freeing the embeddings of a tab snapshot the
    /// panel no longer needs (e.g. dismissed, or gathering tabs again).
    func reset() {
        indexedTabs = []
        chunks = []
        chunkEmbeddings = []
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
