//
//  MCPTestFixtures.swift
//  Internet BrowserTests
//
//  Shared scaffolding for the MCP tool tests: repositories over an in-memory
//  Core Data store, and real HTML in a real `WKWebView`.
//
//  Both exist for the same reason. `search_history` and `search_bookmarks` read
//  the user's own data, so a test that used `HistoryRepository.shared` would
//  assert against whatever the developer running it happens to have browsed — and
//  would be one stray `save()` away from writing test rows into their real
//  history. `read_page` runs JavaScript against a live render tree, so the paths
//  that reach `PageAIExtractor` cannot be tested honestly without a page.
//

import Foundation
import WebKit
import XCTest
@testable import Cherry

// MARK: - Repositories

@MainActor
enum MCPRepositoryFixture {

    /// One store for every "no rows" case. Shared because nothing mutates it, and
    /// because each `PersistenceController` builds its own
    /// `NSManagedObjectModel` — several of them claiming the same
    /// `NSManagedObject` subclasses is legal but noisy.
    private static let emptyStore = PersistenceController(inMemory: true)

    static let emptyHistory = HistoryRepository(persistence: emptyStore)
    static let emptyBookmarks = BookmarkRepository(persistence: emptyStore)

    /// A history repository holding exactly `rows`, and nothing of the user's.
    static func history(_ rows: [(url: String, title: String, visitDate: Date, visitCount: Int)]) -> HistoryRepository {
        let store = PersistenceController(inMemory: true)
        let context = store.viewContext
        for row in rows {
            let entity = HistoryEntity(context: context)
            entity.id = UUID()
            entity.url = row.url
            entity.title = row.title
            entity.visitDate = row.visitDate
            entity.visitCount = Int32(row.visitCount)
        }
        try? context.save()
        return HistoryRepository(persistence: store)
    }

    /// A bookmark repository holding exactly `rows`.
    static func bookmarks(
        _ rows: [(url: String, title: String, folder: String?, inBar: Bool, createdAt: Date)]
    ) -> BookmarkRepository {
        let store = PersistenceController(inMemory: true)
        let context = store.viewContext
        for (index, row) in rows.enumerated() {
            let entity = BookmarkEntity(context: context)
            entity.id = UUID()
            entity.url = row.url
            entity.title = row.title
            entity.folder = row.folder
            entity.isInBookmarkBar = row.inBar
            entity.createdAt = row.createdAt
            entity.visitCount = 0
            entity.sortOrder = Int32(index)
        }
        try? context.save()
        return BookmarkRepository(persistence: store)
    }
}

// MARK: - Pages

@MainActor
enum MCPPageFixture {

    enum Failure: Error { case timedOut }

    /// An article-shaped page. `<article>` is the first thing
    /// `PageAIExtractor`'s heuristic looks for, so this exercises its main path
    /// rather than its last-resort one.
    static func article(repeating phrase: String, paragraphs: Int) -> String {
        let body = (0..<paragraphs)
            .map { "<p>\($0): \(String(repeating: phrase + " ", count: 12))</p>" }
            .joined()
        return "<html><head><title>Fixture</title></head><body><article>\(body)</article></body></html>"
    }

    /// Loads `html` and returns once WebKit has finished with it.
    ///
    /// Polls rather than installing a navigation delegate: `Tab` owns its web
    /// view's delegate in the app, and a test taking that over would be testing
    /// its own plumbing. Each `Task.sleep` releases the main actor, which is what
    /// lets WebKit make progress at all.
    static func load(_ html: String, into webView: WKWebView, timeout: TimeInterval = 15) async throws {
        webView.loadHTMLString(html, baseURL: URL(string: "https://fixture.invalid/"))
        let deadline = Date().addingTimeInterval(timeout)
        while webView.isLoading || webView.url == nil {
            if Date() > deadline { throw Failure.timedOut }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        // One further turn: `isLoading` drops when the navigation finishes, which
        // is not quite the same moment as the document being parsed.
        try await Task.sleep(nanoseconds: 100_000_000)
    }
}
