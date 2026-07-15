//
//  MLXChatEngine.swift
//  Cherry Browser
//
//  On-device chat via MLX Swift (Qwen3-8B, 4-bit). Mirrors the shape of the
//  Foundation Models engines in PageAIService.swift (one persistent session
//  per conversation, holding that conversation's multi-turn memory) but
//  behind `#if canImport(MLXLLM)` instead of macOS-26 availability, since MLX
//  has no OS-version gate — only "is the package linked" and "is the model
//  downloaded".
//

import Foundation

#if canImport(MLXLLM)
import MLXLLM
import MLXLMCommon

enum MLXEngineError: LocalizedError {
    case modelNotDownloaded

    var errorDescription: String? {
        switch self {
        case .modelNotDownloaded:
            return "The Qwen model hasn't been downloaded yet. Go to Settings to download it."
        }
    }
}

/// Loads and caches the one `ModelContainer` (the multi-GB weights) shared by
/// every `MLXChatEngine` instance app-wide — loading it is expensive, so it
/// only happens once, lazily, on first use, regardless of how many chat or
/// research conversations are opened afterward.
actor MLXModelLoader {
    static let shared = MLXModelLoader()

    private var container: ModelContainer?

    private init() {}

    func loadedContainer() async throws -> ModelContainer {
        if let container {
            return container
        }
        guard LLMModelManager.weightsExistOnDisk() else {
            throw MLXEngineError.modelNotDownloaded
        }
        let loaded = try await LLMModelFactory.shared.loadContainer(
            hub: LLMModelManager.hubApi,
            configuration: LLMRegistry.qwen3_8b_4bit
        )
        container = loaded
        return loaded
    }
}

/// Turns a stream of token DELTAS (what MLX's `ChatSession` yields) into the
/// cumulative snapshots every `LLMChatEngine` must produce. Pulled out as its
/// own tiny value type so the accumulation logic is unit-testable without a
/// model.
struct MLXStreamAccumulator {
    private(set) var text: String = ""

    mutating func append(_ delta: String) -> String {
        text += delta
        return text
    }
}

/// Runs Qwen3-8B inference. A plain (non-`MainActor`) `actor` — mirroring
/// `PageRetriever`'s rationale — so generation (real CPU/Metal work) never
/// blocks the UI; callers already `await` into it from async contexts.
///
/// Foundation Models keeps multi-turn memory implicitly in
/// `LanguageModelSession`'s transcript; MLX has no equivalent, so this actor
/// keeps that memory explicitly: one `ChatSession` per conversation, created
/// once and reused for every turn, whose internal KV-cache is what actually
/// carries the model's memory of earlier turns forward (mirrors how
/// `PageChatEngine`/`ResearchChatEngine` reuse one `LanguageModelSession`).
///
/// `ChatSession.streamResponse(to:)` replaces its outgoing message with just
/// the latest turn each call (by design — it relies on the KV-cache already
/// holding prior turns rather than resending them), which means a
/// `ChatSession`-level `instructions` string would only ever reach the model
/// if fed in on that first turn. To not depend on that, this engine folds
/// `instructions` into the prompt text itself, once, on the conversation's
/// first turn only — after that, the model's own KV-cache carries the
/// grounding forward exactly like every other earlier turn.
actor MLXChatEngine {
    private let instructions: String?
    private var session: ChatSession?
    private var isFirstTurn = true

    init(instructions: String?) {
        self.instructions = instructions
    }

    /// Pure logic, split out for testability: whether/how to fold
    /// instructions into a given turn's prompt.
    static func turnPrompt(message: String, instructions: String?, isFirstTurn: Bool) -> String {
        guard isFirstTurn, let instructions, !instructions.isEmpty else { return message }
        return "\(instructions)\n\n\(message)"
    }

    private func loadedSession() async throws -> ChatSession {
        if let session {
            return session
        }
        let container = try await MLXModelLoader.shared.loadedContainer()
        let created = ChatSession(container)
        session = created
        return created
    }

    private func rawStream(prompt: String) async throws -> AsyncThrowingStream<String, Error> {
        let session = try await loadedSession()
        let fullPrompt = Self.turnPrompt(message: prompt, instructions: instructions, isFirstTurn: isFirstTurn)
        isFirstTurn = false
        return session.streamResponse(to: fullPrompt)
    }
}

extension MLXChatEngine: LLMChatEngine {
    nonisolated func stream(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let deltas = try await self.rawStream(prompt: prompt)
                    var accumulator = MLXStreamAccumulator()
                    for try await delta in deltas {
                        continuation.yield(accumulator.append(delta))
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
