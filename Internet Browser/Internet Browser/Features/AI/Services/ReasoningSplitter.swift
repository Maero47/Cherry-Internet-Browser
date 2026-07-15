//
//  ReasoningSplitter.swift
//  Cherry Browser
//
//  Splits a reasoning model's raw reply into its `<think>…</think>` block and
//  the visible answer. Qwen3 emits its chain-of-thought inside `<think>` tags
//  before the actual answer; Apple's Foundation Models never do, so replies
//  without the tag pass through untouched (`reasoning == nil`).
//
//  Streaming contract: both engines stream CUMULATIVE snapshots, so this is
//  called on the full text-so-far each time. Deliberately uses plain
//  `range(of:)` on the literal tags — a regex over a partial snapshot could
//  mis-handle a tag that hasn't fully arrived yet, whereas a literal match
//  simply doesn't match until the tag is complete.
//

import Foundation

/// `nonisolated`: pure string logic with no state, callable from any actor
/// (the module builds with default-MainActor isolation — see
/// `MLXStreamAccumulator` for the same pattern).
nonisolated enum ReasoningSplitter {

    private static let openTag = "<think>"
    private static let closeTag = "</think>"

    /// Splits `raw` into `(reasoning, answer)`:
    /// - No `<think>` tag → `(nil, raw)` — non-reasoning engines are unaffected.
    /// - `<think>` but no `</think>` yet (mid-stream, still thinking) →
    ///   reasoning is everything after the open tag (trimmed); the answer is
    ///   whatever preceded the tag (usually empty).
    /// - Both tags → reasoning is the trimmed text between them; the answer is
    ///   everything after `</think>` with leading whitespace trimmed (plus any
    ///   text that preceded `<think>`, which some models emit).
    ///
    /// When the open tag is present, `reasoning` is non-nil even if the block
    /// is empty so far — callers hide empty reasoning in the UI.
    static func split(_ raw: String) -> (reasoning: String?, answer: String) {
        guard let openRange = raw.range(of: openTag, options: .caseInsensitive) else {
            return (nil, raw)
        }

        let beforeOpen = String(raw[..<openRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let afterOpen = raw[openRange.upperBound...]

        guard let closeRange = afterOpen.range(of: closeTag, options: .caseInsensitive) else {
            // Mid-stream: the model is still inside its thinking block.
            let reasoning = String(afterOpen).trimmingCharacters(in: .whitespacesAndNewlines)
            return (reasoning, beforeOpen)
        }

        let reasoning = String(afterOpen[..<closeRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var answer = String(afterOpen[closeRange.upperBound...])
        // Only LEADING whitespace is trimmed: mid-stream answers legitimately
        // end in whitespace that the next snapshot will extend.
        while let first = answer.first, first.isWhitespace {
            answer.removeFirst()
        }
        if !beforeOpen.isEmpty {
            answer = answer.isEmpty ? beforeOpen : "\(beforeOpen)\n\(answer)"
        }
        return (reasoning, answer)
    }
}
