//
//  ChatHistoryStoreTests.swift
//  Internet BrowserTests
//

import XCTest
@testable import Cherry

@MainActor
final class ChatHistoryStoreTests: XCTestCase {

    private var directory: URL!
    private var fileURL: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        fileURL = directory.appendingPathComponent("history.json")
    }

    override func tearDown() async throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeSession(
        id: UUID = UUID(),
        kind: SavedChatSession.Kind = .page,
        title: String = "What is this page about?",
        updatedAt: Date = Date(),
        turns: [SavedTurn]? = nil
    ) -> SavedChatSession {
        SavedChatSession(
            id: id,
            kind: kind,
            title: title,
            createdAt: updatedAt,
            updatedAt: updatedAt,
            turns: turns ?? [
                SavedTurn(role: .user, text: "What is this page about?", reasoning: nil, sources: []),
                SavedTurn(
                    role: .assistant,
                    text: "It compares hybrid retrieval strategies. [1]",
                    reasoning: "The user wants a summary; the intro paragraph covers it.",
                    sources: [SavedSource(index: 1, title: "Hybrid RAG explained", tabID: UUID(), url: URL(string: "https://example.com/rag"))]
                ),
            ]
        )
    }

    // MARK: - Codable round-trip

    func testRoundTripPreservesReasoningAndSources() throws {
        let original = makeSession(kind: .research)
        ChatHistoryStore(fileURL: fileURL).upsert(original)

        let reloaded = ChatHistoryStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.sessions.count, 1)
        let session = try XCTUnwrap(reloaded.sessions.first)
        XCTAssertEqual(session.id, original.id)
        XCTAssertEqual(session.kind, .research)
        XCTAssertEqual(session.title, original.title)
        XCTAssertEqual(session.turns, original.turns)
        XCTAssertEqual(session.turns[1].reasoning, original.turns[1].reasoning)
        XCTAssertEqual(session.turns[1].sources, original.turns[1].sources)
        // ISO8601 encoding keeps whole-second precision; that's enough for
        // "2h ago" display ordering.
        XCTAssertEqual(
            session.updatedAt.timeIntervalSinceReferenceDate,
            original.updatedAt.timeIntervalSinceReferenceDate,
            accuracy: 1.0
        )
    }

    // MARK: - Upsert

    func testUpsertUpdatesInPlaceInsteadOfDuplicating() {
        let store = ChatHistoryStore(fileURL: fileURL)
        let id = UUID()
        let created = Date(timeIntervalSinceNow: -3600)
        store.upsert(makeSession(id: id, updatedAt: created))

        var grown = makeSession(id: id, updatedAt: Date())
        grown.turns += [
            SavedTurn(role: .user, text: "And the downsides?", reasoning: nil, sources: []),
            SavedTurn(role: .assistant, text: "Latency and index freshness.", reasoning: nil, sources: []),
        ]
        store.upsert(grown)

        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions.first?.turns.count, 4)
        // The original creation date survives the update.
        XCTAssertEqual(
            store.sessions.first?.createdAt.timeIntervalSinceReferenceDate ?? 0,
            created.timeIntervalSinceReferenceDate,
            accuracy: 1.0
        )
    }

    func testUpsertWithUnchangedContentKeepsUpdatedAt() {
        let store = ChatHistoryStore(fileURL: fileURL)
        let id = UUID()
        let first = Date(timeIntervalSinceNow: -3600)
        // Identical turns both times (makeSession would mint a fresh source
        // tabID per call, which counts as changed content).
        let turns = [SavedTurn(role: .user, text: "q", reasoning: nil, sources: [])]
        store.upsert(makeSession(id: id, updatedAt: first, turns: turns))
        store.upsert(makeSession(id: id, updatedAt: Date(), turns: turns))

        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(
            store.sessions.first?.updatedAt.timeIntervalSinceReferenceDate ?? 0,
            first.timeIntervalSinceReferenceDate,
            accuracy: 1.0
        )
    }

    // MARK: - Ordering

    func testSessionsAreNewestFirst() {
        let store = ChatHistoryStore(fileURL: fileURL)
        // Whole seconds apart: ISO8601 persistence truncates sub-second
        // precision, so same-second timestamps could tie after a reload.
        let oldest = makeSession(title: "oldest", updatedAt: Date(timeIntervalSinceNow: -7200))
        let middle = makeSession(title: "middle", updatedAt: Date(timeIntervalSinceNow: -3600))
        let newest = makeSession(title: "newest", updatedAt: Date(timeIntervalSinceNow: -60))
        store.upsert(oldest)
        store.upsert(middle)
        store.upsert(newest)

        XCTAssertEqual(store.sessions.map(\.title), ["newest", "middle", "oldest"])

        // Updating the oldest bumps it to the front…
        var updatedOldest = oldest
        updatedOldest.turns += [SavedTurn(role: .user, text: "more", reasoning: nil, sources: [])]
        updatedOldest.updatedAt = Date()
        store.upsert(updatedOldest)
        XCTAssertEqual(store.sessions.map(\.title), ["oldest", "newest", "middle"])

        // …and a reload from disk re-sorts by updatedAt the same way.
        XCTAssertEqual(ChatHistoryStore(fileURL: fileURL).sessions.map(\.title), ["oldest", "newest", "middle"])
    }

    // MARK: - Delete / clear

    func testDeleteRemovesOnlyThatSessionAndPersists() {
        let store = ChatHistoryStore(fileURL: fileURL)
        let keep = makeSession(title: "keep")
        let remove = makeSession(title: "remove")
        store.upsert(keep)
        store.upsert(remove)

        store.delete(id: remove.id)
        XCTAssertEqual(store.sessions.map(\.id), [keep.id])
        XCTAssertEqual(ChatHistoryStore(fileURL: fileURL).sessions.map(\.id), [keep.id])
    }

    func testClearEmptiesTheStoreAndDisk() {
        let store = ChatHistoryStore(fileURL: fileURL)
        store.upsert(makeSession())
        store.clear()
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertTrue(ChatHistoryStore(fileURL: fileURL).sessions.isEmpty)
    }

    // MARK: - Failure safety

    func testMissingFileLoadsAsEmpty() {
        XCTAssertTrue(ChatHistoryStore(fileURL: fileURL).sessions.isEmpty)
    }

    func testCorruptFileLoadsAsEmptyAndRecoversOnNextSave() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json {{{".utf8).write(to: fileURL)

        let store = ChatHistoryStore(fileURL: fileURL)
        XCTAssertTrue(store.sessions.isEmpty)

        // The next save overwrites the corrupt file with a valid one.
        let session = makeSession()
        store.upsert(session)
        XCTAssertEqual(ChatHistoryStore(fileURL: fileURL).sessions.map(\.id), [session.id])
    }

    // MARK: - Snapshot projection

    func testSnapshotRequiresACompletedExchange() {
        let id = UUID()
        // No turns at all.
        XCTAssertNil(SavedChatSession.snapshot(id: id, kind: .general, fallbackTitle: "x", turns: []))
        // A lone user turn (no assistant reply yet).
        XCTAssertNil(SavedChatSession.snapshot(
            id: id, kind: .general, fallbackTitle: "x",
            turns: [PageChatTurn(role: .user, text: "hello")]
        ))
        // An error-only conversation.
        XCTAssertNil(SavedChatSession.snapshot(
            id: id, kind: .general, fallbackTitle: "x",
            turns: [PageChatTurn(role: .error, text: "engine unavailable")]
        ))
        // A still-streaming assistant reply doesn't count as completed.
        XCTAssertNil(SavedChatSession.snapshot(
            id: id, kind: .general, fallbackTitle: "x",
            turns: [
                PageChatTurn(role: .user, text: "hello"),
                PageChatTurn(role: .assistant, text: "partial", isStreaming: true),
            ]
        ))
    }

    func testSnapshotDropsErrorTurnsAndDerivesTitleFromFirstUserTurn() throws {
        let turns = [
            PageChatTurn(role: .user, text: "  Summarize the key points of this very long article please  "),
            PageChatTurn(role: .error, text: "transient failure"),
            PageChatTurn(role: .assistant, text: "Here are the key points.", reasoning: "thinking…"),
        ]
        let snapshot = try XCTUnwrap(SavedChatSession.snapshot(
            id: UUID(), kind: .page, fallbackTitle: "Some Page", turns: turns
        ))
        XCTAssertEqual(snapshot.turns.count, 2)
        XCTAssertEqual(snapshot.turns.map(\.role), [.user, .assistant])
        XCTAssertEqual(snapshot.turns[1].reasoning, "thinking…")
        XCTAssertTrue(snapshot.title.hasPrefix("Summarize the key points"))
        XCTAssertLessThanOrEqual(snapshot.title.count, SavedChatSession.titleLength + 1) // +1 for the ellipsis
    }

    func testDeriveTitleFallsBack() {
        XCTAssertEqual(SavedChatSession.deriveTitle(turns: [], fallback: "Page Title"), "Page Title")
        XCTAssertEqual(SavedChatSession.deriveTitle(turns: [], fallback: "   "), "New chat")
    }

    func testSavedTurnRoundTripsToChatTurn() {
        let tabID = UUID()
        let saved = SavedTurn(
            role: .assistant,
            text: "Answer [1]",
            reasoning: "chain of thought",
            sources: [SavedSource(index: 1, title: "Source Tab", tabID: tabID, url: URL(string: "https://example.com/a"))]
        )
        let live = saved.asChatTurn()
        XCTAssertEqual(live.role, .assistant)
        XCTAssertEqual(live.text, "Answer [1]")
        XCTAssertEqual(live.reasoning, "chain of thought")
        XCTAssertEqual(live.sources.map(\.tabID), [tabID])
        XCTAssertEqual(live.sources.map(\.index), [1])
        XCTAssertEqual(live.sources.map(\.url), [URL(string: "https://example.com/a")])
        XCTAssertFalse(live.isStreaming)
    }

    /// A chat saved before source URLs were persisted (no `url` key in the
    /// JSON) must still decode — its sources just carry a nil URL.
    func testSavedSourceDecodesLegacyJSONWithoutURL() throws {
        let legacyJSON = """
        {"index":2,"title":"Old Source","tabID":"\(UUID().uuidString)"}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        let source = try decoder.decode(SavedSource.self, from: legacyJSON)
        XCTAssertEqual(source.index, 2)
        XCTAssertEqual(source.title, "Old Source")
        XCTAssertNil(source.url)
    }

    /// A source URL survives a full encode → decode round-trip through the store.
    func testSavedSourceURLPersistsThroughEncodeDecode() throws {
        let url = URL(string: "https://example.com/persisted")
        let original = SavedSource(index: 3, title: "Live Source", tabID: UUID(), url: url)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SavedSource.self, from: data)
        XCTAssertEqual(decoded.url, url)
    }
}
