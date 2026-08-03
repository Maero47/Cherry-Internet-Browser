//
//  MCPRequestServerTests.swift
//  Internet BrowserTests
//
//  The whole JSON-RPC surface, driven through `MCPRequestServer.serve` with
//  hand-written request bodies. No socket, no client, no network — the SDK's
//  `HTTPRequest` is a plain struct with a public initialiser, and
//  `StatelessHTTPServerTransport.handleRequest` is the entire server-side API.
//
//  The test that matters most here is `testASecondClientSessionCanAlsoInitialize`,
//  with `testOneSharedServerRejectsTheSecondInitialize` sitting next to it to
//  show what it is guarding against. Cherry is connected to by many short-lived
//  client processes, each sending its own `initialize`; a shared `MCP.Server`
//  serves the first and refuses every one after it, forever, and the symptom
//  only appears when the CLIENT restarts.
//

import XCTest
import MCP
@testable import Cherry

final class MCPRequestServerTests: XCTestCase {

    private let token = "test-token-abcdef"
    private let port = 8787

    private func makeServer(
        invokeTool: @escaping MCPRequestServer.ToolInvoker = MCPToolStubs.notImplemented
    ) -> MCPRequestServer {
        MCPRequestServer(
            serverName: "Cherry",
            serverVersion: "1.0-test",
            port: port,
            expectedToken: { [token] in token },
            invokeTool: invokeTool
        )
    }

    // MARK: - Request fixtures

    private func request(
        json: String,
        authorization: String? = nil,
        origin: String? = nil,
        method: String = "POST",
        contentType: String? = "application/json",
        accept: String? = "application/json"
    ) -> HTTPRequest {
        var headers: [String: String] = ["Host": "127.0.0.1:\(port)"]
        headers["Authorization"] = authorization ?? "Bearer \(token)"
        if let contentType { headers["Content-Type"] = contentType }
        if let accept { headers["Accept"] = accept }
        if let origin { headers["Origin"] = origin }
        return HTTPRequest(method: method, headers: headers, body: Data(json.utf8), path: "/mcp")
    }

    private var initializeBody: String {
        """
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{\
        "protocolVersion":"2025-06-18","capabilities":{},\
        "clientInfo":{"name":"test-client","version":"1.0"}}}
        """
    }

    private func body(of response: HTTPResponse) -> [String: Any] {
        guard let data = response.bodyData,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }
        return json
    }

    private func text(of response: HTTPResponse) -> String {
        String(decoding: response.bodyData ?? Data(), as: UTF8.self)
    }

    // MARK: - The per-request factory

    func testInitializeSucceeds() async {
        let response = await makeServer().serve(request(json: initializeBody))
        XCTAssertEqual(response.statusCode, 200)

        let result = body(of: response)["result"] as? [String: Any]
        XCTAssertNotNil(result, text(of: response))
        XCTAssertNil(body(of: response)["error"])
        XCTAssertEqual((result?["serverInfo"] as? [String: Any])?["name"] as? String, "Cherry")
        XCTAssertNotNil(result?["protocolVersion"])
    }

    /// THE regression test for the finding that shaped this design.
    ///
    /// Two consecutive requests, each an `initialize`, exactly as two separate
    /// `claude mcp get` processes would send. Both must succeed. If someone
    /// "simplifies" `MCPRequestServer` into a long-lived shared `Server`, this
    /// is the test that fails.
    func testASecondClientSessionCanAlsoInitialize() async {
        let server = makeServer()

        for session in 1...3 {
            let response = await server.serve(request(json: initializeBody))
            XCTAssertEqual(response.statusCode, 200, "session \(session)")
            XCTAssertNil(
                body(of: response)["error"],
                "session \(session) was refused: \(text(of: response))"
            )
            XCTAssertNotNil(body(of: response)["result"], "session \(session)")
        }
    }

    /// The counter-example, kept deliberately: one `Server` held across
    /// requests answers the first client and refuses every later one with
    /// `-32600 Server is already initialized`
    /// (`Sources/MCP/Server/Server.swift:928-929`).
    ///
    /// If a future SDK release removes that guard this test starts failing —
    /// which is exactly when someone should re-read whether the per-request
    /// factory is still needed.
    func testOneSharedServerRejectsTheSecondInitialize() async throws {
        let shared = Server(name: "Cherry", version: "1.0-test", capabilities: .init(tools: .init()))
        let transport = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [])
        )
        try await shared.start(transport: transport)
        defer { Task { await shared.stop() } }

        let first = await transport.handleRequest(request(json: initializeBody))
        XCTAssertNil(body(of: first)["error"], "the first client should always work")

        let second = await transport.handleRequest(request(json: initializeBody))
        let error = body(of: second)["error"] as? [String: Any]
        XCTAssertNotNil(error, "a shared Server unexpectedly accepted a second initialize")
        XCTAssertEqual(error?["code"] as? Int, -32600)
        XCTAssertTrue(
            (error?["message"] as? String ?? "").contains("already initialized"),
            "\(text(of: second))"
        )
    }

    // MARK: - Tools

    /// `Server.Configuration.default` is `strict: false`, and `strict` is the
    /// only thing gating `checkInitialized()` — so a fresh per-request `Server`
    /// that never saw an `initialize` still answers. This is what makes the
    /// factory legal.
    func testToolsListWorksOnAServerThatNeverSawAnInitialize() async {
        let response = await makeServer().serve(
            request(json: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        )
        XCTAssertEqual(response.statusCode, 200)

        let result = body(of: response)["result"] as? [String: Any]
        let tools = result?["tools"] as? [[String: Any]] ?? []
        XCTAssertEqual(tools.compactMap { $0["name"] as? String },
                       ["list_tabs", "read_page", "search_history", "search_bookmarks", "open_tab"])
    }

    func testToolsListSurvivesAcrossSeparateRequests() async {
        let server = makeServer()
        _ = await server.serve(request(json: initializeBody))
        let response = await server.serve(request(json: #"{"jsonrpc":"2.0","id":9,"method":"tools/list"}"#))
        let tools = (body(of: response)["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        XCTAssertEqual(tools.count, 5)
    }

    /// Every declared tool must be callable and must say plainly that it is not
    /// wired up yet — a cheerful empty success would invite the model to invent
    /// an answer.
    func testEveryToolReportsNotImplemented() async {
        let server = makeServer()
        for tool in MCPToolRegistry.tools {
            let response = await server.serve(request(
                json: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"\#(tool.name)","arguments":{}}}"#
            ))
            XCTAssertEqual(response.statusCode, 200, tool.name)

            let result = body(of: response)["result"] as? [String: Any]
            XCTAssertEqual(result?["isError"] as? Bool, true, tool.name)

            let content = (result?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
            XCTAssertTrue(content.contains("not implemented yet"), "\(tool.name): \(content)")
        }
    }

    func testUnknownToolIsNamedInTheRefusal() async {
        let response = await makeServer().serve(request(
            json: #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"delete_history","arguments":{}}}"#
        ))
        let result = body(of: response)["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, true)

        let content = (result?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        XCTAssertTrue(content.contains("Unknown tool"), content)
    }

    /// The seam steps 5–7 attach to: swapping the invoker is all it takes.
    func testToolInvokerIsTheOnlySeamNeededForRealTools() async {
        let server = makeServer(invokeTool: { params in
            CallTool.Result(content: [.text(text: "handled \(params.name)", annotations: nil, _meta: nil)])
        })
        let response = await server.serve(request(
            json: #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"list_tabs","arguments":{}}}"#
        ))
        let result = body(of: response)["result"] as? [String: Any]
        let content = (result?["content"] as? [[String: Any]])?.first?["text"] as? String
        XCTAssertEqual(content, "handled list_tabs")
    }

    // MARK: - Authentication

    func testWrongTokenIsRejectedBeforeAnyToolDataIsProduced() async {
        let response = await makeServer().serve(
            request(json: #"{"jsonrpc":"2.0","id":6,"method":"tools/list"}"#, authorization: "Bearer wrong")
        )
        XCTAssertEqual(response.statusCode, 401)
        assertNoToolDataLeaked(in: text(of: response))
    }

    func testAbsentTokenIsRejected() async {
        var headers = ["Host": "127.0.0.1:\(port)", "Content-Type": "application/json", "Accept": "application/json"]
        headers.removeValue(forKey: "Authorization")
        let response = await makeServer().serve(HTTPRequest(
            method: "POST",
            headers: headers,
            body: Data(#"{"jsonrpc":"2.0","id":7,"method":"tools/list"}"#.utf8),
            path: "/mcp"
        ))
        XCTAssertEqual(response.statusCode, 401)
        assertNoToolDataLeaked(in: text(of: response))
    }

    func testMalformedAuthorizationHeaderIsRejected() async {
        for header in ["Bearer", "Basic \(token)", "\(token)", "Bearer \(token) extra"] {
            let response = await makeServer().serve(
                request(json: #"{"jsonrpc":"2.0","id":8,"method":"tools/list"}"#, authorization: header)
            )
            XCTAssertEqual(response.statusCode, 401, "accepted: \(header)")
        }
    }

    /// Even a valid `initialize` — the one request a client sends before it can
    /// do anything — must not get through unauthenticated.
    func testInitializeAlsoRequiresTheToken() async {
        let response = await makeServer().serve(request(json: initializeBody, authorization: "Bearer nope"))
        XCTAssertEqual(response.statusCode, 401)
    }

    /// The invariant this file's header claims: an unauthorised caller learns
    /// exactly one thing, `401`.
    ///
    /// It was false. `StatelessHTTPServerTransport.handleRequest` answers 405
    /// (with `Allow: POST`), 400 "Empty request body" and 400 "Invalid JSON-RPC
    /// message" BEFORE it ever runs the validation pipeline — so the bearer
    /// check was first inside the pipeline, but the pipeline was not first.
    ///
    /// Two consequences, the second being the real one:
    ///   * an unauthenticated caller could fingerprint Cherry-with-MCP on the
    ///     port, which is the recon the 401-only design existed to deny;
    ///   * attacker-controlled bytes reached `JSONRPCMessageKind(data:)` — a
    ///     JSON decode over an unauthenticated body up to 1 MB — before the
    ///     token was ever compared. Every decoder bug in that path was pre-auth.
    func testEveryPreDispatchRefusalStillRequiresTheToken() async {
        let unauthorized: [(name: String, request: HTTPRequest)] = [
            ("non-POST", request(json: "", authorization: "Bearer wrong", method: "GET")),
            ("DELETE", request(json: "", authorization: "Bearer wrong", method: "DELETE")),
            ("empty body", request(json: "", authorization: "Bearer wrong")),
            ("not JSON at all", request(json: "not json", authorization: "Bearer wrong")),
            ("JSON but not JSON-RPC", request(json: #"{"hello":"world"}"#, authorization: "Bearer wrong")),
            ("wrong content type", request(json: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#,
                                           authorization: "Bearer wrong", contentType: "text/plain")),
            ("unacceptable Accept", request(json: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#,
                                            authorization: "Bearer wrong", accept: "text/html")),
        ]

        for (name, unauthenticated) in unauthorized {
            let response = await makeServer().serve(unauthenticated)
            XCTAssertEqual(response.statusCode, 401, "\(name) leaked a non-401 status")
            XCTAssertNil(response.headers["Allow"], "\(name) leaked the accepted methods")
            assertNoToolDataLeaked(in: text(of: response))
        }
    }

    /// The token check must run before anything decodes the body, so an
    /// unauthenticated 1 MB body is never handed to a JSON parser.
    func testAnUnauthenticatedBodyIsNeverDecoded() async {
        let hostile = String(repeating: "[", count: 200_000)
        let response = await makeServer().serve(request(json: hostile, authorization: "Bearer wrong"))
        XCTAssertEqual(response.statusCode, 401)
    }

    // MARK: - DNS rebinding

    /// A web page's `fetch('http://127.0.0.1:8787/mcp')` sends an `Origin`; a
    /// CLI client sends none. The token stops the page first, and this stops it
    /// again if the token ever leaks into a browsable context.
    func testForeignOriginIsRejectedEvenWithAValidToken() async {
        let response = await makeServer().serve(
            request(json: #"{"jsonrpc":"2.0","id":10,"method":"tools/list"}"#, origin: "https://evil.example")
        )
        XCTAssertEqual(response.statusCode, 403)
        assertNoToolDataLeaked(in: text(of: response))
    }

    /// Validator order is load-bearing: an unauthenticated caller must learn
    /// `401` and nothing about which origins we accept.
    func testBearerIsCheckedBeforeOrigin() async {
        let response = await makeServer().serve(request(
            json: #"{"jsonrpc":"2.0","id":11,"method":"tools/list"}"#,
            authorization: "Bearer wrong",
            origin: "https://evil.example"
        ))
        XCTAssertEqual(response.statusCode, 401, "origin check ran before the token check")
    }

    func testLoopbackOriginOnTheConfiguredPortIsAccepted() async {
        let response = await makeServer().serve(
            request(json: #"{"jsonrpc":"2.0","id":12,"method":"tools/list"}"#, origin: "http://127.0.0.1:\(port)")
        )
        XCTAssertEqual(response.statusCode, 200)
    }

    // MARK: - Protocol hygiene

    func testGetIsNotAllowed() async {
        let response = await makeServer().serve(request(json: "", method: "GET"))
        XCTAssertEqual(response.statusCode, 405)
    }

    func testWrongContentTypeIsRejected() async {
        let response = await makeServer().serve(
            request(json: #"{"jsonrpc":"2.0","id":13,"method":"tools/list"}"#, contentType: "text/plain")
        )
        XCTAssertEqual(response.statusCode, 415)
    }

    func testClientMustAcceptJSON() async {
        let response = await makeServer().serve(
            request(json: #"{"jsonrpc":"2.0","id":14,"method":"tools/list"}"#, accept: "text/html")
        )
        XCTAssertEqual(response.statusCode, 406)
    }

    func testUnparseableBodyIsRejected() async {
        let response = await makeServer().serve(request(json: "not json at all"))
        XCTAssertEqual(response.statusCode, 400)
    }

    // MARK: - Helper

    private func assertNoToolDataLeaked(
        in responseText: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for tool in MCPToolRegistry.tools {
            XCTAssertFalse(
                responseText.contains(tool.name),
                "refusal mentioned \(tool.name)",
                file: file, line: line
            )
        }
        XCTAssertFalse(responseText.contains(token), "refusal echoed the token", file: file, line: line)
    }
}
