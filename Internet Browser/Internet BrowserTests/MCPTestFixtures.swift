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

    /// Favicon bytes for the fixtures below.
    ///
    /// Rows carry one so "favicons are dropped" is a claim a test can actually
    /// falsify: `HistoryItem` and `Bookmark` both hold an `NSImage`, and the point is
    /// that the projection never carries it to a client.
    static let faviconData: Data = {
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.systemPink.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()
        return image.tiffRepresentation ?? Data("favicon-bytes".utf8)
    }()

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
            entity.faviconData = faviconData
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
            entity.faviconData = faviconData
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

    /// A small, genuinely valid one-page PDF, built with CoreGraphics.
    ///
    /// A real one matters: `read_page`'s PDF rung asks the DOCUMENT
    /// (`document.contentType`), so nothing short of WebKit actually displaying a
    /// PDF exercises it. Handing WebKit invalid bytes would fall back to a plain
    /// document and the test would pass for the wrong reason.
    static func pdf() -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else { return Data() }
        var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 300)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return Data() }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 20, y: 20, width: 120, height: 120))
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    /// Loads a real PDF at `baseURL` and waits for WebKit's PDF view.
    ///
    /// `baseURL` is deliberately a caller's choice so a test can use an
    /// extensionless address like `arxiv.org/pdf/2401.00001` — the shape the old
    /// `pathExtension == "pdf"` heuristic missed.
    static func loadPDF(into webView: WKWebView, baseURL: URL, timeout: TimeInterval = 15) async throws {
        webView.load(pdf(), mimeType: "application/pdf", characterEncodingName: "", baseURL: baseURL)
        let deadline = Date().addingTimeInterval(timeout)
        while webView.isLoading || webView.url == nil {
            if Date() > deadline { throw Failure.timedOut }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
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
