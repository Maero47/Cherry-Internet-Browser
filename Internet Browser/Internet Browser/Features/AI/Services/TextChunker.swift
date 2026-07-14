//
//  TextChunker.swift
//  Cherry Browser
//

import Foundation

/// Splits long page text into model-sized chunks for map-reduce summarization.
/// Foundation Models sessions have a 4096-token context window, so a chunk
/// needs to stay well under that once combined with instructions and prompt
/// scaffolding — a few thousand characters (~1 token per ~4 chars for English)
/// leaves plenty of headroom.
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
