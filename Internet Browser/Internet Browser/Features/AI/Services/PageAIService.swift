//
//  PageAIService.swift
//  Cherry Browser
//
//  On-device "Ask This Page" inference via Apple's Foundation Models
//  framework. Every Foundation Models symbol is macOS-26-only, so all use of
//  them is behind `@available(macOS 26.0, *)` / `if #available`. Callers on
//  older OSes (or with Apple Intelligence unavailable) get a plain `.failure`
//  with a human-readable reason instead of a crash.
//

import Foundation
import WebKit
#if canImport(FoundationModels)
import FoundationModels
#endif

enum PageAIAvailability: Equatable {
    case available
    case unsupportedOS
    case unavailable(reason: String)

    var isAvailable: Bool { self == .available }
}

enum PageAIError: LocalizedError {
    case notAvailable(String)
    case contextWindowExceeded
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAvailable(let reason):
            return reason
        case .contextWindowExceeded:
            return "This page is too long for the on-device model to process, even in chunks."
        case .generationFailed(let message):
            return message
        }
    }
}

struct PageSummaryResult {
    let summary: String
    let keyPoints: [String]
    let wasTruncated: Bool
}

struct PageAnswerResult {
    let answer: String
    let wasTruncated: Bool
}

/// Foundation Models entry point for the "Ask This Page" panel. Public API is
/// plain (no FoundationModels types leak out) so callers — including the
/// SwiftUI panel — don't need their own `@available` gating; every method
/// checks availability at runtime and fails gracefully below macOS 26.
@MainActor
enum PageAIService {

    static var availability: PageAIAvailability {
        switch SettingsManager.shared.aiEngine {
        case .apple:
            guard #available(macOS 26.0, *) else { return .unsupportedOS }
            #if canImport(FoundationModels)
            return currentAvailability()
            #else
            return .unsupportedOS
            #endif
        case .qwen:
            return qwenAvailability()
        }
    }

    static func extractPageText(from webView: WKWebView) async -> ExtractedPageContent? {
        await PageAIExtractor.extract(from: webView)
    }

    static func answer(question: String, pageText: String, pageTitle: String) async -> Result<PageAnswerResult, PageAIError> {
        switch SettingsManager.shared.aiEngine {
        case .apple:
            guard #available(macOS 26.0, *) else {
                return .failure(.notAvailable("Ask This Page requires macOS 26 or later."))
            }
            #if canImport(FoundationModels)
            return await answerOnDevice(question: question, pageText: pageText, pageTitle: pageTitle)
            #else
            return .failure(.notAvailable("Foundation Models isn't available in this build."))
            #endif
        case .qwen:
            #if canImport(MLXLLM)
            return await answerWithQwen(question: question, pageText: pageText, pageTitle: pageTitle)
            #else
            return .failure(.notAvailable("The local Qwen engine isn't available in this build."))
            #endif
        }
    }

    /// Text used to ground a chat session in the page, once, at session start.
    /// Prefers an already-generated summary (much cheaper on the token budget
    /// than raw page text) and falls back to a capped excerpt of the page.
    static func chatGroundingText(pageText: String, summary: PageSummaryResult?) -> String {
        if let summary, !summary.summary.isEmpty {
            var text = "Page summary: \(summary.summary)"
            if !summary.keyPoints.isEmpty {
                text += "\n\nKey points:\n" + summary.keyPoints.map { "- \($0)" }.joined(separator: "\n")
            }
            return text
        }
        return pageText.count > chatGroundingCap ? String(pageText.prefix(chatGroundingCap)) : pageText
    }

    /// The chat session's page grounding is baked ONCE into the persistent
    /// session instructions, so it must stay small: per-turn RAG retrieval
    /// (`chatRetrievalTopK` chunks) already supplies the relevant page content
    /// for each question, and a large baked-in prefix would permanently eat the
    /// 4096-token window — big/dense pages (e.g. GitHub) could then overflow on
    /// even a one-word message, which conversation trimming can't recover. This
    /// small cap is just a broad-question fallback; retrieval does the rest.
    static let chatGroundingCap = 1500

    /// Creates a fresh, page-grounded chat engine. `pageText` is kept
    /// alongside `grounding` (which only holds a summary or capped prefix)
    /// so each turn can retrieve the chunks most relevant to that turn's
    /// question from the full page. `recentConversation` optionally seeds the
    /// engine with a compact replay of the most recent turns — used to keep a
    /// chat's follow-up context alive across a sliding-window rebuild after a
    /// context-window overflow, without carrying the whole prior transcript
    /// forward. Returns `nil` below macOS 26 or without Foundation Models —
    /// callers treat `nil` as "chat isn't available" without needing to know
    /// why. The returned value is type-erased so this signature (and every
    /// other caller of it) stays free of Foundation Models types.
    static func makeChatEngine(pageTitle: String, pageText: String, grounding: String, recentConversation: String? = nil) -> AnyObject? {
        switch SettingsManager.shared.aiEngine {
        case .apple:
            guard #available(macOS 26.0, *) else { return nil }
            #if canImport(FoundationModels)
            return makeChatEngineOnDevice(pageTitle: pageTitle, pageText: pageText, grounding: grounding, recentConversation: recentConversation)
            #else
            return nil
            #endif
        case .qwen:
            #if canImport(MLXLLM)
            return makeChatEngineMLX(pageTitle: pageTitle, pageText: pageText, grounding: grounding, recentConversation: recentConversation)
            #else
            return nil
            #endif
        }
    }

    /// Sends one user turn to an engine produced by `makeChatEngine` and
    /// streams back the assistant's reply. Each element is the cumulative
    /// text so far (Foundation Models streams snapshots, not deltas) so
    /// callers can assign it straight to their bubble's text.
    static func streamChatReply(engine: AnyObject, message: String) -> AsyncThrowingStream<String, Error> {
        switch SettingsManager.shared.aiEngine {
        case .apple:
            guard #available(macOS 26.0, *) else {
                return AsyncThrowingStream { $0.finish(throwing: PageAIError.notAvailable("Ask This Page requires macOS 26 or later.")) }
            }
            #if canImport(FoundationModels)
            return streamChatReplyOnDevice(engine: engine, message: message)
            #else
            return AsyncThrowingStream { $0.finish(throwing: PageAIError.notAvailable("Foundation Models isn't available in this build.")) }
            #endif
        case .qwen:
            #if canImport(MLXLLM)
            return streamChatReplyMLX(engine: engine, message: message)
            #else
            return AsyncThrowingStream { $0.finish(throwing: PageAIError.notAvailable("The local Qwen engine isn't available in this build.")) }
            #endif
        }
    }

    /// Creates a fresh engine for the "All Tabs" research chat — a session
    /// instructed to synthesize an answer from source-labeled excerpts
    /// gathered across multiple open tabs and to cite them inline. Unlike
    /// `makeChatEngine`, no page text is baked in: each turn's grounding
    /// comes entirely from the source-tagged chunks passed to
    /// `streamResearchReply`, retrieved fresh per question by
    /// `TabsResearchService`. Returns `nil` below macOS 26 or without
    /// Foundation Models, same as `makeChatEngine`.
    static func makeResearchEngine() -> AnyObject? {
        switch SettingsManager.shared.aiEngine {
        case .apple:
            guard #available(macOS 26.0, *) else { return nil }
            #if canImport(FoundationModels)
            return ResearchChatEngine(instructions: researchInstructions)
            #else
            return nil
            #endif
        case .qwen:
            #if canImport(MLXLLM)
            guard LLMModelManager.shared.isDownloaded else { return nil }
            return MLXChatEngine(instructions: researchInstructions)
            #else
            return nil
            #endif
        }
    }

    /// Sends one research question to an engine produced by
    /// `makeResearchEngine`, grounded on `chunks` (already retrieved and
    /// ranked across all open tabs by the caller), and streams back the
    /// assistant's cumulative reply. Mirrors `streamChatReply`'s streaming
    /// shape exactly.
    static func streamResearchReply(engine: AnyObject, question: String, chunks: [ResearchChunk]) -> AsyncThrowingStream<String, Error> {
        switch SettingsManager.shared.aiEngine {
        case .apple:
            guard #available(macOS 26.0, *) else {
                return AsyncThrowingStream { $0.finish(throwing: PageAIError.notAvailable("Ask This Page requires macOS 26 or later.")) }
            }
            #if canImport(FoundationModels)
            return streamResearchReplyOnDevice(engine: engine, question: question, chunks: chunks)
            #else
            return AsyncThrowingStream { $0.finish(throwing: PageAIError.notAvailable("Foundation Models isn't available in this build.")) }
            #endif
        case .qwen:
            #if canImport(MLXLLM)
            return streamResearchReplyMLX(engine: engine, question: question, chunks: chunks)
            #else
            return AsyncThrowingStream { $0.finish(throwing: PageAIError.notAvailable("The local Qwen engine isn't available in this build.")) }
            #endif
        }
    }
}

/// RAG retrieval and prompt-building shared by both engines: they only
/// produce plain prompt STRINGS from model-agnostic pieces (`PageRetriever`,
/// chunk formatting), so both the Foundation Models path and the MLX path
/// call the exact same functions here rather than each rebuilding their own.
private extension PageAIService {

    /// Chat's per-turn retrieval topK, smaller than Q&A's
    /// `PageRetriever.defaultTopK`. A persistent chat session (Foundation
    /// Models' transcript, or MLX's KV-cache) effectively keeps every past
    /// turn's prompt around forever, so retrieved excerpts injected each turn
    /// accumulate across the conversation — unlike single-shot Q&A, which
    /// never re-sends anything. A smaller per-turn footprint keeps a
    /// multi-turn chat from overflowing its context window much sooner than
    /// the old blind-prefix behavior did.
    static let chatRetrievalTopK = 3

    /// Builds the per-turn prompt sent to the chat engine: retrieves the
    /// chunks of `pageText` most relevant to `message` and prepends them, so
    /// each question is grounded on the page sections that actually answer
    /// it rather than only the fixed instructions-level summary/prefix. If
    /// retrieval isn't usable (assets not ready, embedding failed, or the
    /// page is too short to chunk), falls back to sending the bare message —
    /// relying on the engine's fixed grounding instead.
    static func chatTurnPrompt(pageText: String, message: String) async -> String {
        guard !pageText.isEmpty else { return message }
        guard let retrieved = await PageRetriever.shared.retrieve(
            pageText: pageText,
            query: message,
            topK: chatRetrievalTopK
        ), !retrieved.isEmpty else {
            return message
        }
        let context = retrieved.map(\.text).joined(separator: "\n\n---\n\n")
        return """
        Most relevant page excerpts for this question:
        \(context)

        Question: \(message)
        """
    }

    /// Builds the per-question prompt for the research chat: every retrieved
    /// chunk is presented labeled with its source tab so the model can (and
    /// is instructed to) cite it inline as `[N]`.
    static func researchPrompt(question: String, chunks: [ResearchChunk]) -> String {
        let context = chunks
            .map { "[Source \($0.source.index) — \"\($0.source.title)\"]\n\($0.text)" }
            .joined(separator: "\n\n---\n\n")
        return """
        Relevant excerpts from open tabs:
        \(context)

        Question: \(question)
        """
    }

    static let chatInstructionsPrefix = """
    You are chatting with someone about a single web page, inside a browser side panel. \
    Answer ONLY using the page content provided below and any additional relevant excerpts \
    supplied alongside a question — never invent facts, names, numbers, or claims that \
    aren't present in them. If the answer isn't in the provided content, say so plainly \
    instead of guessing. Keep replies conversational and reasonably concise, and use the \
    earlier turns of this conversation as context for follow-up questions. Do not refer to \
    yourself by any name and do not describe yourself as an AI assistant; just answer the \
    question directly.
    """

    static func chatInstructions(pageTitle: String, grounding: String, recentConversation: String? = nil) -> String {
        var text = """
        \(chatInstructionsPrefix)

        Page title: \(pageTitle)

        Page content:
        \(grounding)
        """
        if let recentConversation, !recentConversation.isEmpty {
            text += """


            Recent conversation so far (older turns were trimmed to fit; use this for context on follow-up questions):
            \(recentConversation)
            """
        }
        return text
    }

    static let researchInstructions = """
    You answer questions by synthesizing information gathered from several currently open \
    browser tabs, for a browser side panel. Each excerpt you're given is labeled with the tab \
    it came from, like `[Source 2 — "Page Title"]`. Answer ONLY using the information present \
    in the supplied excerpts — never invent facts, names, numbers, or claims that aren't in \
    them, and never use outside knowledge. Cite the source of every concrete fact inline using \
    its bracketed number, for example: "The XPS 13 weighs 1.2 kg [2]." When sources disagree, \
    point out the disagreement and cite each side. If the excerpts don't contain the answer, say \
    so plainly instead of guessing. Keep replies conversational and reasonably concise, and use \
    earlier turns of this conversation as context for follow-up questions. Do not refer to \
    yourself by any name and do not describe yourself as an AI assistant; just answer the \
    question directly.
    """

    /// Q&A answers directly over raw page text (no map-reduce per the v1
    /// scope), so it gets a smaller, deliberate truncation cap of its own.
    /// Shared by both engines' single-shot `answer(question:pageText:pageTitle:)`.
    static let qaTextCap = 6000

    static let qaInstructions = """
    You answer questions about a single web page's content, for a browser side panel. Answer \
    ONLY using the page content provided in the prompt. If the answer is not present in that \
    content, say plainly that the page doesn't contain that information — never guess or use \
    outside knowledge. Keep answers concise and address the question directly. Do not refer to \
    yourself by any name and do not describe yourself as an AI assistant; just answer the \
    question directly.
    """

    /// Qwen's availability doesn't depend on macOS version or Apple
    /// Intelligence at all — only on whether MLX is linked into this build
    /// and whether the model weights have been downloaded yet.
    static func qwenAvailability() -> PageAIAvailability {
        guard LLMModelManager.isMLXImportable else {
            return .unavailable(reason: "The local Qwen engine isn't available in this build.")
        }
        guard LLMModelManager.shared.isDownloaded else {
            return .unavailable(reason: "The Qwen model hasn't been downloaded yet. Open Settings to download it.")
        }
        return .available
    }
}

#if canImport(FoundationModels)

@available(macOS 26.0, *)
private extension PageAIService {

    static func currentAvailability() -> PageAIAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            return .unavailable(reason: "This Mac doesn't support Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable(reason: "Turn on Apple Intelligence in System Settings to use Ask This Page.")
        case .unavailable(.modelNotReady):
            return .unavailable(reason: "The on-device model is still downloading. Try again in a bit.")
        case .unavailable:
            return .unavailable(reason: "The on-device model isn't available right now.")
        @unknown default:
            return .unavailable(reason: "The on-device model isn't available right now.")
        }
    }

    fileprivate nonisolated static func mapGenerationError(_ error: Error) -> PageAIError {
        if let generationError = error as? LanguageModelSession.GenerationError {
            switch generationError {
            case .exceededContextWindowSize:
                return .contextWindowExceeded
            default:
                return .generationFailed(generationError.localizedDescription)
            }
        }
        return .generationFailed(error.localizedDescription)
    }

    static func answerOnDevice(question: String, pageText: String, pageTitle: String) async -> Result<PageAnswerResult, PageAIError> {
        guard !pageText.isEmpty else {
            return .failure(.generationFailed("There's no readable content on this page to answer from."))
        }

        let workingText: String
        let wasTruncated: Bool
        if let retrieved = await PageRetriever.shared.retrieve(pageText: pageText, query: question),
           !retrieved.isEmpty {
            // Grounded on the most relevant sections rather than a prefix,
            // so there's nothing "truncated" about this answer.
            workingText = retrieved.map(\.text).joined(separator: "\n\n---\n\n")
            wasTruncated = false
        } else {
            wasTruncated = pageText.count > qaTextCap
            workingText = wasTruncated ? String(pageText.prefix(qaTextCap)) : pageText
        }

        do {
            let session = LanguageModelSession(instructions: qaInstructions)
            let prompt = """
            Page title: \(pageTitle)

            Page content:
            \(workingText)

            Question: \(question)
            """
            let response = try await session.respond(to: prompt)
            return .success(PageAnswerResult(answer: response.content, wasTruncated: wasTruncated))
        } catch {
            return .failure(mapGenerationError(error))
        }
    }

    /// `pageText` is the full extracted page text, kept on the engine so
    /// `streamChatReplyOnDevice` can retrieve turn-relevant chunks from it;
    /// `grounding` (a summary, or a capped prefix as a last resort) is baked
    /// into the session's fixed instructions as a light whole-page anchor
    /// that's always present, even on turns where retrieval finds nothing
    /// or isn't available. `recentConversation`, when supplied, is a compact
    /// replay of recent turns baked into the same fixed instructions — see
    /// `makeChatEngine`.
    static func makeChatEngineOnDevice(pageTitle: String, pageText: String, grounding: String, recentConversation: String? = nil) -> AnyObject? {
        guard !grounding.isEmpty else { return nil }
        return PageChatEngine(
            instructions: chatInstructions(pageTitle: pageTitle, grounding: grounding, recentConversation: recentConversation),
            pageText: pageText
        )
    }

    static func streamChatReplyOnDevice(engine: AnyObject, message: String) -> AsyncThrowingStream<String, Error> {
        guard let chatEngine = engine as? PageChatEngine else {
            return AsyncThrowingStream { $0.finish(throwing: PageAIError.generationFailed("This chat session is unavailable.")) }
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let prompt = await chatTurnPrompt(pageText: chatEngine.pageText, message: message)
                    for try await partial in chatEngine.stream(prompt: prompt) {
                        continuation.yield(partial)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func streamResearchReplyOnDevice(engine: AnyObject, question: String, chunks: [ResearchChunk]) -> AsyncThrowingStream<String, Error> {
        guard let researchEngine = engine as? ResearchChatEngine else {
            return AsyncThrowingStream { $0.finish(throwing: PageAIError.generationFailed("This research session is unavailable.")) }
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let prompt = researchPrompt(question: question, chunks: chunks)
                    for try await partial in researchEngine.stream(prompt: prompt) {
                        continuation.yield(partial)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Wraps the one Foundation Models type a chat conversation actually needs
/// to keep alive: a single `LanguageModelSession` whose transcript IS the
/// multi-turn memory. Deliberately the opposite of the map-reduce summarizer
/// above, which uses a fresh session per chunk — here reusing one session
/// across turns is the whole point, since that's what gives the model
/// memory of earlier turns in the conversation.
@available(macOS 26.0, *)
private final class PageChatEngine {
    let session: LanguageModelSession
    /// Full extracted page text, kept for per-turn retrieval — distinct from
    /// the (usually much shorter) grounding baked into `session`'s fixed
    /// instructions.
    let pageText: String

    init(instructions: String, pageText: String) {
        session = LanguageModelSession(instructions: instructions)
        self.pageText = pageText
    }
}

/// Wraps the "All Tabs" research chat's `LanguageModelSession`. Unlike
/// `PageChatEngine`, there's no single page's text to hold onto: each turn's
/// grounding comes from chunks retrieved fresh (across all indexed tabs) by
/// `TabsResearchService`, passed straight into `streamResearchReplyOnDevice`.
@available(macOS 26.0, *)
private final class ResearchChatEngine {
    let session: LanguageModelSession

    init(instructions: String) {
        session = LanguageModelSession(instructions: instructions)
    }
}

/// Thin conformance so `PageAIService` can eventually route by the
/// model-agnostic `LLMChatEngine` protocol instead of by concrete type.
/// Foundation Models streams cumulative snapshots already (`partial.content`
/// is the full reply so far), so there's no accumulation to do here — unlike
/// the MLX engine, which streams deltas.
@available(macOS 26.0, *)
extension PageChatEngine: LLMChatEngine {
    func stream(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await partial in session.streamResponse(to: prompt) {
                        continuation.yield(partial.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: PageAIService.mapGenerationError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@available(macOS 26.0, *)
extension ResearchChatEngine: LLMChatEngine {
    func stream(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await partial in session.streamResponse(to: prompt) {
                        continuation.yield(partial.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: PageAIService.mapGenerationError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

#endif

#if canImport(MLXLLM)

private extension PageAIService {

    static func answerWithQwen(question: String, pageText: String, pageTitle: String) async -> Result<PageAnswerResult, PageAIError> {
        guard !pageText.isEmpty else {
            return .failure(.generationFailed("There's no readable content on this page to answer from."))
        }
        guard LLMModelManager.shared.isDownloaded else {
            return .failure(.notAvailable("The Qwen model hasn't been downloaded yet. Open Settings to download it."))
        }

        let workingText: String
        let wasTruncated: Bool
        if let retrieved = await PageRetriever.shared.retrieve(pageText: pageText, query: question),
           !retrieved.isEmpty {
            workingText = retrieved.map(\.text).joined(separator: "\n\n---\n\n")
            wasTruncated = false
        } else {
            wasTruncated = pageText.count > qaTextCap
            workingText = wasTruncated ? String(pageText.prefix(qaTextCap)) : pageText
        }

        let prompt = """
        Page title: \(pageTitle)

        Page content:
        \(workingText)

        Question: \(question)
        """

        let engine = MLXChatEngine(instructions: qaInstructions)
        do {
            var finalText = ""
            for try await partial in engine.stream(prompt: prompt) {
                finalText = partial
            }
            return .success(PageAnswerResult(answer: finalText, wasTruncated: wasTruncated))
        } catch {
            return .failure(.generationFailed(error.localizedDescription))
        }
    }

    /// `pageText` is kept on the engine (see `MLXChatEngine.pageText`) so
    /// `streamChatReplyMLX` can retrieve turn-relevant chunks from it,
    /// mirroring `makeChatEngineOnDevice`.
    static func makeChatEngineMLX(pageTitle: String, pageText: String, grounding: String, recentConversation: String? = nil) -> AnyObject? {
        guard LLMModelManager.shared.isDownloaded, !grounding.isEmpty else { return nil }
        return MLXChatEngine(
            instructions: chatInstructions(pageTitle: pageTitle, grounding: grounding, recentConversation: recentConversation),
            pageText: pageText
        )
    }

    static func streamChatReplyMLX(engine: AnyObject, message: String) -> AsyncThrowingStream<String, Error> {
        guard let chatEngine = engine as? MLXChatEngine else {
            return AsyncThrowingStream { $0.finish(throwing: PageAIError.generationFailed("This chat session is unavailable.")) }
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let prompt = await chatTurnPrompt(pageText: chatEngine.pageText ?? "", message: message)
                    for try await partial in chatEngine.stream(prompt: prompt) {
                        continuation.yield(partial)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func streamResearchReplyMLX(engine: AnyObject, question: String, chunks: [ResearchChunk]) -> AsyncThrowingStream<String, Error> {
        guard let researchEngine = engine as? MLXChatEngine else {
            return AsyncThrowingStream { $0.finish(throwing: PageAIError.generationFailed("This research session is unavailable.")) }
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let prompt = researchPrompt(question: question, chunks: chunks)
                    for try await partial in researchEngine.stream(prompt: prompt) {
                        continuation.yield(partial)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

#endif
