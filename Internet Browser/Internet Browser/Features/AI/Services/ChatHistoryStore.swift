//
//  ChatHistoryStore.swift
//  Cherry Browser
//
//  Disk-backed history of past Ask This Page conversations — every chat kind
//  (single-page, general, and research/web) — so a conversation survives New
//  Chat, context switches, and app relaunches, and can be reopened from the
//  panel's history list. The store knows nothing about the live chat
//  sessions: the panel projects a conversation into a `SavedChatSession`
//  snapshot and upserts it here at its trigger points.
//
//  Persistence is one JSON file under Application Support (NOT UserDefaults —
//  transcripts can be large). Writes are atomic (temp file + rename via
//  `.atomic`) and failure-safe: a missing or corrupt file loads as an empty
//  history, never a crash.
//

import Foundation

/// One persisted conversation. `id` is the live session's stable conversation
/// id, so re-saving a growing conversation updates its entry in place instead
/// of duplicating it.
struct SavedChatSession: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case page
        case general
        case research
    }

    let id: UUID
    var kind: Kind
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var turns: [SavedTurn]
}

/// Codable projection of one `PageChatTurn`. Error turns and still-streaming
/// (or empty) assistant turns are never projected — only completed exchange
/// content is worth persisting.
struct SavedTurn: Codable, Equatable {
    enum Role: String, Codable {
        case user
        case assistant
    }

    let role: Role
    let text: String
    /// The assistant's chain-of-thought (the collapsible "Thoughts"), when
    /// the engine emitted one.
    let reasoning: String?
    let sources: [SavedSource]
}

/// Codable projection of a cited `ResearchSource`: just what the transcript
/// needs to display `[N] Title`. The `tabID` is kept so a still-open source
/// tab can be focused; a stale id simply doesn't resolve to a live tab.
struct SavedSource: Codable, Equatable {
    let index: Int
    let title: String
    let tabID: UUID
}

@Observable
@MainActor
final class ChatHistoryStore {
    static let shared = ChatHistoryStore()

    /// Newest-first by `updatedAt` — the order the history list shows.
    private(set) var sessions: [SavedChatSession] = []

    private let fileURL: URL

    /// `fileURL` is injectable so tests can point the store at a temp
    /// directory instead of the real Application Support file.
    init(fileURL: URL = ChatHistoryStore.defaultFileURL()) {
        self.fileURL = fileURL
        load()
    }

    /// Inserts `session` as the newest entry, or updates the existing entry
    /// with the same `id` in place — never duplicating a growing
    /// conversation. The original `createdAt` always survives an update. An
    /// update whose content (kind/title/turns) is identical to what's stored
    /// is skipped entirely, so repeated save triggers don't bump `updatedAt`
    /// or rewrite the file for nothing.
    func upsert(_ session: SavedChatSession) {
        var entry = session
        if let existingIndex = sessions.firstIndex(where: { $0.id == session.id }) {
            let existing = sessions[existingIndex]
            if existing.kind == entry.kind, existing.title == entry.title, existing.turns == entry.turns {
                return
            }
            entry.createdAt = existing.createdAt
            sessions.remove(at: existingIndex)
        }
        sessions.insert(entry, at: 0)
        persist()
    }

    func delete(id: UUID) {
        let countBefore = sessions.count
        sessions.removeAll { $0.id == id }
        guard sessions.count != countBefore else { return }
        persist()
    }

    func clear() {
        guard !sessions.isEmpty else { return }
        sessions = []
        persist()
    }

    // MARK: - Disk

    /// `nonisolated` so it can serve as `init`'s default argument (default
    /// arguments are evaluated outside the actor).
    nonisolated static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("CherryChatHistory", isDirectory: true)
            .appendingPathComponent("history.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? Self.decoder.decode([SavedChatSession].self, from: data) else {
            sessions = []
            return
        }
        sessions = decoded.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try Self.encoder.encode(sessions)
            // `.atomic` writes to a temp file and renames it into place, so a
            // crash mid-write can never leave a half-written history behind.
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // History is a convenience; failing to persist must never take
            // the chat down with it. The in-memory list stays usable.
            print("ChatHistoryStore: failed to persist history: \(error)")
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

// MARK: - Projection from the live chat types

extension SavedTurn {
    /// `nil` for turns that shouldn't be persisted: error turns, and
    /// assistant turns that are still streaming or produced no answer text.
    init?(_ turn: PageChatTurn) {
        switch turn.role {
        case .user:
            role = .user
        case .assistant:
            guard !turn.isStreaming, !turn.text.isEmpty else { return nil }
            role = .assistant
        case .error:
            return nil
        }
        text = turn.text
        reasoning = turn.reasoning
        sources = turn.sources.map { SavedSource(index: $0.index, title: $0.title, tabID: $0.tabID) }
    }

    /// The display-side inverse: a live turn carrying the persisted text,
    /// reasoning, and citation labels. A restored source has no URL and its
    /// `tabID` may be stale — focusing it just no-ops if the tab is gone.
    func asChatTurn() -> PageChatTurn {
        PageChatTurn(
            role: role == .user ? .user : .assistant,
            text: text,
            reasoning: reasoning,
            sources: sources.map { ResearchSource(index: $0.index, tabID: $0.tabID, title: $0.title, url: nil) }
        )
    }
}

extension SavedChatSession {
    /// Character budget for a title derived from the first user message.
    static let titleLength = 40

    /// Projects a live conversation into a saveable snapshot, or `nil` when
    /// there is nothing worth saving yet: a conversation only persists once
    /// it has at least one completed user + assistant exchange (so empty and
    /// error-only conversations never reach the store).
    static func snapshot(
        id: UUID,
        kind: Kind,
        fallbackTitle: String,
        turns: [PageChatTurn],
        now: Date = Date()
    ) -> SavedChatSession? {
        let saved = turns.compactMap(SavedTurn.init)
        guard saved.contains(where: { $0.role == .user }),
              saved.contains(where: { $0.role == .assistant }) else { return nil }
        return SavedChatSession(
            id: id,
            kind: kind,
            title: deriveTitle(turns: saved, fallback: fallbackTitle),
            createdAt: now,
            updatedAt: now,
            turns: saved
        )
    }

    /// First user turn's text trimmed to `titleLength`; falls back to the
    /// page/research title (or "New chat") if no user turn has usable text.
    static func deriveTitle(turns: [SavedTurn], fallback: String) -> String {
        let firstUserText = turns.first { $0.role == .user }?
            .text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !firstUserText.isEmpty {
            guard firstUserText.count > titleLength else { return firstUserText }
            return String(firstUserText.prefix(titleLength)).trimmingCharacters(in: .whitespaces) + "…"
        }
        let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedFallback.isEmpty ? "New chat" : trimmedFallback
    }
}
