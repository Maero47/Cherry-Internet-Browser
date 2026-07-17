//
//  TabsResearchSession.swift
//  Cherry Browser
//
//  Drives the "All Tabs" research chat: gathers eligible open tabs, builds a
//  multi-source RAG index over them via `TabsResearchService`, and turns
//  questions into cited answers via `PageAIService`'s research engine.
//  Mirrors `PageChatSession`'s shape (turns + streaming + graceful failure)
//  but grounds each turn on excerpts retrieved fresh across ALL open tabs
//  instead of one page's text.
//

import Combine
import Foundation

@MainActor
final class TabsResearchSession: ObservableObject {
    @Published private(set) var turns: [PageChatTurn] = []
    @Published private(set) var isResponding = false
    @Published private(set) var isPreparing = false
    /// Becomes `true` once `prepare(tabManager:)` has run at least once,
    /// whether or not it found anything usable — used to tell "still
    /// gathering tabs" apart from "gathered, and there was nothing to work
    /// with" in the UI's fallback state.
    @Published private(set) var hasPrepared = false
    @Published private(set) var includedTabCount = 0
    @Published private(set) var skippedTabCount = 0
    /// Live progress of the CURRENT gather's extraction fan-out: how many of
    /// the eligible tabs have finished extracting (successfully or not) out
    /// of how many were attempted. `nil` outside a gather. Drives the web
    /// agent's "Indexing (n/m)…" label so the index build reads as moving,
    /// not hung.
    @Published private(set) var prepareProgress: PrepareProgress?

    struct PrepareProgress: Equatable {
        var extractedTabs: Int
        var totalTabs: Int
    }
    /// Which AI engine setting the current conversation's engine was built
    /// with — same role as `PageChatSession.conversationEngine`.
    @Published private(set) var conversationEngine: AIEngine?

    /// Owned exclusively by this session — NOT `TabsResearchService.shared`
    /// (there is no such singleton). Each window has its own
    /// `TabsResearchSession`/`TabManager`, so each gets its own retriever
    /// instance: sharing one process-wide actor across windows would let a
    /// concurrent `buildIndex` from another window's session overwrite this
    /// session's cached chunks/embeddings mid-flight, answering this
    /// window's question with another window's tabs.
    private let retriever = TabsResearchService()
    private var engine: AnyObject?
    private var isIndexed = false
    private var streamTask: Task<Void, Never>?

    /// Stable identity of the CURRENT conversation, used as the history
    /// store's upsert key — same role as `PageChatSession.conversationID`.
    private(set) var conversationID = UUID()

    /// Set by `restore`: a compact replay of the reopened conversation's
    /// recent turns, folded into the NEXT engine build (the original engine's
    /// state can't be restored) so follow-up questions stay coherent.
    /// Consumed by the first successful build; cleared by `startNewChat`.
    private var pendingRestoredReplay: String?

    var canSend: Bool { !isResponding && isIndexed }

    deinit {
        streamTask?.cancel()
    }

    /// Gathers eligible open tabs from `tabManager` (excluding private,
    /// internal `cherry://`, home-page, and sleeping tabs — the last because
    /// a sleeping tab's `webView` is `nil` and can't be extracted without
    /// waking it), extracts each one's readable text, and builds the
    /// multi-tab retrieval index. Safe to call more than once (e.g. a
    /// "Refresh tabs" action): re-gathering is cheap when nothing changed,
    /// since `TabsResearchService.buildIndex` skips re-embedding an unchanged
    /// snapshot.
    /// Coalesces concurrent gathers onto a single in-flight task. The panel's
    /// automatic re-gather (on tab open/close) and a manual "New Chat"/"Try Again"
    /// tap can race; without this the manual caller's `await` would return
    /// immediately (old `guard !isPreparing` no-op) and then act on stale
    /// pre-refresh state. Now every caller awaits the SAME gather and sees its
    /// result before proceeding.
    private var prepareTask: Task<Void, Never>?
    /// Set when a new gather is requested while one is already running (e.g. the
    /// tab set changed again mid-flight) so the owner re-gathers once more with
    /// the latest tabs rather than committing a snapshot that's already stale.
    private var regatherRequested = false
    /// The most recently requested tab subset (`nil` = all eligible tabs).
    /// Read fresh on each owner-loop iteration so a trailing re-gather always
    /// indexes the LATEST requested selection, not the one that started the chain.
    private var requestedIncludeTabIDs: Set<UUID>?

    /// When `includeTabIDs` is non-nil, only those tabs are gathered and
    /// indexed (the panel's tab picker drives this); `nil` keeps the original
    /// "every eligible open tab" behavior.
    func prepare(tabManager: TabManager, includeTabIDs: Set<UUID>? = nil) async {
        requestedIncludeTabIDs = includeTabIDs
        // A gather is already running: request a trailing re-gather (so the final
        // index reflects the latest tab set) and await the whole chain to settle.
        if prepareTask != nil {
            regatherRequested = true
            while let task = prepareTask { await task.value }
            return
        }
        // Owner: run gathers back-to-back as long as changes keep arriving.
        repeat {
            regatherRequested = false
            let include = requestedIncludeTabIDs
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.performPrepare(tabManager: tabManager, includeTabIDs: include)
            }
            prepareTask = task
            await task.value
            prepareTask = nil
        } while regatherRequested
    }

    private func performPrepare(tabManager: TabManager, includeTabIDs: Set<UUID>?) async {
        isPreparing = true
        defer {
            isPreparing = false
            hasPrepared = true
        }

        let allTabs = tabManager.tabs
        // With a requested subset, "skipped" counts against the tabs the user
        // actually picked — not every other open tab they deliberately left out.
        let candidateTabs = includeTabIDs.map { ids in allTabs.filter { ids.contains($0.id) } } ?? allTabs
        let eligibleTabs = candidateTabs.filter { tab in
            !tab.isPrivate && tab.internalPage == nil && !tab.showHomePage && tab.webView != nil
        }

        prepareProgress = PrepareProgress(extractedTabs: 0, totalTabs: eligibleTabs.count)
        defer { prepareProgress = nil }

        // Extract all tabs CONCURRENTLY: each call just awaits that webview's
        // JS evaluation inside WebKit, so fanning out lets five pages extract
        // in roughly one page's time instead of serially. The children are
        // MainActor like this method (webviews are main-thread objects — the
        // parallelism is in WebKit, not on this actor), and results carry
        // their slot index so tab order — and thus the [N] source numbering —
        // is preserved regardless of completion order.
        let extracted: [ResearchTabInput?] = await withTaskGroup(
            of: (Int, ResearchTabInput?).self
        ) { group in
            for (slot, tab) in eligibleTabs.enumerated() {
                group.addTask { @MainActor in
                    // Prefer the live page text.
                    var pageText = ""
                    var title = tab.title
                    if let webView = tab.webView,
                       let content = await PageAIService.extractPageText(from: webView),
                       !content.text.isEmpty {
                        pageText = content.text
                        if !content.title.isEmpty { title = content.title }
                    }

                    let text: String
                    if !pageText.isEmpty {
                        // Agent-opened result tabs are indexed under the web
                        // agent's per-tab budget so embedding stays a few
                        // seconds; the user's own tabs are never capped.
                        text = tab.isWebResearchTab
                            ? WebAgentIndexBudget.cappedText(pageText)
                            : pageText
                    } else if let snippet = tab.webResearchSnippet?
                        .trimmingCharacters(in: .whitespacesAndNewlines), !snippet.isEmpty {
                        // The page couldn't be extracted (bot-gated/heavy
                        // result pages that don't render text in a background
                        // webview). Fall back to DuckDuckGo's own result
                        // snippet so the result still contributes a citable
                        // source instead of being silently skipped.
                        text = "\(title)\n\(snippet)"
                    } else {
                        return (slot, nil)
                    }

                    return (slot, ResearchTabInput(
                        tabID: tab.id,
                        title: title,
                        url: tab.url,
                        text: text
                    ))
                }
            }
            var slots = [ResearchTabInput?](repeating: nil, count: eligibleTabs.count)
            for await (slot, input) in group {
                slots[slot] = input
                prepareProgress?.extractedTabs += 1
            }
            return slots
        }
        let inputs = extracted.compactMap { $0 }
        let extractionFailures = eligibleTabs.count - inputs.count

        skippedTabCount = (candidateTabs.count - eligibleTabs.count) + extractionFailures

        guard !inputs.isEmpty else {
            includedTabCount = 0
            isIndexed = false
            return
        }

        guard await retriever.buildIndex(tabs: inputs) else {
            includedTabCount = 0
            isIndexed = false
            return
        }

        includedTabCount = inputs.count
        isIndexed = true
        if engine == nil {
            // A restored conversation's first (re)build seeds the fresh
            // engine with the reopened transcript's recent turns, so
            // continuing it over the NEW index stays coherent.
            engine = PageAIService.makeResearchEngine(recentConversation: pendingRestoredReplay)
            if engine != nil { pendingRestoredReplay = nil }
            conversationEngine = engine == nil ? nil : SettingsManager.shared.aiEngine
        }
    }

    /// Loads a saved research conversation's transcript as the current
    /// conversation. Display-only: the original tabs/index/engine are NOT
    /// resurrected — `isIndexed` is dropped so the panel's next
    /// `prepare(tabManager:includeTabIDs:)` re-grounds on whatever tabs are
    /// CURRENTLY selected (or leaves the chat read-only via the existing
    /// unavailable states when there's nothing to index). The rebuilt engine
    /// is seeded with a replay of the restored turns.
    func restore(id: UUID, turns: [PageChatTurn]) {
        streamTask?.cancel()
        streamTask = nil
        isResponding = false
        conversationID = id
        self.turns = turns
        engine = nil
        conversationEngine = nil
        isIndexed = false
        pendingRestoredReplay = PageChatSession.recentConversationReplay(from: turns)
    }

    /// Clears the conversation and rebuilds the engine, keeping the current
    /// tab index (no re-gathering) — mirrors `PageChatSession.startNewChat`.
    func startNewChat() {
        streamTask?.cancel()
        streamTask = nil
        turns = []
        isResponding = false
        conversationID = UUID()
        pendingRestoredReplay = nil
        engine = isIndexed ? PageAIService.makeResearchEngine() : nil
        conversationEngine = engine == nil ? nil : SettingsManager.shared.aiEngine
    }

    /// Cancels the in-flight generation, keeping whatever partial answer has
    /// already streamed in — mirrors `PageChatSession.stop()`.
    func stop() {
        guard isResponding else { return }
        streamTask?.cancel()
        streamTask = nil
        isResponding = false
        guard let index = turns.lastIndex(where: { $0.isStreaming }) else { return }
        if turns[index].text.isEmpty {
            turns.remove(at: index)
        } else {
            turns[index].isStreaming = false
        }
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, canSend else { return }

        guard engine != nil else {
            turns.append(PageChatTurn(role: .error, text: "Ask This Page requires macOS 26 or later."))
            return
        }

        turns.append(PageChatTurn(role: .user, text: trimmed))
        let assistantTurn = PageChatTurn(role: .assistant, text: "", isStreaming: true)
        turns.append(assistantTurn)
        isResponding = true

        streamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performSend(message: trimmed, assistantID: assistantTurn.id)
            guard !Task.isCancelled else { return }
            self.isResponding = false
        }
    }

    private func performSend(message: String, assistantID: UUID) async {
        guard let engine else {
            removeTurn(id: assistantID)
            turns.append(PageChatTurn(role: .error, text: "Ask This Page requires macOS 26 or later."))
            return
        }

        guard let retrieved = await retriever.retrieve(query: message), !retrieved.isEmpty else {
            removeTurn(id: assistantID)
            turns.append(PageChatTurn(role: .error, text: "Couldn't find anything relevant to that question in the open tabs."))
            return
        }
        let candidateSources = TabsResearchService.distinctSources(in: retrieved)

        do {
            var finalText = ""
            let stream = PageAIService.streamResearchReply(engine: engine, question: message, chunks: retrieved)
            for try await partial in stream {
                guard !Task.isCancelled else { return }
                // Cumulative snapshot: split any reasoning-model think block
                // out each time. Citations are scanned over the ANSWER only —
                // a `[N]` mentioned inside the model's chain-of-thought isn't
                // a citation the user can see.
                let parts = ReasoningSplitter.split(partial)
                finalText = parts.answer
                updateTurn(id: assistantID) {
                    $0.reasoning = parts.reasoning
                    $0.text = parts.answer
                }
            }
            guard !Task.isCancelled else { return }
            let citedSources = TabsResearchService.citedSources(inAnswer: finalText, candidates: candidateSources)
            updateTurn(id: assistantID) {
                $0.isStreaming = false
                $0.sources = citedSources
            }
        } catch let error as PageAIError {
            guard !Task.isCancelled else { return }
            removeTurn(id: assistantID)
            turns.append(PageChatTurn(role: .error, text: error.errorDescription ?? "Something went wrong."))
        } catch {
            guard !Task.isCancelled else { return }
            removeTurn(id: assistantID)
            turns.append(PageChatTurn(role: .error, text: error.localizedDescription))
        }
    }

    private func updateTurn(id: UUID, _ mutate: (inout PageChatTurn) -> Void) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        mutate(&turns[index])
    }

    private func removeTurn(id: UUID) {
        turns.removeAll { $0.id == id }
    }
}
