//
//  LLMChatEngine.swift
//  Cherry Browser
//

import Foundation

/// Model-agnostic streaming contract every chat engine — Foundation Models
/// or MLX — conforms to, so `PageAIService` can route by protocol instead of
/// by concrete type. Every yielded value is the CUMULATIVE reply text so far,
/// never a delta: `PageChatSession`/`TabsResearchSession` assign each one
/// straight to a bubble's text (`turn.text = partial`).
protocol LLMChatEngine: AnyObject {
    func stream(prompt: String) -> AsyncThrowingStream<String, Error>
}
