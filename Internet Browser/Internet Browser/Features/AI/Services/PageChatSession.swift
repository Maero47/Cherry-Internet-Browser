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
}

@MainActor
final class PageChatSession: ObservableObject {
    @Published private(set) var turns: [PageChatTurn] = []
    @Published private(set) var isResponding = false
    @Published private(set) var isBlockedByContextLimit = false

    private var pageTitle = ""
    private var pageText = ""
    private var groundingSummary: PageSummaryResult?
    private var engine: AnyObject?
    private var streamTask: Task<Void, Never>?

    var canSend: Bool {
        !isResponding && !isBlockedByContextLimit
    }

    deinit {
        streamTask?.cancel()
    }

    /// (Re)grounds the session in a page. A no-op if the page hasn't
    /// actually changed, so callers can invoke this freely (e.g. from a
    /// SwiftUI `.task(id:)`) without resetting an in-progress conversation.
    func configure(pageTitle: String, pageText: String, summary: PageSummaryResult?) {
        guard pageTitle != self.pageTitle || pageText != self.pageText else { return }
        self.pageTitle = pageTitle
        self.pageText = pageText
        self.groundingSummary = summary
        startNewChat()
    }

    func startNewChat() {
        streamTask?.cancel()
        streamTask = nil
        turns = []
        isResponding = false
        isBlockedByContextLimit = false
        let grounding = PageAIService.chatGroundingText(pageText: pageText, summary: groundingSummary)
        engine = PageAIService.makeChatEngine(pageTitle: pageTitle, grounding: grounding)
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, canSend else { return }

        guard let engine else {
            turns.append(PageChatTurn(role: .error, text: "Ask This Page requires macOS 26 or later."))
            return
        }

        turns.append(PageChatTurn(role: .user, text: trimmed))
        let assistantTurn = PageChatTurn(role: .assistant, text: "", isStreaming: true)
        let assistantID = assistantTurn.id
        turns.append(assistantTurn)
        isResponding = true

        streamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let stream = PageAIService.streamChatReply(engine: engine, message: trimmed)
                for try await partial in stream {
                    self.updateTurn(id: assistantID) { $0.text = partial }
                }
                guard !Task.isCancelled else { return }
                self.updateTurn(id: assistantID) { $0.isStreaming = false }
            } catch let error as PageAIError {
                guard !Task.isCancelled else { return }
                self.handleFailure(error, assistantID: assistantID)
            } catch {
                guard !Task.isCancelled else { return }
                self.handleFailure(.generationFailed(error.localizedDescription), assistantID: assistantID)
            }
            // A cancelled task is stale — e.g. superseded by startNewChat() mid-stream.
            // It must not clobber a newer send()'s isResponding = true.
            guard !Task.isCancelled else { return }
            self.isResponding = false
        }
    }

    private func handleFailure(_ error: PageAIError, assistantID: UUID) {
        removeTurn(id: assistantID)
        switch error {
        case .contextWindowExceeded:
            turns.append(PageChatTurn(
                role: .error,
                text: "This chat got too long for the on-device model to keep in memory. Start a new chat to keep asking questions."
            ))
            isBlockedByContextLimit = true
        case .notAvailable, .generationFailed:
            turns.append(PageChatTurn(role: .error, text: error.errorDescription ?? "Something went wrong."))
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
