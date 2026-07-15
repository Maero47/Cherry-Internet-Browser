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
        guard #available(macOS 26.0, *) else { return .unsupportedOS }
        #if canImport(FoundationModels)
        return currentAvailability()
        #else
        return .unsupportedOS
        #endif
    }

    static func extractPageText(from webView: WKWebView) async -> ExtractedPageContent? {
        await PageAIExtractor.extract(from: webView)
    }

    static func summarize(pageText: String, pageTitle: String) async -> Result<PageSummaryResult, PageAIError> {
        guard #available(macOS 26.0, *) else {
            return .failure(.notAvailable("Ask This Page requires macOS 26 or later."))
        }
        #if canImport(FoundationModels)
        return await summarizeOnDevice(pageText: pageText, pageTitle: pageTitle)
        #else
        return .failure(.notAvailable("Foundation Models isn't available in this build."))
        #endif
    }

    static func answer(question: String, pageText: String, pageTitle: String) async -> Result<PageAnswerResult, PageAIError> {
        guard #available(macOS 26.0, *) else {
            return .failure(.notAvailable("Ask This Page requires macOS 26 or later."))
        }
        #if canImport(FoundationModels)
        return await answerOnDevice(question: question, pageText: pageText, pageTitle: pageTitle)
        #else
        return .failure(.notAvailable("Foundation Models isn't available in this build."))
        #endif
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
        return pageText.count > qaTextCap ? String(pageText.prefix(qaTextCap)) : pageText
    }

    /// Creates a fresh, page-grounded chat engine. `pageText` is kept
    /// alongside `grounding` (which only holds a summary or capped prefix)
    /// so each turn can retrieve the chunks most relevant to that turn's
    /// question from the full page. Returns `nil` below macOS 26 or without
    /// Foundation Models — callers treat `nil` as "chat isn't available"
    /// without needing to know why. The returned value is type-erased so
    /// this signature (and every other caller of it) stays free of
    /// Foundation Models types.
    static func makeChatEngine(pageTitle: String, pageText: String, grounding: String) -> AnyObject? {
        guard #available(macOS 26.0, *) else { return nil }
        #if canImport(FoundationModels)
        return makeChatEngineOnDevice(pageTitle: pageTitle, pageText: pageText, grounding: grounding)
        #else
        return nil
        #endif
    }

    /// Sends one user turn to an engine produced by `makeChatEngine` and
    /// streams back the assistant's reply. Each element is the cumulative
    /// text so far (Foundation Models streams snapshots, not deltas) so
    /// callers can assign it straight to their bubble's text.
    static func streamChatReply(engine: AnyObject, message: String) -> AsyncThrowingStream<String, Error> {
        guard #available(macOS 26.0, *) else {
            return AsyncThrowingStream { $0.finish(throwing: PageAIError.notAvailable("Ask This Page requires macOS 26 or later.")) }
        }
        #if canImport(FoundationModels)
        return streamChatReplyOnDevice(engine: engine, message: message)
        #else
        return AsyncThrowingStream { $0.finish(throwing: PageAIError.notAvailable("Foundation Models isn't available in this build.")) }
        #endif
    }
}

#if canImport(FoundationModels)

@available(macOS 26.0, *)
@Generable
struct GeneratedPageSummary {
    @Guide(description: "A concise, neutral 2 to 4 sentence summary of the page's main content, in the same language as the page.")
    let summary: String
    @Guide(description: "3 to 6 short, concrete key points from the page — specific facts, claims, or takeaways, not generic filler.")
    let keyPoints: [String]
}

@available(macOS 26.0, *)
private extension PageAIService {

    /// Per-chunk budget for map-reduce summarization. Comfortably under the
    /// 4096-token window once instructions + prompt scaffolding are added
    /// (roughly 4 chars/token for English, so ~2800 chars ≈ 700 tokens).
    static let chunkMaxChars = 2800
    /// At most this many chunks feed the map step for one summary. Longer
    /// pages are deliberately truncated before chunking rather than left
    /// unbounded, since the reduce step also has to fit in one context window.
    static let maxChunksForSummary = 12
    /// Q&A answers directly over raw page text (no map-reduce per the v1
    /// scope), so it gets a smaller, deliberate truncation cap of its own.
    static let qaTextCap = 6000

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

    static let chunkSummaryInstructions = """
    You are condensing one excerpt from a single web page into short factual notes, as part \
    of summarizing the whole page. Only use information present in the excerpt — never invent \
    facts, and do not add outside knowledge. Reply with 2 to 4 sentences capturing the concrete \
    facts, names, numbers, and claims in the excerpt. If the excerpt is boilerplate/navigation \
    with no real content, reply exactly: "No substantive content in this excerpt."
    """

    static let finalSummaryInstructions = """
    You write concise, neutral summaries of web pages for a browser side panel. Base the summary \
    and key points ONLY on the supplied content — never invent facts, names, numbers, or claims \
    that aren't present in it. If the supplied content has little real information, say so \
    plainly in the summary instead of padding it out.
    """

    static let qaInstructions = """
    You answer questions about a single web page's content, for a browser side panel. Answer \
    ONLY using the page content provided in the prompt. If the answer is not present in that \
    content, say plainly that the page doesn't contain that information — never guess or use \
    outside knowledge. Keep answers concise and address the question directly.
    """

    static func mapGenerationError(_ error: Error) -> PageAIError {
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

    static func summarizeOnDevice(pageText: String, pageTitle: String) async -> Result<PageSummaryResult, PageAIError> {
        let cap = chunkMaxChars * maxChunksForSummary
        let wasTruncated = pageText.count > cap
        let workingText = wasTruncated ? String(pageText.prefix(cap)) : pageText
        let chunks = TextChunker.chunk(workingText, maxChars: chunkMaxChars)

        guard !chunks.isEmpty else {
            return .failure(.generationFailed("There's no readable content on this page to summarize."))
        }

        do {
            let condensed: String
            if chunks.count == 1 {
                condensed = chunks[0]
            } else {
                var notes: [String] = []
                for chunk in chunks {
                    // A fresh session per chunk is deliberate: LanguageModelSession
                    // accumulates a transcript, so reusing one session across chunks
                    // would layer each chunk's prompt+response on top of the last,
                    // growing cumulative context roughly linearly with chunk count
                    // and blowing past the 4096-token window well before the
                    // maxChunksForSummary cap — exactly the long-page case chunking
                    // exists to handle. Each chunk must be summarized in isolation.
                    let mapSession = LanguageModelSession(instructions: chunkSummaryInstructions)
                    let prompt = "Page title: \(pageTitle)\n\nExcerpt:\n\(chunk)"
                    let response = try await mapSession.respond(to: prompt)
                    notes.append(response.content)
                }
                condensed = notes.enumerated()
                    .map { "Excerpt \($0.offset + 1) notes: \($0.element)" }
                    .joined(separator: "\n\n")
            }

            let reduceSession = LanguageModelSession(instructions: finalSummaryInstructions)
            let reducePrompt = """
            Page title: \(pageTitle)

            Content to summarize (raw page text, or condensed notes from a longer page):

            \(condensed)
            """
            let result = try await reduceSession.respond(to: reducePrompt, generating: GeneratedPageSummary.self)
            return .success(PageSummaryResult(
                summary: result.content.summary,
                keyPoints: result.content.keyPoints,
                wasTruncated: wasTruncated
            ))
        } catch {
            return .failure(mapGenerationError(error))
        }
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

    static let chatInstructionsPrefix = """
    You are chatting with someone about a single web page, inside a browser side panel. \
    Answer ONLY using the page content provided below and any additional relevant excerpts \
    supplied alongside a question — never invent facts, names, numbers, or claims that \
    aren't present in them. If the answer isn't in the provided content, say so plainly \
    instead of guessing. Keep replies conversational and reasonably concise, and use the \
    earlier turns of this conversation as context for follow-up questions.
    """

    static func chatInstructions(pageTitle: String, grounding: String) -> String {
        """
        \(chatInstructionsPrefix)

        Page title: \(pageTitle)

        Page content:
        \(grounding)
        """
    }

    /// `pageText` is the full extracted page text, kept on the engine so
    /// `streamChatReplyOnDevice` can retrieve turn-relevant chunks from it;
    /// `grounding` (a summary, or a capped prefix as a last resort) is baked
    /// into the session's fixed instructions as a light whole-page anchor
    /// that's always present, even on turns where retrieval finds nothing
    /// or isn't available.
    static func makeChatEngineOnDevice(pageTitle: String, pageText: String, grounding: String) -> AnyObject? {
        guard !grounding.isEmpty else { return nil }
        return PageChatEngine(
            instructions: chatInstructions(pageTitle: pageTitle, grounding: grounding),
            pageText: pageText
        )
    }

    /// Chat's per-turn retrieval topK, smaller than Q&A's
    /// `PageRetriever.defaultTopK`. Chat's persistent `LanguageModelSession`
    /// keeps every past turn's prompt in its transcript forever, so retrieved
    /// excerpts injected each turn accumulate across the conversation —
    /// unlike single-shot Q&A, which never re-sends anything. A smaller
    /// per-turn footprint keeps a multi-turn chat from hitting
    /// `.exceededContextWindowSize` much sooner than the old blind-prefix
    /// behavior did.
    static let chatRetrievalTopK = 3

    /// Builds the per-turn prompt sent to the chat session: retrieves the
    /// chunks of `pageText` most relevant to `message` and prepends them, so
    /// each question is grounded on the page sections that actually answer
    /// it rather than only the fixed instructions-level summary/prefix. If
    /// retrieval isn't usable (assets not ready, embedding failed, or the
    /// page is too short to chunk), falls back to sending the bare message —
    /// identical to today's behavior, relying on the engine's fixed grounding.
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

    static func streamChatReplyOnDevice(engine: AnyObject, message: String) -> AsyncThrowingStream<String, Error> {
        guard let chatEngine = engine as? PageChatEngine else {
            return AsyncThrowingStream { $0.finish(throwing: PageAIError.generationFailed("This chat session is unavailable.")) }
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let prompt = await chatTurnPrompt(pageText: chatEngine.pageText, message: message)
                    let stream = chatEngine.session.streamResponse(to: prompt)
                    for try await partial in stream {
                        continuation.yield(partial.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: mapGenerationError(error))
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

#endif
