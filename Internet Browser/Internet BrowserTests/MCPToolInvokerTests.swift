//
//  MCPToolInvokerTests.swift
//  Internet BrowserTests
//
//  The wire shape and the argument handling: what a model actually receives, and
//  what happens when it sends something Cherry cannot use.
//
//  The JSON keys asserted here ARE the tool contract. They are written out in
//  full rather than derived, because a renamed field is a silently broken client
//  and nothing else in the build would notice.
//
//  Two distinctions this file exists to pin down:
//
//  * a **refusal** ("this tab is asleep", "Cherry will not open file:") is a
//    successful call — `isError: false` with a machine-readable `reason`, so the
//    model changes its move instead of retrying the same one;
//  * a **failure** ("that is not a tab id") is `isError: true`, because the call
//    itself was wrong and a cheerful empty success would be filled in by
//    invention.
//

import XCTest
import MCP
@testable import Cherry

@MainActor
final class MCPToolInvokerTests: XCTestCase {

    private var windows: [BrowserViewModel] = []

    override func tearDown() {
        windows = []
        super.tearDown()
    }

    // MARK: - Harness

    private func makeInvoker(
        windows viewModels: [BrowserViewModel] = [],
        history: HistoryRepository? = nil,
        bookmarks: BookmarkRepository? = nil,
        limiter: MCPRateLimiter? = nil
    ) -> MCPToolInvoker {
        windows = viewModels
        let bridge = MCPBrowserBridge(
            registeredViewModels: { viewModels },
            history: history ?? MCPRepositoryFixture.emptyHistory,
            bookmarks: bookmarks ?? MCPRepositoryFixture.emptyBookmarks,
            openTabLimiter: limiter ?? MCPRateLimiter(limit: 5, window: 60)
        )
        return MCPToolInvoker(bridge: { bridge })
    }

    private func window(tabs urls: [String]) -> BrowserViewModel {
        let viewModel = BrowserViewModel(withDefaultTab: false)
        for url in urls {
            viewModel.tabManager.newTab(url: URL(string: url)!, switchTo: true)
        }
        return viewModel
    }

    private func call(
        _ invoker: MCPToolInvoker,
        _ name: String,
        _ arguments: [String: Value] = [:]
    ) async -> CallTool.Result {
        await invoker.call(CallTool.Parameters(name: name, arguments: arguments))
    }

    private func text(of result: CallTool.Result) -> String {
        guard case .text(let text, _, _) = result.content.first else { return "" }
        return text
    }

    /// The single JSON text block a tool returns, as a dictionary — which is what
    /// a client parses.
    private func object(of result: CallTool.Result) throws -> [String: Any] {
        let data = Data(text(of: result).utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any],
                             "not a JSON object: \(text(of: result))")
    }

    // MARK: - The wire shape

    func testListTabsKeys() async throws {
        let viewModel = window(tabs: ["https://swift.org/blog"])
        let result = await call(makeInvoker(windows: [viewModel]), "list_tabs")
        XCTAssertNil(result.isError)

        let body = try object(of: result)
        XCTAssertEqual(Set(body.keys), ["windows", "total_tabs", "truncated"])

        let windowBody = try XCTUnwrap((body["windows"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(windowBody.keys), ["window_id", "is_active", "tab_count", "tabs"])

        let tabBody = try XCTUnwrap((windowBody["tabs"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(tabBody.keys), [
            "tab_id", "title", "url", "selected", "pinned", "sleeping", "loading", "internal_page",
        ])
        XCTAssertTrue(tabBody["internal_page"] is NSNull,
                      "internal_page must be an explicit null, not an absent key")
    }

    func testReadPageRefusalKeys() async throws {
        let viewModel = BrowserViewModel(withDefaultTab: false)
        viewModel.tabManager.newTab(switchTo: true)
        let result = await call(makeInvoker(windows: [viewModel]), "read_page")

        XCTAssertNil(result.isError, "a refusal is a successful call, not an error")
        let body = try object(of: result)
        XCTAssertEqual(body["status"] as? String, "unreadable")
        XCTAssertEqual(body["reason"] as? String, "home_page")
        XCTAssertNotNil(body["detail"] as? String)
        XCTAssertNotNil(body["tab_id"] as? String)
        XCTAssertNotNil(body["window_id"] as? String)
    }

    func testReadPageSuccessKeys() async throws {
        let viewModel = window(tabs: ["https://swift.org/blog"])
        let tab = viewModel.tabManager.tabs[0]
        try await MCPPageFixture.load(
            MCPPageFixture.article(repeating: "MULBERRY-KEYS", paragraphs: 6),
            into: tab.createWebView()
        )

        let result = await call(makeInvoker(windows: [viewModel]), "read_page")
        let body = try object(of: result)
        XCTAssertEqual(body["status"] as? String, "ok")
        for key in ["tab_id", "window_id", "title", "url", "text", "offset",
                    "returned_chars", "total_chars", "has_more", "loading",
                    "text_source", "source_displayed"] {
            XCTAssertNotNil(body[key], "read_page is missing \(key)")
        }
        XCTAssertNil(body["next_offset"], "next_offset must be absent when there is no more")
        XCTAssertNil(body["page_clamped"], "page_clamped must be absent for a page that fits")
        XCTAssertTrue((body["text"] as? String)?.contains("MULBERRY-KEYS") == true)

        // The fixture's `<article>` IS laid out (measured: one client rect,
        // 2,780pt tall, even in a zero-size web view), so this reports the container
        // as displayed. The hidden-DOM counterpart is in MCPBrowserBridgeTests.
        XCTAssertEqual(body["source_displayed"] as? Bool, true)
        XCTAssertEqual(body["text_source"] as? String, PageTextSource.renderedClone.rawValue)
    }

    func testSearchHistoryKeys() async throws {
        let history = MCPRepositoryFixture.history([
            (url: "https://swift.org/blog", title: "Swift Blog", visitDate: Date(), visitCount: 7)
        ])
        let result = await call(
            makeInvoker(history: history), "search_history", ["query": .string("swift")]
        )

        let body = try object(of: result)
        XCTAssertEqual(Set(body.keys), ["query", "results", "returned", "total_matches", "truncated"])
        let entry = try XCTUnwrap((body["results"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(entry.keys), ["title", "url", "visited_at", "visit_count"])
        XCTAssertEqual(entry["visit_count"] as? Int, 7)
        XCTAssertTrue((entry["visited_at"] as? String)?.hasSuffix("Z") == true,
                      "visited_at should be ISO-8601 UTC: \(entry["visited_at"] ?? "nil")")
        assertFaviconWasDropped(from: entry, whole: result)
    }

    func testSearchBookmarksKeys() async throws {
        let bookmarks = MCPRepositoryFixture.bookmarks([
            (url: "https://swift.org", title: "Swift", folder: "Reading", inBar: true, createdAt: Date())
        ])
        let result = await call(
            makeInvoker(bookmarks: bookmarks), "search_bookmarks", ["query": .string("swift")]
        )

        let body = try object(of: result)
        XCTAssertEqual(Set(body.keys), ["query", "results", "returned", "total_matches", "truncated"])
        let entry = try XCTUnwrap((body["results"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(entry.keys), ["title", "url", "folder", "in_bookmark_bar", "created_at"])
        XCTAssertEqual(entry["folder"] as? String, "Reading")
        XCTAssertEqual(entry["in_bookmark_bar"] as? Bool, true)
        assertFaviconWasDropped(from: entry, whole: result)
    }

    /// A favicon really was there to drop, and none of it came through.
    ///
    /// The previous version of this check was `XCTAssertFalse(text.contains("favicon"))`,
    /// which could never fail: the DTOs have no favicon property and the encoder
    /// emits only declared keys, so the substring was unreachable by construction.
    /// The fixtures now put real TIFF bytes on every row — `HistoryItem` and
    /// `Bookmark` both carry an `NSImage` — so the assertion has something to catch:
    /// no image-shaped key, and none of the actual bytes in any encoding.
    private func assertFaviconWasDropped(
        from entry: [String: Any],
        whole result: CallTool.Result,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let body = text(of: result)
        XCTAssertFalse(entry.keys.contains { $0.contains("favicon") || $0.contains("icon") },
                       "an icon field reached an MCP client: \(entry.keys.sorted())",
                       file: file, line: line)
        XCTAssertFalse(body.contains(MCPRepositoryFixture.faviconData.base64EncodedString()),
                       "favicon bytes were serialised into the payload", file: file, line: line)
        // TIFF magic, in case a future encoder chooses a different representation.
        XCTAssertFalse(body.contains("MM\u{0}*") || body.contains("II*\u{0}"),
                       "raw image bytes reached an MCP client", file: file, line: line)
    }

    func testOpenTabKeys() async throws {
        let viewModel = window(tabs: [])
        let result = await call(
            makeInvoker(windows: [viewModel]), "open_tab", ["url": .string("https://example.com")]
        )

        XCTAssertNil(result.isError)
        let body = try object(of: result)
        XCTAssertEqual(Set(body.keys), ["status", "tab_id", "window_id", "url", "activated"])
        XCTAssertEqual(body["status"] as? String, "ok")
        XCTAssertEqual(body["activated"] as? Bool, false)
        XCTAssertEqual(body["tab_id"] as? String, viewModel.tabManager.tabs.first?.id.uuidString)
    }

    func testOpenTabRefusalKeys() async throws {
        let result = await call(
            makeInvoker(windows: [window(tabs: [])]),
            "open_tab",
            ["url": .string("file:///etc/passwd")]
        )

        XCTAssertNil(result.isError, "a refusal is a successful call, not an error")
        let body = try object(of: result)
        XCTAssertEqual(body["status"] as? String, "refused")
        XCTAssertEqual(body["reason"] as? String, "unsupported_scheme")
        XCTAssertEqual(body["scheme"] as? String, "file")
        XCTAssertTrue((body["detail"] as? String)?.contains("file") == true,
                      "the refusal has to name the scheme in prose too")
    }

    // MARK: - Argument handling

    func testUnknownToolIsAFailureThatNamesTheRealOnes() async {
        let result = await call(makeInvoker(), "delete_history")
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(text(of: result).contains("Unknown tool"))
        for tool in MCPToolRegistry.tools {
            XCTAssertTrue(text(of: result).contains(tool.name), "did not offer \(tool.name)")
        }
    }

    func testEveryDeclaredToolIsWiredUp() async {
        let invoker = makeInvoker(windows: [window(tabs: ["https://swift.org"])])
        let arguments: [String: [String: Value]] = [
            "list_tabs": [:],
            "read_page": [:],
            "search_history": ["query": .string("x")],
            "search_bookmarks": ["query": .string("x")],
            "open_tab": ["url": .string("https://example.com")],
        ]
        for tool in MCPToolRegistry.tools {
            let result = await call(invoker, tool.name, arguments[tool.name] ?? [:])
            XCTAssertNotEqual(result.isError, true, "\(tool.name): \(text(of: result))")
            XCTAssertFalse(text(of: result).contains("not wired up"), tool.name)
            XCTAssertFalse(text(of: result).isEmpty, tool.name)
        }
    }

    func testMissingRequiredArgumentIsAFailure() async {
        for tool in ["search_history", "search_bookmarks"] {
            let result = await call(makeInvoker(), tool)
            XCTAssertEqual(result.isError, true, tool)
            XCTAssertTrue(text(of: result).contains("query is required"), "\(tool): \(text(of: result))")
        }
        let openTab = await call(makeInvoker(), "open_tab")
        XCTAssertEqual(openTab.isError, true)
        XCTAssertTrue(text(of: openTab).contains("url is required"), text(of: openTab))
    }

    /// The important one: a mistyped `tab_id` must never fall through to "read
    /// whatever the user is looking at". That would hand the model a DIFFERENT
    /// page than the one it asked for, and say nothing about the substitution.
    func testAMalformedTabIDIsRejectedRatherThanIgnored() async throws {
        let viewModel = window(tabs: ["https://swift.org/blog"])
        let tab = viewModel.tabManager.tabs[0]
        try await MCPPageFixture.load(
            MCPPageFixture.article(repeating: "NECTARINE-NOT-ASKED-FOR", paragraphs: 6),
            into: tab.createWebView()
        )

        let result = await call(
            makeInvoker(windows: [viewModel]), "read_page", ["tab_id": .string("tab-3")]
        )
        XCTAssertEqual(result.isError, true)
        XCTAssertFalse(text(of: result).contains("NECTARINE-NOT-ASKED-FOR"),
                       "a bad tab_id silently read the focused tab instead")
        XCTAssertTrue(text(of: result).contains("list_tabs"), "say where a real id comes from")
    }

    func testANegativeOffsetIsRejected() async {
        let result = await call(makeInvoker(), "read_page", ["offset": .int(-1)])
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(text(of: result).contains("offset"), text(of: result))
    }

    func testAnEmptyHistoryQueryIsRejectedRatherThanDumpingEverything() async throws {
        let history = MCPRepositoryFixture.history([
            (url: "https://a.example", title: "A", visitDate: Date(), visitCount: 1),
            (url: "https://b.example", title: "B", visitDate: Date(), visitCount: 1),
        ])
        for empty in ["", "   "] {
            let result = await call(
                makeInvoker(history: history), "search_history", ["query": .string(empty)]
            )
            XCTAssertEqual(result.isError, true, "\"\(empty)\" was accepted")
            XCTAssertFalse(text(of: result).contains("a.example"),
                           "an empty query returned the user's history")
        }
    }

    /// Bookmarks are different, and the schema says so: an empty query is a
    /// listing of a set the user curated, not a dump of everything they read.
    func testAnEmptyBookmarkQueryListsBookmarks() async throws {
        let bookmarks = MCPRepositoryFixture.bookmarks([
            (url: "https://a.example", title: "A", folder: nil, inBar: false, createdAt: Date()),
            (url: "https://b.example", title: "B", folder: nil, inBar: false, createdAt: Date()),
        ])
        let result = await call(
            makeInvoker(bookmarks: bookmarks), "search_bookmarks", ["query": .string("")]
        )
        XCTAssertNil(result.isError)
        XCTAssertEqual(try object(of: result)["returned"] as? Int, 2)
    }

    /// A number may arrive as a JSON number or as a string depending on the
    /// client. Refusing a perfectly clear `"limit": "1"` would be pedantry.
    func testScalarsAreAcceptedInTheFormsClientsActuallySend() async throws {
        let history = MCPRepositoryFixture.history(
            (0..<5).map {
                (url: "https://example.com/\($0)", title: "Item \($0)",
                 visitDate: Date().addingTimeInterval(Double(-$0)), visitCount: 1)
            }
        )
        for limit in [Value.int(2), .double(2.0), .string("2")] {
            let result = await call(
                makeInvoker(history: history),
                "search_history",
                ["query": .string("example"), "limit": limit]
            )
            XCTAssertNil(result.isError, "\(limit) was rejected")
            XCTAssertEqual(try object(of: result)["returned"] as? Int, 2, "\(limit)")
        }

        let activate = await call(
            makeInvoker(windows: [window(tabs: [])]),
            "open_tab",
            ["url": .string("https://example.com"), "activate": .string("true")]
        )
        XCTAssertEqual(try object(of: activate)["activated"] as? Bool, true)
    }

    func testAnUnusableScalarIsRejectedNotDefaulted() async {
        let result = await call(
            makeInvoker(), "search_history", ["query": .string("x"), "limit": .string("lots")]
        )
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(text(of: result).contains("whole number"), text(of: result))
    }

    /// One MCP request used to kill the whole browser process.
    ///
    /// `optionalInt` matched `.double` and called the TRAPPING `Int(d)`, so any
    /// out-of-range JSON number took the app down: every window and every unsaved
    /// tab, from any client holding the token. The SDK does no `inputSchema`
    /// validation, so the declared `"maximum": 100` never ran; and it decodes
    /// Int-first-then-Double, so an integer literal beyond `Int64` arrives as
    /// `.double` too. `infinity.rounded() == infinity`, so the old
    /// `d == d.rounded()` guard let it straight through.
    ///
    /// Reachable on all three tools that take a number. Every shape below is a
    /// separate way to trap `Int(_: Double)`.
    func testOutOfRangeNumbersAreRefusedRatherThanTrapping() async {
        let hostile: [(name: String, value: Value)] = [
            ("1e300", .double(1e300)),
            ("-1e300", .double(-1e300)),
            ("1e999 → infinity", .double(.infinity)),
            ("-infinity", .double(-.infinity)),
            ("nan", .double(.nan)),
            ("greatestFiniteMagnitude", .double(.greatestFiniteMagnitude)),
            // Just past Int64.max, which is where Double(Int.max) itself lands.
            ("Int64.max + 1", .double(9_223_372_036_854_775_808.0)),
            // A bare integer literal past Int64, as the SDK would decode it.
            ("99999999999999999999", .double(99_999_999_999_999_999_999.0)),
            // Fractional: not a count, so refused rather than silently rounded.
            ("2.5", .double(2.5)),
            // And the string forms, which must also not overflow.
            ("\"99999999999999999999\"", .string("99999999999999999999")),
        ]

        for (name, value) in hostile {
            for (tool, key, extra) in [
                ("search_history", "limit", ["query": Value.string("a")]),
                ("search_history", "since_days", ["query": Value.string("a")]),
                ("search_bookmarks", "limit", ["query": Value.string("a")]),
                ("read_page", "offset", [:]),
            ] as [(String, String, [String: Value])] {
                var arguments = extra
                arguments[key] = value
                // Reaching the assertion at all is most of the point: before the fix
                // this call did not return, it killed the process.
                let result = await call(makeInvoker(), tool, arguments)
                XCTAssertEqual(
                    result.isError, true,
                    "\(tool).\(key) accepted \(name): \(text(of: result))"
                )
            }
        }
    }

    /// The in-range boundaries still work, so the fix did not just refuse everything.
    func testTheIntegerBoundariesThemselvesAreStillAccepted() async throws {
        let history = MCPRepositoryFixture.history([
            (url: "https://example.com/x", title: "X", visitDate: Date(), visitCount: 1)
        ])
        for value in [Value.int(Int.max), .int(Int.min), .double(3.0), .int(1)] {
            let result = await call(
                makeInvoker(history: history),
                "search_history",
                ["query": .string("example"), "limit": value]
            )
            XCTAssertNil(result.isError, "\(value) was refused: \(text(of: result))")
            XCTAssertEqual(try object(of: result)["returned"] as? Int, 1)
        }
    }

    /// `read_page`'s offset is the other number a client controls, and a huge but
    /// in-range one has to clamp rather than overflow while chunking.
    func testAHugeInRangeOffsetClampsInsteadOfOverflowing() async throws {
        let viewModel = window(tabs: ["https://swift.org/blog"])
        let tab = viewModel.tabManager.tabs[0]
        try await MCPPageFixture.load(
            MCPPageFixture.article(repeating: "OREGANO-OFFSET", paragraphs: 6),
            into: tab.createWebView()
        )

        let result = await call(
            makeInvoker(windows: [viewModel]), "read_page", ["offset": .int(Int.max)]
        )
        XCTAssertNil(result.isError, text(of: result))
        let body = try object(of: result)
        XCTAssertEqual(body["returned_chars"] as? Int, 0)
        XCTAssertEqual(body["has_more"] as? Bool, false)
    }

    /// An explicit `null` means "not given", which is what several clients send
    /// for an unset optional.
    func testNullOptionalsAreTreatedAsAbsent() async throws {
        let viewModel = window(tabs: ["https://swift.org"])
        let result = await call(
            makeInvoker(windows: [viewModel]), "list_tabs", ["window_id": .null]
        )
        XCTAssertNil(result.isError, text(of: result))
        XCTAssertEqual((try object(of: result)["windows"] as? [[String: Any]])?.count, 1)
    }

    // MARK: - Caps and what a client sees when it hits one

    func testHistoryBeyondTheLimitSaysHowToGetMore() async throws {
        let history = MCPRepositoryFixture.history(
            (0..<60).map {
                (url: "https://example.com/\($0)", title: "Item \($0)",
                 visitDate: Date().addingTimeInterval(Double(-$0 * 60)), visitCount: 1)
            }
        )
        let result = await call(
            makeInvoker(history: history),
            "search_history",
            ["query": .string("example"), "limit": .int(10)]
        )

        let body = try object(of: result)
        XCTAssertEqual(body["returned"] as? Int, 10)
        XCTAssertEqual(body["total_matches"] as? Int, 60)
        XCTAssertEqual(body["truncated"] as? Bool, true)
        let note = try XCTUnwrap(body["note"] as? String)
        XCTAssertTrue(note.contains("10 of 60"), note)
        XCTAssertTrue(note.contains("limit"), note)
    }

    /// Above the schema's maximum, clamp and keep going rather than fail: the
    /// model wanted "as many as possible", and it is told what it got.
    func testAnOverLargeLimitIsClampedNotRefused() async throws {
        let history = MCPRepositoryFixture.history(
            (0..<150).map {
                (url: "https://example.com/\($0)", title: "Item \($0)",
                 visitDate: Date().addingTimeInterval(Double(-$0 * 60)), visitCount: 1)
            }
        )
        let result = await call(
            makeInvoker(history: history),
            "search_history",
            ["query": .string("example"), "limit": .int(10_000)]
        )
        let body = try object(of: result)
        XCTAssertNil(result.isError)
        XCTAssertEqual(body["returned"] as? Int, MCPResultCaps.historyLimitMaximum)
        XCTAssertEqual(body["truncated"] as? Bool, true)

        // And it is told that its own limit was cut, not just that there is more —
        // otherwise "raise limit" is advice it has already tried.
        let note = try XCTUnwrap(body["note"] as? String)
        XCTAssertTrue(note.contains("capped at \(MCPResultCaps.historyLimitMaximum)"), note)
    }

    func testHistoryIsMostRecentFirstAndRespectsSinceDays() async throws {
        let now = Date()
        let history = MCPRepositoryFixture.history([
            (url: "https://example.com/old", title: "Old", visitDate: now.addingTimeInterval(-10 * 86_400), visitCount: 1),
            (url: "https://example.com/mid", title: "Mid", visitDate: now.addingTimeInterval(-2 * 86_400), visitCount: 1),
            (url: "https://example.com/new", title: "New", visitDate: now.addingTimeInterval(-60), visitCount: 1),
        ])

        let all = try object(of: await call(
            makeInvoker(history: history), "search_history", ["query": .string("example")]
        ))
        XCTAssertEqual((all["results"] as? [[String: Any]])?.compactMap { $0["title"] as? String },
                       ["New", "Mid", "Old"])

        let recent = try object(of: await call(
            makeInvoker(history: history),
            "search_history",
            ["query": .string("example"), "since_days": .int(3)]
        ))
        XCTAssertEqual((recent["results"] as? [[String: Any]])?.compactMap { $0["title"] as? String },
                       ["New", "Mid"])
        XCTAssertEqual(recent["total_matches"] as? Int, 2,
                       "total_matches must count what since_days left, not everything")
    }

    func testBookmarksCanBeNarrowedToOneFolder() async throws {
        let now = Date()
        let bookmarks = MCPRepositoryFixture.bookmarks([
            (url: "https://a.example", title: "Alpha", folder: "Reading", inBar: false, createdAt: now),
            (url: "https://b.example", title: "Beta", folder: "Work", inBar: false, createdAt: now),
            (url: "https://c.example", title: "Gamma", folder: nil, inBar: true, createdAt: now),
        ])

        let reading = try object(of: await call(
            makeInvoker(bookmarks: bookmarks),
            "search_bookmarks",
            ["query": .string(""), "folder": .string("reading")]
        ))
        XCTAssertEqual((reading["results"] as? [[String: Any]])?.compactMap { $0["title"] as? String },
                       ["Alpha"], "folder matching should be case-insensitive")
        XCTAssertEqual(reading["total_matches"] as? Int, 1)
    }

    /// The searches are budgeted by total size too, not only by `limit`. 200
    /// bookmarks at 200 title + 500 url is ~168,000 characters in one unchunked
    /// answer, and 100 history rows ~73,000 — both past the hard limit.
    func testSearchResultsFitTheSizeBudgetAndSayWhenTheyStopped() async throws {
        let longTitle = String(repeating: "T", count: 400)
        let longURL = "https://example.com/" + String(repeating: "p", count: 900)

        let history = MCPRepositoryFixture.history((0..<100).map {
            (url: "\(longURL)/\($0)", title: "\($0) \(longTitle)",
             visitDate: Date().addingTimeInterval(Double(-$0)), visitCount: 1)
        })
        let historyBody = await call(
            makeInvoker(history: history),
            "search_history",
            ["query": .string("example"), "limit": .int(100)]
        )
        XCTAssertLessThan(text(of: historyBody).count, MCPResultCaps.payloadChars,
                          "search_history exceeded its own declared budget")
        let historyNote = try XCTUnwrap(try object(of: historyBody)["note"] as? String)
        XCTAssertTrue(historyNote.contains("result size limit"), historyNote)
        XCTAssertTrue(historyNote.contains("will not return more"),
                      "raising limit is useless here and the note must say so: \(historyNote)")

        let bookmarks = MCPRepositoryFixture.bookmarks((0..<200).map {
            (url: "\(longURL)/\($0)", title: "\($0) \(longTitle)", folder: "Reading",
             inBar: false, createdAt: Date().addingTimeInterval(Double(-$0)))
        })
        let bookmarkBody = await call(
            makeInvoker(bookmarks: bookmarks),
            "search_bookmarks",
            ["query": .string("example"), "limit": .int(200)]
        )
        XCTAssertLessThan(text(of: bookmarkBody).count, MCPResultCaps.payloadChars,
                          "search_bookmarks exceeded its own declared budget")
        XCTAssertTrue(
            try XCTUnwrap(try object(of: bookmarkBody)["note"] as? String).contains("result size limit")
        )
    }

    func testLongHistoryTitlesAreTruncatedVisibly() async throws {
        let history = MCPRepositoryFixture.history([
            (url: "https://example.com/x", title: String(repeating: "T", count: 900),
             visitDate: Date(), visitCount: 1)
        ])
        let body = try object(of: await call(
            makeInvoker(history: history), "search_history", ["query": .string("example")]
        ))
        let title = try XCTUnwrap((body["results"] as? [[String: Any]])?.first?["title"] as? String)
        XCTAssertEqual(title.count, MCPResultCaps.entryTitleChars + 1)
        XCTAssertTrue(title.hasSuffix("…"))
    }

    // MARK: - Through the whole JSON-RPC path

    /// Everything above drives the invoker directly. This one drives it the way a
    /// client does — `tools/call` over `MCPRequestServer`, bearer token and all —
    /// so the seam is proved end to end and not just in isolation.
    func testAToolResultTravelsTheWholeJSONRPCPath() async throws {
        let viewModel = window(tabs: ["https://swift.org/blog"])
        let token = "test-token-abcdef"
        let server = MCPRequestServer(
            serverName: "Cherry",
            serverVersion: "1.0-test",
            port: 8787,
            expectedToken: { token },
            invokeTool: makeInvoker(windows: [viewModel]).invoker
        )

        let request = HTTPRequest(
            method: "POST",
            headers: [
                "Host": "127.0.0.1:8787",
                "Authorization": "Bearer \(token)",
                "Content-Type": "application/json",
                "Accept": "application/json",
            ],
            body: Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_tabs","arguments":{}}}"#.utf8),
            path: "/mcp"
        )

        let response = await server.serve(request)
        XCTAssertEqual(response.statusCode, 200)

        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(response.bodyData)) as? [String: Any]
        )
        let result = try XCTUnwrap(envelope["result"] as? [String: Any])
        let blockText = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(blockText.utf8)) as? [String: Any])

        XCTAssertEqual(body["total_tabs"] as? Int, 1)
        XCTAssertEqual(
            ((body["windows"] as? [[String: Any]])?.first)?["window_id"] as? String,
            viewModel.windowID.uuidString
        )
    }

    /// And the same path with no token gets nothing — the tools are only ever
    /// reachable behind the check that was already there.
    func testTheSamePathWithoutATokenReturnsNoToolData() async throws {
        let viewModel = window(tabs: ["https://swift.org/blog"])
        let server = MCPRequestServer(
            serverName: "Cherry",
            serverVersion: "1.0-test",
            port: 8787,
            expectedToken: { "test-token-abcdef" },
            invokeTool: makeInvoker(windows: [viewModel]).invoker
        )

        let response = await server.serve(HTTPRequest(
            method: "POST",
            headers: [
                "Host": "127.0.0.1:8787",
                "Authorization": "Bearer wrong",
                "Content-Type": "application/json",
                "Accept": "application/json",
            ],
            body: Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_tabs","arguments":{}}}"#.utf8),
            path: "/mcp"
        ))

        XCTAssertEqual(response.statusCode, 401)
        let body = String(decoding: response.bodyData ?? Data(), as: UTF8.self)
        XCTAssertFalse(body.contains("swift.org"))
        XCTAssertFalse(body.contains(viewModel.windowID.uuidString))
        XCTAssertFalse(body.contains("total_tabs"))
    }
}
