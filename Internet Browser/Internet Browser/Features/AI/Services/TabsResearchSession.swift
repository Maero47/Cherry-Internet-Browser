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
    func prepare(tabManager: TabManager) async {
        guard !isPreparing else { return }
        isPreparing = true
        defer {
            isPreparing = false
            hasPrepared = true
        }

        let allTabs = tabManager.tabs
        let eligibleTabs = allTabs.filter { tab in
            !tab.isPrivate && tab.internalPage == nil && !tab.showHomePage && tab.webView != nil
        }

        var inputs: [ResearchTabInput] = []
        var extractionFailures = 0
        for tab in eligibleTabs {
            guard let webView = tab.webView,
                  let content = await PageAIService.extractPageText(from: webView),
                  !content.text.isEmpty else {
                extractionFailures += 1
                continue
            }
            inputs.append(ResearchTabInput(
                tabID: tab.id,
                title: content.title.isEmpty ? tab.title : content.title,
                url: tab.url,
                text: content.text
            ))
        }

        skippedTabCount = (allTabs.count - eligibleTabs.count) + extractionFailures

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
            engine = PageAIService.makeResearchEngine()
        }
    }

    /// Clears the conversation and rebuilds the engine, keeping the current
    /// tab index (no re-gathering) — mirrors `PageChatSession.startNewChat`.
    func startNewChat() {
        streamTask?.cancel()
        streamTask = nil
        turns = []
        isResponding = false
        engine = isIndexed ? PageAIService.makeResearchEngine() : nil
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
                finalText = partial
                updateTurn(id: assistantID) { $0.text = partial }
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
