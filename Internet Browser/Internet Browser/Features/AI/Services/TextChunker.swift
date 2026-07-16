//
//  TextChunker.swift
//  Cherry Browser
//

import Foundation

/// Splits long page text into model-sized chunks. Two shapes live here:
/// `chunk` — plain paragraph packing for map-reduce summarization — and
/// `retrievalChunks` — sentence-aware packing with overlap, built for the
/// RAG index, where a fact spanning a chunk boundary must not be lost to it.
enum TextChunker {
    static func chunk(_ text: String, maxChars: Int) -> [String] {
        guard text.count > maxChars else {
            return text.isEmpty ? [] : [text]
        }

        var chunks: [String] = []
        var current = ""

        for paragraph in text.components(separatedBy: "\n\n") {
            if paragraph.count > maxChars {
                if !current.isEmpty {
                    chunks.append(current)
                    current = ""
                }
                chunks.append(contentsOf: splitLong(paragraph, maxChars: maxChars))
                continue
            }

            let candidate = current.isEmpty ? paragraph : current + "\n\n" + paragraph
            if candidate.count > maxChars {
                chunks.append(current)
                current = paragraph
            } else {
                current = candidate
            }
        }

        if !current.isEmpty {
            chunks.append(current)
        }

        return chunks
    }

    /// Splits `text` into retrieval-sized chunks that (a) prefer sentence and
    /// paragraph boundaries over hard mid-word cuts, and (b) overlap: each
    /// chunk starts with the tail sentences (up to `overlapChars`) of the one
    /// before it, so an answer spanning a boundary appears whole in at least
    /// one chunk. A chunk stays within `targetChars` of NEW content — the
    /// carried overlap can push its total length up to roughly
    /// `targetChars + overlapChars`, which callers must budget for against
    /// the embedder's per-request limit. Sentences longer than `targetChars`
    /// are hard-split as a last resort (`splitLong`), same as `chunk`.
    nonisolated static func retrievalChunks(_ text: String, targetChars: Int, overlapChars: Int) -> [String] {
        guard text.count > targetChars else {
            return text.isEmpty ? [] : [text]
        }

        var units: [String] = []
        for unit in sentenceUnits(text) {
            if unit.count > targetChars {
                units.append(contentsOf: splitLong(unit, maxChars: targetChars))
            } else {
                units.append(unit)
            }
        }

        var chunks: [String] = []
        var current: [String] = []
        var currentCount = 0
        // Whether `current` holds anything beyond the overlap seed — a chunk
        // is only ever flushed once it has NEW content, so no chunk can be a
        // pure duplicate of the previous chunk's tail.
        var hasNewContent = false

        func flush() {
            let joined = current.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { chunks.append(joined) }
        }

        for unit in units {
            if hasNewContent, currentCount + unit.count > targetChars {
                flush()
                var overlap: [String] = []
                var overlapCount = 0
                for previous in current.reversed() {
                    guard overlapCount + previous.count <= overlapChars else { break }
                    overlap.insert(previous, at: 0)
                    overlapCount += previous.count
                }
                current = overlap
                currentCount = overlapCount
                hasNewContent = false
            }
            current.append(unit)
            currentCount += unit.count
            hasNewContent = true
        }
        if hasNewContent { flush() }

        return chunks
    }

    private static let sentenceTerminators: Set<Character> = [".", "!", "?", "…", "\n"]

    /// Splits `text` into sentence-ish units, each RETAINING its original
    /// trailing terminator and whitespace so concatenating the units
    /// reproduces the text exactly. A unit ends after a terminator
    /// (`.`, `!`, `?`, `…`, or a newline — which also covers headings and
    /// list items) once at least one whitespace character follows it, so
    /// decimals like "3.14" never split. Deliberately simple and
    /// deterministic — boundaries only need to be sentence-ISH for chunk
    /// packing, not linguistically perfect.
    nonisolated static func sentenceUnits(_ text: String) -> [String] {
        var units: [String] = []
        var current = ""
        var terminatorSeen = false
        var whitespaceAfterTerminator = false

        for character in text {
            if terminatorSeen, whitespaceAfterTerminator, !character.isWhitespace {
                units.append(current)
                current = ""
                terminatorSeen = false
                whitespaceAfterTerminator = false
            }
            current.append(character)
            if sentenceTerminators.contains(character) {
                terminatorSeen = true
                // A newline is terminator and whitespace at once: the very
                // next non-whitespace character starts a new unit.
                whitespaceAfterTerminator = character.isWhitespace
            } else if character.isWhitespace {
                if terminatorSeen { whitespaceAfterTerminator = true }
            } else {
                terminatorSeen = false
                whitespaceAfterTerminator = false
            }
        }
        if !current.isEmpty { units.append(current) }
        return units
    }

    /// Hard-splits a single paragraph that's already longer than a chunk on its own.
    private static func splitLong(_ text: String, maxChars: Int) -> [String] {
        var pieces: [String] = []
        var remainder = Substring(text)
        while remainder.count > maxChars {
            let cut = remainder.index(remainder.startIndex, offsetBy: maxChars)
            pieces.append(String(remainder[..<cut]))
            remainder = remainder[cut...]
        }
        if !remainder.isEmpty {
            pieces.append(String(remainder))
        }
        return pieces
    }
}
