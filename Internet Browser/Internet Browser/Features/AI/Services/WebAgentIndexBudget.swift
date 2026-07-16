//
//  WebAgentIndexBudget.swift
//  Cherry Browser
//
//  The web research agent's "how much indexing is worth the wait?" policy,
//  factored out as pure, unit-testable logic — the sibling of
//  `WebAgentLoadWait`, one step later in the flow. The agent opens up to a
//  handful of FULL result pages, and embedding every chunk of all of them
//  through `NLContextualEmbedding` can take tens of seconds — which reads as
//  a hang on "Indexing…". Deliberate All-Tabs research over the user's own
//  tabs stays unbounded (a considered user action); only tabs the AGENT
//  opened get this budget.
//

nonisolated enum WebAgentIndexBudget {
    /// How much of ONE agent-opened result page gets indexed. 8k characters
    /// is ~11 retrieval chunks at the 700-char chunk target — across five
    /// result tabs that's ~55 chunks to embed (a few seconds) instead of the
    /// unbounded whole-page count, and web pages front-load their substance,
    /// so the first 8k of a result is plenty for a good cited answer.
    static let perTabIndexCharacterLimit = 8_000

    /// Hard budget on the agent's whole index build (extraction + chunking +
    /// embedding). `performWebResearch` races `prepare` against this; on
    /// expiry it proceeds with whatever has been indexed (or fails with the
    /// normal "couldn't read" message) instead of sitting on "Indexing…"
    /// forever. Generous on purpose: with the per-tab cap the build should
    /// finish in seconds, so hitting this means something is genuinely wedged.
    static let prepareTimeout: Duration = .seconds(22)

    /// `text` cut down to at most `limit` characters for indexing. Backtracks
    /// to the last whitespace inside the window so the cut never splits a
    /// word mid-way (a severed half-word would embed and BM25-tokenize as
    /// noise), then trims the trailing whitespace itself. Text within the
    /// limit is returned untouched.
    static func cappedText(_ text: String, limit: Int = perTabIndexCharacterLimit) -> String {
        guard limit > 0 else { return "" }
        guard text.count > limit else { return text }
        let window = text.prefix(limit)
        guard let lastSpace = window.lastIndex(where: \.isWhitespace) else {
            return String(window)
        }
        var cut = String(window[..<lastSpace])
        while cut.last?.isWhitespace == true { cut.removeLast() }
        // Pathological input (one giant unbroken token after leading spaces)
        // can leave nothing usable before the cut — fall back to the raw
        // window rather than returning "".
        return cut.isEmpty ? String(window) : cut
    }
}
