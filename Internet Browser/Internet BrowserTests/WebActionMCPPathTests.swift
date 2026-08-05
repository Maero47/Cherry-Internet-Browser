//
//  WebActionMCPPathTests.swift
//  Internet BrowserTests
//
//  `read_elements` over a real loopback socket, against a real page.
//
//  Everything else in `WebActionBridgeTests` drives the bridge directly. This
//  file drives it the way a client does and assembles the server exactly as
//  `MCPServerManager.start()` does: `MCPHTTPListener` bound to loopback, the
//  bearer check running BEFORE any hop to the main actor, `MCPRequestServer`
//  dispatching `tools/call`, `MCPToolInvoker` parsing off-main, one hop, the
//  isolated content world, and JSON back down the socket.
//
//  It binds a per-run high port and mints its own token, so it needs no settings
//  change, writes nothing to the token store, and cannot collide with a copy of
//  Cherry running on 8787.
//

import XCTest
import WebKit
@testable import Cherry

@MainActor
final class WebActionMCPPathTests: XCTestCase {

    private var listener: MCPHTTPListener?
    private var windows: [BrowserViewModel] = []

    override func tearDown() {
        listener?.stop()
        listener = nil
        windows = []
        super.tearDown()
    }

    private let token = "read-elements-path-token"

    /// The server, wired the way `MCPServerManager.start()` wires it.
    private func startServer(over viewModels: [BrowserViewModel]) async throws -> UInt16 {
        windows = viewModels
        let browser = MCPBrowserBridge(
            registeredViewModels: { viewModels },
            history: MCPRepositoryFixture.emptyHistory,
            bookmarks: MCPRepositoryFixture.emptyBookmarks
        )
        let actions = WebActionBridge(browser: { browser })

        var candidate = UInt16.random(in: 20_000...40_000)
        for _ in 0..<10 {
            // Built per candidate because the server checks the request's `Host`
            // against the port it was told it is on — Cherry's DNS-rebinding
            // guard — so a server declaring one port behind a socket bound to
            // another answers 421 to everything, which is correct of it.
            let requestServer = MCPRequestServer(
                serverName: "Cherry",
                serverVersion: "1.0-test",
                port: Int(candidate),
                expectedToken: { [token] in token },
                invokeTool: MCPToolInvoker(bridge: { browser }, actions: { actions }).invoker
            )
            let listener = MCPHTTPListener(
                handler: { request in
                    if let refusal = requestServer.authenticate(request) { return refusal }
                    return await requestServer.dispatch(request)
                },
                authorize: { headers in requestServer.bearer.authorizes(headers: headers) }
            )
            listener.start(port: candidate)

            // Polled rather than waited on: a blocking `wait(for:)` here would
            // hold the main actor, and the handler above needs it.
            for _ in 0..<150 where !listener.currentStatus.isReady {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            if listener.currentStatus.isReady {
                self.listener = listener
                return candidate
            }
            listener.stop()
            candidate = candidate &+ 137
        }
        throw XCTSkip("could not bind any loopback port in this environment")
    }

    private func post(
        port: UInt16,
        bearer: String?,
        body: String
    ) async throws -> (status: Int, body: String) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        request.httpBody = Data(body.utf8)
        request.timeoutInterval = 15

        let session = URLSession(configuration: .ephemeral)
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? -1, String(decoding: data, as: UTF8.self))
    }

    /// The tool result's single JSON text block, parsed — which is what a model
    /// actually receives.
    private func toolBody(_ envelopeText: String) throws -> [String: Any] {
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(envelopeText.utf8)) as? [String: Any],
            envelopeText
        )
        let result = try XCTUnwrap(envelope["result"] as? [String: Any], envelopeText)
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], text)
    }

    // MARK: - The whole path

    func testReadElementsTravelsTheWholeLoopbackPath() async throws {
        let viewModel = BrowserViewModel(withDefaultTab: false)
        viewModel.tabManager.newTab(url: URL(string: "https://shop.example/cart")!, switchTo: true)
        let tab = viewModel.tabManager.tabs[0]
        let webView = tab.createWebView()
        webView.frame = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        try await MCPPageFixture.load("""
        <html><head><title>Cherry test shop</title></head><body>
          <a href="/">Cherry test shop</a>
          <input type="search" aria-label="Search the shop">
          <button>Go</button>
          <a href="/cart">2 items in cart</a>
          <form action="/checkout" method="post"><button>Pay now</button></form>
          <button style="display:block;margin-top:2000px">Footer control</button>
        </body></html>
        """, into: webView)

        let port = try await startServer(over: [viewModel])

        // 1. tools/list advertises it.
        let listed = try await post(
            port: port, bearer: token,
            body: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#
        )
        XCTAssertEqual(listed.status, 200)
        XCTAssertTrue(listed.body.contains("read_elements"), listed.body)

        // 2. tools/call returns the listing.
        let called = try await post(
            port: port, bearer: token,
            body: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"read_elements","arguments":{}}}"#
        )
        XCTAssertEqual(called.status, 200)

        let body = try toolBody(called.body)
        XCTAssertEqual(body["status"] as? String, "ok")
        XCTAssertEqual(body["tab_id"] as? String, tab.id.uuidString)
        XCTAssertEqual(body["scope"] as? String, "viewport")

        let elements = try XCTUnwrap(body["elements"] as? String)
        XCTAssertTrue(elements.contains("searchbox \"Search the shop\""), elements)
        XCTAssertTrue(elements.contains("\"Pay now\" (commits=pay)"),
                      "the commitment flag did not survive the wire:\n\(elements)")
        XCTAssertFalse(elements.contains("Footer control"),
                       "the viewport default listed something below the fold")

        // Printed so the payload in the report is a transcript rather than a
        // reconstruction.
        print("""
            [read_elements over loopback] HTTP \(called.status)
            \(String(decoding: try JSONSerialization.data(
                withJSONObject: body, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            ), as: UTF8.self))
            """)
    }

    /// The same request without the token gets nothing — the control list is
    /// only ever reachable behind the check that was already there, and the
    /// refusal must not identify the page either.
    func testTheSamePathWithoutATokenListsNothing() async throws {
        let viewModel = BrowserViewModel(withDefaultTab: false)
        viewModel.tabManager.newTab(url: URL(string: "https://shop.example/cart")!, switchTo: true)
        let webView = viewModel.tabManager.tabs[0].createWebView()
        webView.frame = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        try await MCPPageFixture.load(
            "<html><body><button>PIMENTO-UNAUTHENTICATED</button></body></html>", into: webView
        )

        let port = try await startServer(over: [viewModel])
        let call = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"read_elements","arguments":{}}}"#

        for bearer in [nil, "wrong-token"] {
            let response = try await post(port: port, bearer: bearer, body: call)
            XCTAssertEqual(response.status, 401, bearer ?? "(no header)")
            XCTAssertFalse(response.body.contains("PIMENTO-UNAUTHENTICATED"), response.body)
            XCTAssertFalse(response.body.contains("shop.example"), response.body)
            XCTAssertFalse(response.body.contains("elements"), response.body)
        }

        // …and the same socket still works with the real token, so the 401s
        // above are the check and not a broken server.
        let good = try await post(port: port, bearer: token, body: call)
        XCTAssertEqual(good.status, 200)
        XCTAssertTrue(good.body.contains("PIMENTO-UNAUTHENTICATED"))
    }

    /// A refusal travels as a successful call, so the model can change its move.
    func testARefusalArrivesAsASuccessWithAReason() async throws {
        let viewModel = BrowserViewModel(withDefaultTab: false)
        viewModel.tabManager.newTab(switchTo: true)   // the home page
        let port = try await startServer(over: [viewModel])

        let response = try await post(
            port: port, bearer: token,
            body: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"read_elements","arguments":{}}}"#
        )
        XCTAssertEqual(response.status, 200)

        let body = try toolBody(response.body)
        XCTAssertEqual(body["status"] as? String, "unreadable")
        XCTAssertEqual(body["reason"] as? String, "home_page")
    }
}
