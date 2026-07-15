//
//  PageChatSession.swift
//  Cherry Browser
//
//  Drives the "Ask This Page" chat: owns the conversation's turns and talks
//  to `PageAIService` for the actual on-device generation. The Foundation
//  Models session it talks to is type-erased behind `PageAIService`'s
//  `AnyObject` bridge, so this file needs no `canImport(FoundationModels)` /
//  `@available` gating of its own — it behaves the same shape on every OS,
//  and simply has no engine to talk to below macOS 26 (`send` reports that
//  as an inline error turn instead of doing nothing silently).
//

import Combine
import Foundation

struct PageChatTurn: Identifiable, Equatable {
    enum Role: Equatable {
        case user
        case assistant
        case error
    }

    let id = UUID()
    let role: Role
    var text: String
    var isStreaming: Bool = false
    /// The model's `<think>…</think>` chain-of-thought, split out of the raw
    /// stream by `ReasoningSplitter`. `nil` for engines that don't emit one
    /// (Apple Foundation Models) and for user/error turns.
    var reasoning: String? = nil
    /// Sources cited in this turn's answer, e.g. from the "All Tabs" research
    /// chat. Always empty for plain single-page chat turns.
    var sources: [ResearchSource] = []
}

@MainActor
final class PageChatSession: ObservableObject {
    @Published private(set) var turns: [PageChatTurn] = []
    @Published private(set) var isResponding = false
    /// Which AI engine setting the current conversation's engine was built
    /// with. The panel compares this against the live setting to hint that a
    /// mid-conversation engine switch only applies to the next new chat.
    @Published private(set) var conversationEngine: AIEngine?

    /// Whether the session is a GENERAL chat — no page grounding at all, the
    /// model answering from its own knowledge. Decides which engine
    /// `startNewChat` / `rebuildEngineForSlidingWindow` build, so New Chat
    /// and a context-overflow rebuild stay in the mode the conversation is in.
    private(set) var isGeneral = false

    private var pageTitle = ""
    private var pageText = ""
    private var groundingSummary: PageSummaryResult?
    private var engine: AnyObject?
    private var streamTask: Task<Void, Never>?

    /// Number of most-recent turns (user + assistant, ~3 exchanges) replayed
    /// into a rebuilt engine after a context-window overflow. See `send(_:)`.
    private static let slidingWindowReplayTurnCount = 6

    var canSend: Bool {
        !isResponding
    }

    deinit {
        streamTask?.cancel()
    }

    /// (Re)grounds the session in a page. A no-op if the page hasn't
    /// actually changed (and the session isn't leaving general mode), so
    /// callers can invoke this freely (e.g. from a SwiftUI `.task(id:)`)
    /// without resetting an in-progress conversation. Coming FROM general
    /// mode always reconfigures — the grounding fundamentally changed, so a
    /// fresh chat is expected, same as switching pages.
    func configure(pageTitle: String, pageText: String, summary: PageSummaryResult?) {
        guard isGeneral || pageTitle != self.pageTitle || pageText != self.pageText else { return }
        isGeneral = false
        self.pageTitle = pageTitle
        self.pageText = pageText
        self.groundingSummary = summary
        startNewChat()
    }

    /// Switches the session to GENERAL mode — no page grounding; the model
    /// answers from its own knowledge. A no-op if already general, so a live
    /// general conversation is never reset by re-fired configure tasks.
    /// Coming FROM a page always starts fresh, mirroring `configure`.
    func configureGeneral() {
        guard !isGeneral else { return }
        isGeneral = true
        pageTitle = ""
        pageText = ""
        groundingSummary = nil
        startNewChat()
    }

    func startNewChat() {
        streamTask?.cancel()
        streamTask = nil
        turns = []
        isResponding = false
        if isGeneral {
            engine = PageAIService.makeGeneralChatEngine()
        } else {
            let grounding = PageAIService.chatGroundingText(pageText: pageText, summary: groundingSummary)
            engine = PageAIService.makeChatEngine(pageTitle: pageTitle, pageText: pageText, grounding: grounding)
        }
        conversationEngine = engine == nil ? nil : SettingsManager.shared.aiEngine
    }

    /// Cancels the in-flight generation, keeping whatever partial answer has
    /// already streamed in (marked no-longer-streaming). A turn with no
    /// answer text yet is dropped entirely rather than left as an empty
    /// bubble. Safe to call when nothing is streaming.
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

        // Snapshot of every turn before this one, used only if this message
        // trips a context-window overflow and the engine needs rebuilding
        // with a replay of recent history — see `rebuildEngineForSlidingWindow`.
        let historyBeforeSend = turns

        turns.append(PageChatTurn(role: .user, text: trimmed))
        let assistantTurn = PageChatTurn(role: .assistant, text: "", isStreaming: true)
        turns.append(assistantTurn)
        isResponding = true

        streamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performSend(
                message: trimmed,
                assistantID: assistantTurn.id,
                history: historyBeforeSend,
                allowContextOverflowRetry: true
            )
            // A cancelled task is stale — e.g. superseded by startNewChat() mid-stream.
            // It must not clobber a newer send()'s isResponding = true.
            guard !Task.isCancelled else { return }
            self.isResponding = false
        }
    }

    /// Streams one reply into the turn at `assistantID`. On
    /// `.contextWindowExceeded`, and only while `allowContextOverflowRetry` is
    /// true, this rebuilds the engine with a trimmed sliding window of recent
    /// history and retries `message` exactly once (passing
    /// `allowContextOverflowRetry: false` into that retry) — so the chat
    /// never hard dead-ends, and the recursion is bounded to a single retry
    /// regardless of the message or page.
    private func performSend(
        message: String,
        assistantID: UUID,
        history: [PageChatTurn],
        allowContextOverflowRetry: Bool
    ) async {
        guard let engine else {
            removeTurn(id: assistantID)
            turns.append(PageChatTurn(role: .error, text: "Ask This Page requires macOS 26 or later."))
            return
        }

        do {
            let stream = PageAIService.streamChatReply(engine: engine, message: message)
            for try await partial in stream {
                guard !Task.isCancelled else { return }
                // Each partial is the cumulative reply so far; split the
                // reasoning-model think block out on every snapshot so the UI
                // can show "Thinking…" until the actual answer starts.
                let parts = ReasoningSplitter.split(partial)
                updateTurn(id: assistantID) {
                    $0.reasoning = parts.reasoning
                    $0.text = parts.answer
                }
            }
            guard !Task.isCancelled else { return }
            updateTurn(id: assistantID) { $0.isStreaming = false }
        } catch let error as PageAIError {
            guard !Task.isCancelled else { return }
            await handleFailure(
                error,
                message: message,
                assistantID: assistantID,
                history: history,
                allowContextOverflowRetry: allowContextOverflowRetry
            )
        } catch {
            guard !Task.isCancelled else { return }
            await handleFailure(
                .generationFailed(error.localizedDescription),
                message: message,
                assistantID: assistantID,
                history: history,
                allowContextOverflowRetry: allowContextOverflowRetry
            )
        }
    }

    private func handleFailure(
        _ error: PageAIError,
        message: String,
        assistantID: UUID,
        history: [PageChatTurn],
        allowContextOverflowRetry: Bool
    ) async {
        removeTurn(id: assistantID)
        switch error {
        case .contextWindowExceeded where allowContextOverflowRetry:
            rebuildEngineForSlidingWindow(history: history)
            guard engine != nil else {
                turns.append(PageChatTurn(role: .error, text: "Ask This Page requires macOS 26 or later."))
                return
            }
            let retryTurn = PageChatTurn(role: .assistant, text: "", isStreaming: true)
            turns.append(retryTurn)
            await performSend(
                message: message,
                assistantID: retryTurn.id,
                history: history,
                allowContextOverflowRetry: false
            )
        case .contextWindowExceeded:
            // Even a freshly rebuilt, minimally-windowed engine couldn't fit this
            // message — a soft inline notice, never a hard block; the chat stays usable.
            turns.append(PageChatTurn(
                role: .error,
                text: "That reply didn't fit in the on-device model's memory even after trimming earlier context. Try a shorter question, or start a new chat."
            ))
        case .notAvailable, .generationFailed:
            turns.append(PageChatTurn(role: .error, text: error.errorDescription ?? "Something went wrong."))
        }
    }

    /// Rebuilds `engine` from scratch (same recreation pattern as
    /// `startNewChat()`) seeded with a compact replay of the most recent
    /// exchanges from `history`, so follow-up context survives even though
    /// the old engine's full transcript is discarded. In page mode the page
    /// grounding is always re-supplied in the fresh instructions, so even a
    /// fully trimmed window still has the page; a general chat rebuilds with
    /// the general instructions and stays ungrounded.
    private func rebuildEngineForSlidingWindow(history: [PageChatTurn]) {
        let replay = Self.recentConversationReplay(from: history)
        // An overflow rebuild CONTINUES the same conversation, so it must stay
        // on the engine the conversation was built under — not the live
        // setting, which the user may have switched mid-chat (that switch
        // only applies to the next new chat). Likewise it stays in the mode
        // the conversation is in: a general chat rebuilds as general.
        let rebuildEngine = conversationEngine ?? SettingsManager.shared.aiEngine
        if isGeneral {
            engine = PageAIService.makeGeneralChatEngine(recentConversation: replay, engine: rebuildEngine)
        } else {
            let grounding = PageAIService.chatGroundingText(pageText: pageText, summary: groundingSummary)
            engine = PageAIService.makeChatEngine(
                pageTitle: pageTitle,
                pageText: pageText,
                grounding: grounding,
                recentConversation: replay,
                engine: rebuildEngine
            )
        }
        conversationEngine = engine == nil ? nil : rebuildEngine
    }

    /// Formats the last `slidingWindowReplayTurnCount` non-error, non-streaming
    /// turns as a compact "Speaker: text" transcript for seeding a rebuilt
    /// engine's instructions.
    private static func recentConversationReplay(from history: [PageChatTurn]) -> String? {
        let replayable = history.filter { $0.role != .error && !$0.isStreaming }
        guard !replayable.isEmpty else { return nil }
        return replayable.suffix(slidingWindowReplayTurnCount)
            .map { turn in "\(turn.role == .user ? "User" : "Assistant"): \(turn.text)" }
            .joined(separator: "\n")
    }

    private func updateTurn(id: UUID, _ mutate: (inout PageChatTurn) -> Void) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        mutate(&turns[index])
    }

    private func removeTurn(id: UUID) {
        turns.removeAll { $0.id == id }
    }
}
