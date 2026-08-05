//
//  MCPActionArgumentTests.swift
//  Internet BrowserTests
//
//  What a client actually receives from the three acting tools, and what happens
//  when it sends something Cherry cannot use.
//
//  The same two distinctions the rest of the MCP tests pin down: a REFUSAL is a
//  successful call whose answer is "no" (`isError: false`, machine-readable
//  `reason`), and a FAILURE is a call that was wrong (`isError: true`). "You have
//  no session" is the first. "You did not say which page load your element
//  number came from" is the second, because a caller that cannot say that is not
//  making a well-formed call at all.
//

import XCTest
import MCP
@testable import Cherry

@MainActor
final class MCPActionArgumentTests: XCTestCase {

    private var windows: [BrowserViewModel] = []
    private var auditDirectory: URL!

    override func setUp() {
        super.setUp()
        auditDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cherry-args-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        windows = []
        if let auditDirectory { try? FileManager.default.removeItem(at: auditDirectory) }
        super.tearDown()
    }

    /// An invoker over one window, with its OWN session store and its own audit
    /// directory — so nothing here inherits a grant from another test or writes
    /// into the developer's real action log.
    private func makeInvoker() -> (MCPToolInvoker, Tab) {
        let viewModel = BrowserViewModel(withDefaultTab: false)
        viewModel.tabManager.newTab(url: URL(string: "https://example.invalid/")!, switchTo: true)
        windows = [viewModel]
        let bridge = MCPBrowserBridge(
            registeredViewModels: { [viewModel] },
            history: MCPRepositoryFixture.emptyHistory,
            bookmarks: MCPRepositoryFixture.emptyBookmarks
        )
        let store = WebActionSessionStore()
        let audit = WebActionAuditLog(directory: auditDirectory)
        let actions = WebActionBridge(browser: { bridge }, sessions: { store }, auditLog: { audit })
        return (
            MCPToolInvoker(bridge: { bridge }, actions: { actions }),
            viewModel.tabManager.tabs[0]
        )
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

    private func object(of result: CallTool.Result) throws -> [String: Any] {
        try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(text(of: result).utf8)) as? [String: Any]
        )
    }

    // MARK: - `document` is required, and its absence is a failure not a refusal

    func testClickWithoutADocumentIsAFailureAndSaysWhy() async {
        let (invoker, tab) = makeInvoker()
        let result = await call(invoker, "click_element", [
            "element": .int(4),
            "expect_name": .string("Show more"),
            "tab_id": .string(tab.id.uuidString),
        ])
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(text(of: result).contains("document is required"), text(of: result))
        XCTAssertTrue(
            text(of: result).contains("read_elements"),
            "the message must say where to get one"
        )
    }

    func testTypeWithoutADocumentIsAFailure() async {
        let (invoker, tab) = makeInvoker()
        let result = await call(invoker, "type_text", [
            "element": .int(4),
            "expect_name": .string("Search"),
            "text": .string("hello"),
            "tab_id": .string(tab.id.uuidString),
        ])
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(text(of: result).contains("document is required"))
    }

    func testAnEmptyDocumentIsNotADocument() async {
        let (invoker, tab) = makeInvoker()
        let result = await call(invoker, "click_element", [
            "element": .int(4),
            "expect_name": .string("Show more"),
            "document": .string("   "),
            "tab_id": .string(tab.id.uuidString),
        ])
        XCTAssertEqual(result.isError, true)
    }

    // MARK: - No session is a refusal, and it is machine-readable

    func testClickingWithNoSessionIsARefusalTheModelCanActOn() async throws {
        let (invoker, tab) = makeInvoker()
        let result = await call(invoker, "click_element", [
            "element": .int(4),
            "expect_name": .string("Show more"),
            "document": .string("0123456789abcdef0123456789abcdef"),
            "tab_id": .string(tab.id.uuidString),
        ])
        XCTAssertNotEqual(result.isError, true, "a refusal is a successful call")

        let payload = try object(of: result)
        XCTAssertEqual(payload["status"] as? String, "refused")
        XCTAssertEqual(payload["reason"] as? String, "no_session")
        let detail = try XCTUnwrap(payload["detail"] as? String)
        XCTAssertTrue(
            detail.contains("request_action_session"),
            "the refusal has to say what to do instead: \(detail)"
        )
    }

    /// Leaving out `tab_id` does not fall back to whatever the user is looking
    /// at. With no grant there is no tab to act in, full stop.
    func testOmittingTheTabWithNoSessionIsStillNoSession() async throws {
        let (invoker, _) = makeInvoker()
        let result = await call(invoker, "type_text", [
            "element": .int(1),
            "expect_name": .string("Search"),
            "document": .string("0123456789abcdef0123456789abcdef"),
            "text": .string("hello"),
        ])
        let payload = try object(of: result)
        XCTAssertEqual(payload["reason"] as? String, "no_session")
    }

    // MARK: - The purpose is the one string the user reads

    func testAPurposeTooShortToMeanAnythingIsRefusedBeforeTheUserIsAsked() async {
        let (invoker, tab) = makeInvoker()
        let result = await call(invoker, "request_action_session", [
            "tab_id": .string(tab.id.uuidString),
            "purpose": .string("do stuff"),
        ])
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(text(of: result).contains("purpose must be at least"), text(of: result))
    }

    func testMinutesOutsideWhatTheUserIsShownIsRefused() async {
        let (invoker, tab) = makeInvoker()
        for minutes in [0, 31, 10_000] {
            let result = await call(invoker, "request_action_session", [
                "tab_id": .string(tab.id.uuidString),
                "purpose": .string("Find the January invoice and download it"),
                "minutes": .int(minutes),
            ])
            XCTAssertEqual(result.isError, true, "minutes \(minutes) was accepted")
        }
    }

    /// `request_action_session` takes a tab id and only a tab id. A grant is the
    /// one place where "whatever the user happens to be looking at" is exactly
    /// the wrong answer — the sheet names a tab, and it must be the one meant.
    func testASessionCannotBeAskedForWithoutNamingATab() async {
        let (invoker, _) = makeInvoker()
        let result = await call(invoker, "request_action_session", [
            "purpose": .string("Find the January invoice and download it"),
        ])
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(text(of: result).contains("tab_id is required"), text(of: result))
    }

    func testAMalformedTabIdIsAFailureRatherThanASubstitution() async {
        let (invoker, _) = makeInvoker()
        let result = await call(invoker, "request_action_session", [
            "tab_id": .string("not-a-uuid"),
            "purpose": .string("Find the January invoice and download it"),
        ])
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(text(of: result).contains("not an id Cherry issued"), text(of: result))
    }

    // MARK: - text

    func testTypingRefusesTextLargerThanTheSchemaAllows() async {
        let (invoker, tab) = makeInvoker()
        let result = await call(invoker, "type_text", [
            "element": .int(1),
            "expect_name": .string("Search"),
            "document": .string("0123456789abcdef0123456789abcdef"),
            "text": .string(String(repeating: "a", count: MCPResultCaps.typedTextChars + 1)),
            "tab_id": .string(tab.id.uuidString),
        ])
        XCTAssertEqual(result.isError, true)
    }

    // MARK: - The unknown-tool list

    func testAnUnknownToolNamesAllNineThatExist() async {
        let (invoker, _) = makeInvoker()
        let result = await call(invoker, "click_at_coordinates", [:])
        XCTAssertEqual(result.isError, true)
        for name in ["click_element", "type_text", "request_action_session"] {
            XCTAssertTrue(text(of: result).contains(name), "the tool list omits \(name)")
        }
    }
}
