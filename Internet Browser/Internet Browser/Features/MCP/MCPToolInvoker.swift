//
//  MCPToolInvoker.swift
//  Cherry Browser
//
//  `tools/call` → the browser → JSON. The whole attachment surface between the
//  MCP transport and Cherry.
//
//  `MCPRequestServer` takes one closure —
//  `@Sendable (CallTool.Parameters) async -> CallTool.Result` — and this file is
//  what fills it. Nothing in the transport, the listener, the bearer validator or
//  the token store knows these tools exist.
//
//  ## Isolation
//
//  `nonisolated`, because that is where it runs: the SDK registers handlers as
//  `@Sendable` closures on its own executor, off the main actor. Argument parsing
//  and JSON encoding happen here, off-main. There is exactly ONE hop per call,
//  `hop(_:)`, and only a `Sendable` payload comes back through it — no `Tab`, no
//  `BrowserViewModel`, no `WKWebView`, no `HistoryItem`.
//
//  ## Refusal vs. failure
//
//  Two different answers, deliberately shaped differently:
//
//  * A **refusal** is a successful call whose answer is "there is nothing here":
//    a sleeping tab, a `cherry://` page, a scheme Cherry will not open, the rate
//    limit. `isError: false`, with a machine-readable `status`/`reason` so the
//    model can pick a different move instead of retrying the same one.
//  * A **failure** is a call that was wrong: an unknown tool, a missing required
//    argument, a `tab_id` that is not a UUID. `isError: true`, so the model is
//    told plainly rather than handed an empty success it will paper over.
//

import Foundation
import MCP

// MARK: - Argument errors

/// A `tools/call` Cherry cannot act on. Its message goes to the model verbatim,
/// so it says what was wrong AND what to send instead.
nonisolated struct MCPArgumentError: Error {
    let message: String
}

// MARK: - Invoker

nonisolated struct MCPToolInvoker: Sendable {

    /// How to reach the bridge, on the main actor.
    ///
    /// Injected so tests can drive a bridge built over a known set of windows and
    /// repositories rather than whatever the running app has open.
    private let resolveBridge: @MainActor @Sendable () -> MCPBrowserBridge

    /// How to reach the action layer, on the main actor.
    ///
    /// A second bridge rather than a method on the first, because
    /// `WebActionBridge` sits BELOW MCP — local agent mode is meant to reach it
    /// without going through anything in this folder — and because everything it
    /// will grow next (a consent session, an audit log) belongs to it and not to
    /// the read-only tools.
    private let resolveActions: @MainActor @Sendable () -> WebActionBridge

    init(
        bridge: @escaping @MainActor @Sendable () -> MCPBrowserBridge = { MCPBrowserBridge.shared },
        actions: @escaping @MainActor @Sendable () -> WebActionBridge = { WebActionBridge.shared }
    ) {
        self.resolveBridge = bridge
        self.resolveActions = actions
    }

    /// The closure `MCPServerManager` installs as `MCPRequestServer.ToolInvoker`.
    var invoker: MCPRequestServer.ToolInvoker {
        { [self] params in await call(params) }
    }

    // MARK: The one hop

    /// Runs `body` on the main actor and returns its `Sendable` result.
    ///
    /// This is the only place in the MCP feature that crosses onto the main
    /// actor, and there is still exactly one crossing per call. `body` is `async`
    /// so `read_page` and `read_elements` can await `evaluateJavaScript` inside
    /// it and release the main actor while a page's JavaScript runs; synchronous
    /// tool bodies are accepted unchanged.
    ///
    /// It takes no argument because there are now two bridges to reach — the
    /// browser one and the action one — and which of them a tool wants is the
    /// tool's business, not the hop's.
    @MainActor
    private func hop<Payload: Sendable>(
        _ body: @MainActor () async -> Payload
    ) async -> Payload {
        await body()
    }

    // MARK: Dispatch

    func call(_ params: CallTool.Parameters) async -> CallTool.Result {
        guard MCPToolRegistry.tool(named: params.name) != nil else {
            return MCPPayloadEncoding.failure(
                "Unknown tool \"\(params.name)\". Cherry exposes: "
                    + MCPToolRegistry.tools.map(\.name).joined(separator: ", ")
                    + "."
            )
        }

        do {
            let arguments = MCPArguments(params.arguments)
            switch params.name {
            case MCPToolRegistry.listTabs.name:
                return MCPPayloadEncoding.result(try await listTabs(arguments))
            case MCPToolRegistry.readPage.name:
                return MCPPayloadEncoding.result(try await readPage(arguments))
            case MCPToolRegistry.readElements.name:
                // The one tool whose bridge can answer "Cherry could not do
                // this", as distinct from "there is nothing here". A refusal is
                // encoded as a result; a failure goes out as one, so a model is
                // told plainly instead of being handed an empty page listing it
                // would report to the user as fact.
                switch try await readElements(arguments) {
                case .failed(let message):
                    return MCPPayloadEncoding.failure(message)
                case .snapshot(let snapshot):
                    return MCPPayloadEncoding.result(
                        MCPReadElementsOutcome.elements(MCPReadElementsPayload(snapshot))
                    )
                case .unreadable(let payload):
                    return MCPPayloadEncoding.result(MCPReadElementsOutcome.unreadable(payload))
                }
            case MCPToolRegistry.requestActionSession.name:
                switch try await requestActionSession(arguments) {
                case .granted(let grant):
                    return MCPPayloadEncoding.result(
                        MCPActionSessionOutcome.granted(MCPActionSessionPayload(grant))
                    )
                case .refused(let refusal):
                    return MCPPayloadEncoding.result(
                        MCPActionSessionOutcome.refused(MCPActionRefusalPayload(refusal))
                    )
                case .failed(let message):
                    return MCPPayloadEncoding.failure(message)
                }
            case MCPToolRegistry.clickElement.name:
                return encode(try await click(arguments))
            case MCPToolRegistry.typeText.name:
                return encode(try await type(arguments))
            case MCPToolRegistry.searchHistory.name:
                return MCPPayloadEncoding.result(try await searchHistory(arguments))
            case MCPToolRegistry.searchBookmarks.name:
                return MCPPayloadEncoding.result(try await searchBookmarks(arguments))
            case MCPToolRegistry.openTab.name:
                return MCPPayloadEncoding.result(try await openTab(arguments))
            default:
                // Unreachable: the registry lookup above already accepted the
                // name, so this only fires if a tool is declared and never wired,
                // which is a Cherry bug and must not read as an empty answer.
                return MCPPayloadEncoding.failure(
                    "\"\(params.name)\" is declared but not wired up in this build of Cherry. "
                        + "Do not retry, and do not guess what it would have returned."
                )
            }
        } catch let error as MCPArgumentError {
            return MCPPayloadEncoding.failure(error.message)
        } catch {
            return MCPPayloadEncoding.failure(
                "Cherry could not complete \(params.name): \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Per-tool argument handling

    private func listTabs(_ arguments: MCPArguments) async throws -> MCPListTabsPayload {
        let windowID = try arguments.optionalUUID("window_id")
        return await hop { resolveBridge().listTabs(windowID: windowID) }
    }

    private func readPage(_ arguments: MCPArguments) async throws -> MCPReadPageOutcome {
        // A malformed `tab_id` is an error, never a silent fall-through to the
        // focused tab: a model that mistyped an id must not be handed a
        // different page than the one it asked for and told nothing.
        let tabID = try arguments.optionalUUID("tab_id")
        let offset = try arguments.optionalInt("offset") ?? 0
        guard offset >= 0 else {
            throw MCPArgumentError(message: "offset must be 0 or greater; got \(offset).")
        }
        return await hop { await resolveBridge().readPage(tabID: tabID, offset: offset) }
    }

    private func readElements(_ arguments: MCPArguments) async throws -> WebActionSnapshotOutcome {
        let tabID = try arguments.optionalUUID("tab_id")

        // An unrecognised `scope` is an error, not a silent fall back to the
        // default. The two values differ by a factor of ten in size and by rather
        // more in what they contain, so a model that typed `"whole"` and got the
        // viewport would draw conclusions about a page from a third of it.
        let scope: WebActionScope
        if let raw = try arguments.optionalString("scope") {
            guard let parsed = WebActionScope(rawValue: raw.trimmingCharacters(in: .whitespaces).lowercased())
            else {
                throw MCPArgumentError(
                    message: "scope must be one of: "
                        + WebActionScope.allCases.map(\.rawValue).joined(separator: ", ")
                        + ". Got \"\(raw)\"."
                )
            }
            scope = parsed
        } else {
            scope = .viewport
        }

        // An empty filter is not a filter. Treating `""` as one would match
        // everything and read, in the payload's own counts, as though a filter
        // had been applied and nothing excluded.
        let filter = try arguments.optionalString("filter")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }

        return await hop { await resolveActions().snapshot(tabID: tabID, scope: scope, filter: filter) }
    }

    // MARK: The acting tools

    /// A `WebActionResult` as a `tools/call` answer.
    ///
    /// Refusals are results, failures are failures — the distinction this file's
    /// header describes. An action Cherry declined to take is a successful call
    /// whose answer is "no", and a model handed `isError: true` for one would
    /// retry it.
    private func encode(_ result: WebActionResult) -> CallTool.Result {
        switch result {
        case .acted(let acted):
            MCPPayloadEncoding.result(MCPActionOutcome.acted(MCPActionResultPayload(acted)))
        case .refused(let refusal):
            MCPPayloadEncoding.result(MCPActionOutcome.refused(MCPActionRefusalPayload(refusal)))
        case .failed(let message):
            MCPPayloadEncoding.failure(message)
        }
    }

    private func requestActionSession(_ arguments: MCPArguments) async throws -> WebActionSessionResult {
        // Required, and never defaulted to the focused tab. A grant is the one
        // place where "whatever the user happens to be looking at" is exactly the
        // wrong answer: the sheet names a tab, and the tab it names must be the
        // one the client meant.
        let raw = try arguments.requiredString("tab_id")
        guard let tabID = UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw MCPArgumentError(
                message: "tab_id \"\(raw)\" is not an id Cherry issued. Use one from list_tabs."
            )
        }

        let purpose = try arguments.requiredString("purpose").trimmingCharacters(in: .whitespacesAndNewlines)
        // The schema says `minLength`, and the SDK performs no schema validation
        // at all, so this is the only thing that actually enforces it. A purpose
        // is the one string the user reads; "do stuff" is not one.
        guard purpose.count >= WebActionText.purposeMinimumChars else {
            throw MCPArgumentError(
                message: "purpose must be at least \(WebActionText.purposeMinimumChars) characters "
                    + "and say what you intend to do in the user's own terms. The user reads it "
                    + "verbatim and it is the only thing they have to judge your request by."
            )
        }

        let minutes = try arguments.optionalInt("minutes") ?? 10
        guard (1...30).contains(minutes) else {
            throw MCPArgumentError(message: "minutes must be between 1 and 30; got \(minutes).")
        }

        return await hop {
            await resolveActions().requestSession(
                tabID: tabID, purpose: purpose, minutes: minutes, by: .mcp
            )
        }
    }

    private func click(_ arguments: MCPArguments) async throws -> WebActionResult {
        let common = try actionArguments(arguments)
        return await hop {
            await resolveActions().perform(
                .click(
                    element: common.element,
                    expectName: common.expectName,
                    document: common.document,
                    waitMS: common.waitMS
                ),
                on: common.tabID,
                by: .mcp
            )
        }
    }

    private func type(_ arguments: MCPArguments) async throws -> WebActionResult {
        let common = try actionArguments(arguments)
        let text = try arguments.requiredString("text")
        guard text.count <= MCPResultCaps.typedTextChars else {
            throw MCPArgumentError(
                message: "text must be at most \(MCPResultCaps.typedTextChars) characters; "
                    + "got \(text.count)."
            )
        }
        let append = try arguments.optionalBool("append") ?? false
        let submit = try arguments.optionalBool("submit") ?? false
        return await hop {
            await resolveActions().perform(
                .type(
                    element: common.element,
                    expectName: common.expectName,
                    document: common.document,
                    text: text,
                    append: append,
                    submit: submit,
                    waitMS: common.waitMS
                ),
                on: common.tabID,
                by: .mcp
            )
        }
    }

    /// The four arguments both acting tools share.
    ///
    /// `document` is required, and a missing one is an argument ERROR rather than
    /// a refusal — because a caller that cannot say which page load it read is
    /// not making a well-formed call at all. That is the whole reason the token
    /// exists: an element number paired with nothing is the positional-id defect
    /// wearing a different hat.
    private func actionArguments(
        _ arguments: MCPArguments
    ) throws -> (element: Int, expectName: String, document: String, tabID: UUID?, waitMS: Int) {
        guard let element = try arguments.optionalInt("element") else {
            throw MCPArgumentError(
                message: "element is required. Pass a number from a read_elements listing."
            )
        }
        guard element > 0 else {
            throw MCPArgumentError(
                message: "element must be a number read_elements gave you; got \(element)."
            )
        }
        let expectName = try arguments.requiredString("expect_name")
        // Read as OPTIONAL and rejected here, rather than through
        // `requiredString`, so the message is this one. "document is required."
        // on its own tells a model nothing about where to get one, and the
        // whole point of the token is that a caller has to understand what it is.
        let document = (try arguments.optionalString("document") ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard !document.isEmpty else {
            throw MCPArgumentError(
                message: "document is required and must be the `document` value from the same "
                    + "read_elements answer element \(element) came from. Element numbers are only "
                    + "meaningful paired with the page load they were listed in."
            )
        }
        let tabID = try arguments.optionalUUID("tab_id")
        let waitMS = WebActionSettleWait.boundedWait(try arguments.optionalInt("wait_ms"))
        return (element, expectName, document, tabID, waitMS)
    }

    private func searchHistory(_ arguments: MCPArguments) async throws -> MCPSearchHistoryPayload {
        let query = try arguments.requiredString("query")
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPArgumentError(
                message: "query must not be empty. search_history is a substring match, "
                    + "so pass something to match; it will not list the user's whole history."
            )
        }
        let limit = try arguments.optionalInt("limit") ?? MCPResultCaps.historyLimitDefault
        let sinceDays = try arguments.optionalInt("since_days")
        if let sinceDays, sinceDays < 1 {
            throw MCPArgumentError(message: "since_days must be 1 or greater; got \(sinceDays).")
        }
        return await hop { resolveBridge().searchHistory(query: query, limit: limit, sinceDays: sinceDays) }
    }

    private func searchBookmarks(_ arguments: MCPArguments) async throws -> MCPSearchBookmarksPayload {
        // Empty IS meaningful here, and the schema says so: it lists everything,
        // still subject to `limit`. Bookmarks are a set the user curated, so a
        // full listing is a reasonable ask in a way a full history dump is not.
        let query = try arguments.requiredString("query")
        let folder = try arguments.optionalString("folder")
        let limit = try arguments.optionalInt("limit") ?? MCPResultCaps.bookmarkLimitDefault
        return await hop { resolveBridge().searchBookmarks(query: query, folder: folder, limit: limit) }
    }

    private func openTab(_ arguments: MCPArguments) async throws -> MCPOpenTabOutcome {
        let raw = try arguments.requiredString("url")
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw MCPArgumentError(message: "\"\(raw)\" is not a URL Cherry can parse.")
        }
        let windowID = try arguments.optionalUUID("window_id")
        let activate = try arguments.optionalBool("activate") ?? false
        return await hop { resolveBridge().openTab(url: url, windowID: windowID, activate: activate) }
    }
}

// MARK: - Arguments

/// Reads `tools/call` arguments out of the SDK's `Value` tree.
///
/// Lenient about how a client encodes a scalar — a number may arrive as
/// `.int`, `.double` or `.string` depending on the client, and refusing a
/// perfectly clear `"limit": "50"` would be pedantry — but strict about a value
/// it genuinely cannot use, which throws rather than defaulting silently.
nonisolated struct MCPArguments {

    private let values: [String: Value]

    init(_ values: [String: Value]?) {
        self.values = values ?? [:]
    }

    /// Present, non-null values only. A client sending `"folder": null` means
    /// "no folder", which is the same as omitting it.
    private func present(_ key: String) -> Value? {
        guard let value = values[key], !value.isNull else { return nil }
        return value
    }

    func optionalString(_ key: String) throws -> String? {
        guard let value = present(key) else { return nil }
        guard let string = value.stringValue else {
            throw MCPArgumentError(message: "\(key) must be a string.")
        }
        return string
    }

    func requiredString(_ key: String) throws -> String {
        guard let string = try optionalString(key) else {
            throw MCPArgumentError(message: "\(key) is required.")
        }
        return string
    }

    /// A whole number, or a thrown error. Never a crash.
    ///
    /// `Int(someDouble)` TRAPS for anything outside `Int`'s range, and every
    /// out-of-range JSON number reaches this: `1e300`, `1e999` (which decodes to
    /// infinity, and `infinity.rounded() == infinity`, so a
    /// `double == double.rounded()` guard waves it through), `-1e300`, `nan`, and
    /// a bare integer literal past `Int64.max` — the SDK's `Value` decoder tries
    /// `Int` first and falls back to `Double`, so an over-large integer arrives
    /// here as `.double` too. The SDK performs no `inputSchema` validation, so the
    /// tools' declared `"maximum"` never runs and cannot be relied on.
    ///
    /// One request with `{"limit": 1e300}` therefore took down the whole browser —
    /// every window and every unsaved tab — from any client holding the token.
    /// `Int(exactly:)` is the fix: it returns nil instead of trapping, and this
    /// parser's whole contract is that it throws rather than defaulting silently.
    func optionalInt(_ key: String) throws -> Int? {
        guard let value = present(key) else { return nil }
        switch value {
        case .int(let int):
            return int
        case .double(let double):
            // `Int(exactly:)` rejects infinity, NaN, everything out of range, AND
            // a fractional value — all four throw below. A `limit` of 2.5 is not a
            // number of results, so rounding it would be guessing.
            guard let int = Int(exactly: double) else { break }
            return int
        case .string(let string):
            // `Int(_: String)` already returns nil on overflow rather than trapping.
            guard let int = Int(string) else { break }
            return int
        default:
            break
        }
        throw MCPArgumentError(
            message: "\(key) must be a whole number Cherry can use. "
                + "Values outside the range of a 64-bit integer, and infinity, are refused."
        )
    }

    func optionalBool(_ key: String) throws -> Bool? {
        guard let value = present(key) else { return nil }
        switch value {
        case .bool(let bool):
            return bool
        case .string("true"):
            return true
        case .string("false"):
            return false
        default:
            throw MCPArgumentError(message: "\(key) must be true or false.")
        }
    }

    /// A UUID a previous call handed out.
    ///
    /// Throws for a present-but-unparseable id rather than treating it as absent.
    /// That distinction is the whole reason this is not `UUID(uuidString:)` at the
    /// call site: `read_page` with no `tab_id` reads the tab the user is looking
    /// at, so silently swallowing a typo'd id would return a DIFFERENT page than
    /// the one asked for, with no indication it had substituted.
    func optionalUUID(_ key: String) throws -> UUID? {
        guard let string = try optionalString(key) else { return nil }
        guard let uuid = UUID(uuidString: string.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw MCPArgumentError(
                message: "\(key) \"\(string)\" is not an id Cherry issued. "
                    + "Use an id from a previous list_tabs call."
            )
        }
        return uuid
    }
}
