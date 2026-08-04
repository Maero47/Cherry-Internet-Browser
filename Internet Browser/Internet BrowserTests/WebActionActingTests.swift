//
//  WebActionActingTests.swift
//  Internet BrowserTests
//
//  Clicking and typing, through the real bridge, against real pages in real
//  `WKWebView`s.
//
//  Five of these are the ones to read first, and they are the five properties
//  the whole slice exists to hold:
//
//  * `testWithoutASessionNothingIsEvaluatedAtAll` — the enforcement point. Not
//    "the tool returns a refusal", which a description could also arrange, but
//    "the page was never touched": the fixture counts its own clicks and Cherry's
//    isolated world is never even installed. If a second path to acting ever
//    appears, this is what fails.
//  * `testAStaleDocumentIsRefusedAndTheLiveOneIsNamed` — an element number is
//    meaningless without the page load it was minted in. A tool that acted on a
//    stale id would be the positional-id defect wearing a different hat.
//  * `testAnExpiredSessionRefusesOnTheVeryNextClick` and
//    `testEndingTheSessionRefusesTheVeryNextClick` — expiry and revocation are
//    decided where the action executes, so neither has a window.
//  * `testTheAuditLogRecordsTheTypingWithoutTheText` — the same property as the
//    unit test, asserted through the real path a password would actually take.
//

import XCTest
import WebKit
@testable import Cherry

@MainActor
final class WebActionActingTests: XCTestCase {

    /// Windows under test, held strongly: `BrowserViewModel.windowViewModels` is
    /// a registry of WEAK boxes.
    private var windows: [BrowserViewModel] = []
    private var auditDirectory: URL!
    private var clock = Clock()

    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        func advance(_ seconds: TimeInterval) { now += seconds }
    }

    override func setUp() {
        super.setUp()
        auditDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cherry-acting-\(UUID().uuidString)", isDirectory: true)
        clock = Clock()
    }

    override func tearDown() {
        windows = []
        if let auditDirectory { try? FileManager.default.removeItem(at: auditDirectory) }
        super.tearDown()
    }

    // MARK: - Scaffolding

    private struct Harness {
        let bridge: WebActionBridge
        let store: WebActionSessionStore
        let audit: WebActionAuditLog
        let tab: Tab
        let webView: WKWebView
    }

    /// One window, one displayed tab holding `html`, and a bridge over exactly
    /// that — with its own session store and its own audit directory, so no test
    /// inherits another's grants or writes into the developer's real log.
    private func harness(_ html: String) async throws -> Harness {
        let viewModel = BrowserViewModel(withDefaultTab: false)
        viewModel.tabManager.newTab(url: URL(string: "https://fixture.invalid/")!, switchTo: true)
        windows = [viewModel]
        let tab = try XCTUnwrap(viewModel.tabManager.tabs.first)

        let webView = tab.createWebView()
        webView.frame = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        try await MCPPageFixture.load(html, into: webView)

        let browser = MCPBrowserBridge(
            registeredViewModels: { [viewModel] },
            history: MCPRepositoryFixture.emptyHistory,
            bookmarks: MCPRepositoryFixture.emptyBookmarks
        )
        let held = clock
        let store = WebActionSessionStore(now: { held.now })
        let audit = WebActionAuditLog(directory: auditDirectory)
        return Harness(
            bridge: WebActionBridge(
                browser: { browser }, sessions: { store }, auditLog: { audit }
            ),
            store: store,
            audit: audit,
            tab: tab,
            webView: webView
        )
    }

    /// Grant through the real consent path — `requestSession` raises the prompt,
    /// the test presses Allow. Nothing here reaches past the sheet, so if consent
    /// ever stops producing a usable grant every test below fails.
    @discardableResult
    private func grant(
        _ harness: Harness,
        purpose: String = "Search the page and open the first result",
        minutes: Int = 10
    ) async throws -> WebActionSessionGrant {
        let asking = Task {
            await harness.bridge.requestSession(
                tabID: harness.tab.id, purpose: purpose, minutes: minutes, by: .mcp
            )
        }
        for _ in 0..<400 where harness.store.pending.isEmpty {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        let request = try XCTUnwrap(harness.store.pending.first, "no consent prompt was raised")
        harness.store.allow(request.id)
        guard case .granted(let grant) = await asking.value else {
            throw Wrong.notGranted
        }
        return grant
    }

    enum Wrong: Error { case notGranted, notASnapshot, noSuchElement }

    private func snapshot(_ harness: Harness) async throws -> WebActionSnapshot {
        let outcome = await harness.bridge.snapshot(tabID: harness.tab.id, scope: .page, filter: nil)
        guard case .snapshot(let snapshot) = outcome else {
            XCTFail("expected a snapshot; got \(outcome)")
            throw Wrong.notASnapshot
        }
        return snapshot
    }

    private func id(of snapshot: WebActionSnapshot, named name: String) throws -> Int {
        guard let element = snapshot.elements.first(where: { $0.name == name }) else {
            XCTFail("no element named \"\(name)\" in:\n"
                + snapshot.elements.map(\.listingLine).joined(separator: "\n"))
            throw Wrong.noSuchElement
        }
        return element.id
    }

    /// A number the page world can see. Every fixture below counts what happened
    /// to it, so "was this actually clicked" is a fact rather than an inference.
    private func pageNumber(_ webView: WKWebView, _ expression: String) async -> Int {
        let raw = try? await webView.evaluateJavaScript(expression)
        return (raw as? NSNumber)?.intValue ?? -1
    }

    private func pageString(_ webView: WKWebView, _ expression: String) async -> String {
        let raw = try? await webView.evaluateJavaScript(expression)
        return (raw as? String) ?? ""
    }

    // MARK: - Fixtures

    private enum Page {

        /// Counts its own clicks, and mutates when the ordinary button is
        /// pressed. Nothing here navigates, so the tests are offline.
        static let counter = """
        <html><head><title>Counter</title></head><body>
          <div id="log"></div>
          <button id="ordinary" onclick="window.__clicks=(window.__clicks||0)+1;
            document.getElementById('log').appendChild(document.createTextNode('x'));">Show more</button>
          <button id="quiet" onclick="window.__quiet=(window.__quiet||0)+1;">Does nothing visible</button>
          <button id="commit">Confirm transfer of $5000</button>
          <a href="#results" id="hashlink">Jump to results</a>
          <input type="file" id="upload" aria-label="Choose a file">
          <input type="password" id="secret" aria-label="Password">
          <input type="text" id="plain" aria-label="Search the docs">
        </body></html>
        """

        /// A faithful reproduction of React's `inputValueTracking`: the tracker
        /// drops a change whose tracked value already matches, so a naive
        /// `el.value = x` leaves the DOM showing the text while application state
        /// stays empty. This is what `framework_observed` is about.
        static let tracked = """
        <html><head><title>Tracked</title></head><body>
          <input type="text" id="field" aria-label="Search with DuckDuckGo">
          <div id="state"></div>
          <script>
            (function () {
              var field = document.getElementById('field');
              var descriptor = Object.getOwnPropertyDescriptor(
                window.HTMLInputElement.prototype, 'value');
              var tracked = field.value;
              Object.defineProperty(field, 'value', {
                get: function () { return descriptor.get.call(this); },
                set: function (next) { tracked = next; descriptor.set.call(this, next); }
              });
              window.__appState = '';
              window.__dropped = 0;
              field.addEventListener('input', function () {
                if (descriptor.get.call(field) === tracked && window.__naive) {
                  window.__dropped = window.__dropped + 1;
                  return;
                }
                window.__appState = descriptor.get.call(field);
                document.getElementById('state').textContent = window.__appState;
              });
            })();
          </script>
        </body></html>
        """

        /// A form whose default button is an ordinary "Search", and one whose
        /// default button is a commitment.
        static func form(buttonLabel: String) -> String {
            """
            <html><head><title>Form</title></head><body>
              <form id="f" action="/results" method="get" onsubmit="return false;">
                <input type="text" name="q" aria-label="Search the store">
                <button type="submit" id="go"
                  onclick="window.__submitClicks=(window.__submitClicks||0)+1; return false;"
                >\(buttonLabel)</button>
              </form>
            </body></html>
            """
        }

        /// A form whose own Enter handler inserts a commitment-shaped submit
        /// button AHEAD of the innocuous one, synchronously, the moment a keydown
        /// arrives.
        ///
        /// This is the hostile page for the re-query hole. `pressEnter` used to
        /// dispatch its keydown and THEN re-run `form.querySelector(…)`, so this
        /// handler ran inside Cherry's own evaluation and the re-query returned
        /// the button it had just inserted. A gate that passed on "Search"
        /// clicked "Confirm payment". No race required.
        static let formThatSwapsItsButtonOnEnter = """
        <html><head><title>Form</title></head><body>
          <form id="f" action="/results" method="get" onsubmit="return false;">
            <input type="text" name="q" aria-label="Search the store" id="q">
            <button type="submit" id="go"
              onclick="window.__searchClicks=(window.__searchClicks||0)+1; return false;"
            >Search</button>
          </form>
          <script>
            window.__searchClicks = 0;
            window.__confirmClicks = 0;
            document.getElementById('q').addEventListener('keydown', function (event) {
              if (event.key !== 'Enter') { return; }
              if (document.getElementById('evil')) { return; }
              var form = document.getElementById('f');
              var evil = document.createElement('button');
              evil.id = 'evil';
              evil.type = 'submit';
              evil.textContent = 'Confirm payment';
              evil.addEventListener('click', function (e) {
                window.__confirmClicks = window.__confirmClicks + 1;
                e.preventDefault();
              });
              // FIRST in tree order, so a re-query returns this one.
              form.insertBefore(evil, form.firstChild);
            });
          </script>
        </body></html>
        """

        /// A message composer: a `contenteditable` whose Enter handler sends.
        ///
        /// Not a `<form>`, and there is no submit button anywhere — which is
        /// exactly how Slack, X, Discord, WhatsApp Web and Gmail's compose body
        /// are built. `submit: true` here used to dispatch the full Enter
        /// sequence with nothing classified at all.
        static let composer = """
        <html><head><title>Composer</title></head><body>
          <div id="box" contenteditable="true" aria-label="Message"></div>
          <div id="sent"></div>
          <script>
            window.__sent = 0;
            document.getElementById('box').addEventListener('keydown', function (event) {
              if (event.key !== 'Enter') { return; }
              window.__sent = window.__sent + 1;
              document.getElementById('sent').textContent =
                'sent: ' + document.getElementById('box').textContent;
            });
          </script>
        </body></html>
        """

        /// The same composer with NO `aria-label`, so its accessible name falls
        /// all the way through the ladder to `el.innerText` — which, once
        /// anything has been typed into it, IS what was typed.
        ///
        /// This is the shape that leaks into the audit log, and it is an ordinary
        /// one: a bare `<div contenteditable>` with a visual placeholder is how a
        /// great many comment boxes and composers are built.
        static let unlabelledComposer = """
        <html><head><title>Composer</title></head><body>
          <div id="composer" contenteditable="true"
            style="min-height:40px;width:300px;border:1px solid #ccc"></div>
        </body></html>
        """

        /// A button whose accessible name is longer than the 100-character
        /// display cap, so its rendered form is `prefix(99) + "…"` and the tail
        /// is invisible to the model.
        static func longNamed(tail: String) -> String {
            let padding = String(repeating: "Reference documentation section ", count: 4)
            return """
            <html><head><title>Long</title></head><body>
              <button id="long" onclick="window.__longClicks=(window.__longClicks||0)+1;"
                >\(padding)\(tail)</button>
            </body></html>
            """
        }
    }

    // MARK: - The enforcement point

    /// THE test. Not "a refusal comes back" — "the page was never touched".
    ///
    /// The fixture counts its own clicks, and Cherry's isolated world is queried
    /// WITHOUT installing it, so a `undefined` answer means no script of this
    /// feature's ever ran. A refusal produced by a tool description could not
    /// make either assertion true.
    func testWithoutASessionNothingIsEvaluatedAtAll() async throws {
        let harness = try await self.harness(Page.counter)

        // A real element number from a real listing, so the call is as
        // well-formed as it could possibly be. `read_elements` is deliberately
        // outside the gate, so this much is allowed.
        let listing = try await snapshot(harness)
        let ordinary = try id(of: listing, named: "Show more")

        let result = await harness.bridge.perform(
            .click(element: ordinary, expectName: "Show more",
                   document: listing.document, waitMS: 500),
            on: harness.tab.id,
            by: .mcp
        )

        XCTAssertEqual(result.refusalReason, .noSession)
        let clicks = await pageNumber(harness.webView, "window.__clicks || 0")
        XCTAssertEqual(clicks, 0, "the page recorded a click, so something acted without a session")
    }

    /// The same, on a page the snapshot never ran against — so the isolated world
    /// itself is the witness. If the gate ever moved below the world install,
    /// `typeof window.__cherryAct` would come back `"object"`.
    func testWithoutASessionCherrysIsolatedWorldIsNeverEvenInstalled() async throws {
        let harness = try await self.harness(Page.counter)
        let world = WKContentWorld.world(name: WebActionScripts.worldName)

        let before = try await harness.webView.evaluateJavaScript(
            "typeof window.__cherryAct", in: nil, contentWorld: world
        ) as? String
        XCTAssertEqual(before, "undefined")

        let result = await harness.bridge.perform(
            .click(element: 1, expectName: "Show more", document: "whatever", waitMS: 0),
            on: harness.tab.id,
            by: .mcp
        )
        XCTAssertEqual(result.refusalReason, .noSession)

        let after = try await harness.webView.evaluateJavaScript(
            "typeof window.__cherryAct", in: nil, contentWorld: world
        ) as? String
        XCTAssertEqual(
            after, "undefined",
            "the gate ran after something had already touched the page"
        )
    }

    func testASessionForAnotherTabDoesNotActInThisOne() async throws {
        let harness = try await self.harness(Page.counter)
        let listing = try await snapshot(harness)
        let ordinary = try id(of: listing, named: "Show more")

        // A grant that exists, for a tab that is not this one.
        let asking = Task {
            await harness.store.requestSession(
                tabID: UUID(), windowID: UUID(), tabTitle: "Somewhere else",
                origin: "https://fixture.invalid", purpose: "Do something over there",
                minutes: 10, requester: .mcp
            )
        }
        for _ in 0..<400 where harness.store.pending.isEmpty { await Task.yield() }
        let request = try XCTUnwrap(harness.store.pending.first)
        harness.store.allow(request.id)
        _ = await asking.value

        let result = await harness.bridge.perform(
            .click(element: ordinary, expectName: "Show more",
                   document: listing.document, waitMS: 500),
            on: harness.tab.id,
            by: .mcp
        )
        XCTAssertEqual(result.refusalReason, .wrongTab)
        let clicks = await pageNumber(harness.webView, "window.__clicks || 0")
        XCTAssertEqual(clicks, 0)
    }

    func testAnExpiredSessionRefusesOnTheVeryNextClick() async throws {
        let harness = try await self.harness(Page.counter)
        try await grant(harness, minutes: 1)
        let listing = try await snapshot(harness)
        let ordinary = try id(of: listing, named: "Show more")

        clock.advance(61)

        let result = await harness.bridge.perform(
            .click(element: ordinary, expectName: "Show more",
                   document: listing.document, waitMS: 500),
            on: harness.tab.id,
            by: .mcp
        )
        XCTAssertEqual(result.refusalReason, .sessionExpired)
        let clicks = await pageNumber(harness.webView, "window.__clicks || 0")
        XCTAssertEqual(clicks, 0)
    }

    func testEndingTheSessionRefusesTheVeryNextClick() async throws {
        let harness = try await self.harness(Page.counter)
        let granted = try await grant(harness)
        let listing = try await snapshot(harness)
        let ordinary = try id(of: listing, named: "Show more")

        harness.store.revoke(sessionID: try XCTUnwrap(UUID(uuidString: granted.sessionID)))

        let result = await harness.bridge.perform(
            .click(element: ordinary, expectName: "Show more",
                   document: listing.document, waitMS: 500),
            on: harness.tab.id,
            by: .mcp
        )
        XCTAssertEqual(result.refusalReason, .sessionRevoked)
        let clicks = await pageNumber(harness.webView, "window.__clicks || 0")
        XCTAssertEqual(clicks, 0)
    }

    /// A grant is pinned to the origin it was given for. This drives the tab to a
    /// different site and asserts the next action is refused rather than
    /// inherited.
    func testLeavingTheOriginEndsTheSession() async throws {
        let harness = try await self.harness(Page.counter)
        try await grant(harness)
        let listing = try await snapshot(harness)
        let ordinary = try id(of: listing, named: "Show more")

        harness.webView.loadHTMLString(
            "<html><body><button>Show more</button></body></html>",
            baseURL: URL(string: "https://elsewhere.invalid/")
        )
        for _ in 0..<400 where harness.webView.url?.host != "elsewhere.invalid" {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        let result = await harness.bridge.perform(
            .click(element: ordinary, expectName: "Show more",
                   document: listing.document, waitMS: 500),
            on: harness.tab.id,
            by: .mcp
        )
        XCTAssertEqual(result.refusalReason, .originChanged)
        XCTAssertFalse(harness.store.hasLiveSession(forTab: harness.tab.id))
    }

    // MARK: - Stale ids

    /// An element number means nothing without the page load it was minted in.
    ///
    /// Same URL, same origin, same markup — only the document is new, because the
    /// page was loaded again. The old numbers would still RESOLVE against a naive
    /// implementation; the token is what makes them refuse.
    func testAStaleDocumentIsRefusedAndTheLiveOneIsNamed() async throws {
        let harness = try await self.harness(Page.counter)
        try await grant(harness)
        let first = try await snapshot(harness)
        let ordinary = try id(of: first, named: "Show more")

        try await MCPPageFixture.load(Page.counter, into: harness.webView)

        let second = try await snapshot(harness)
        XCTAssertNotEqual(second.document, first.document,
                          "a fresh load must mint a new document token")

        let result = await harness.bridge.perform(
            .click(element: ordinary, expectName: "Show more",
                   document: first.document, waitMS: 500),
            on: harness.tab.id,
            by: .mcp
        )
        guard case .refused(let refusal) = result else {
            return XCTFail("a stale document must be refused; got \(result)")
        }
        XCTAssertEqual(refusal.reason, .snapshotGone)
        XCTAssertEqual(refusal.document, second.document,
                       "the refusal names the document the tab is actually on")
        let clicks = await pageNumber(harness.webView, "window.__clicks || 0")
        XCTAssertEqual(clicks, 0)
    }

    /// The other half: the SAME number, with the CURRENT document, still works.
    /// Without this the test above would pass for a bridge that refused
    /// everything.
    func testTheSameNumberWithTheLiveDocumentIsAccepted() async throws {
        let harness = try await self.harness(Page.counter)
        try await grant(harness)
        let listing = try await snapshot(harness)
        let ordinary = try id(of: listing, named: "Show more")

        let result = await harness.bridge.perform(
            .click(element: ordinary, expectName: "Show more",
                   document: listing.document, waitMS: 800),
            on: harness.tab.id,
            by: .mcp
        )
        XCTAssertEqual(result.outcome, .changed, "\(result)")
        let clicks = await pageNumber(harness.webView, "window.__clicks || 0")
        XCTAssertEqual(clicks, 1)
    }

    func testANumberThatWasNeverIssuedIsRefusedAsSuch() async throws {
        let harness = try await self.harness(Page.counter)
        try await grant(harness)
        let listing = try await snapshot(harness)

        let result = await harness.bridge.perform(
            .click(element: 9_999, expectName: "Show more",
                   document: listing.document, waitMS: 0),
            on: harness.tab.id,
            by: .mcp
        )
        XCTAssertEqual(result.refusalReason, .unknownElement)
    }

    // MARK: - The element the model agreed to

    func testANameThatNoLongerMatchesAbortsRatherThanClicking() async throws {
        let harness = try await self.harness(Page.counter)
        try await grant(harness)
        let listing = try await snapshot(harness)
        let ordinary = try id(of: listing, named: "Show more")

        _ = try? await harness.webView.evaluateJavaScript(
            "document.getElementById('ordinary').textContent = 'Delete everything';"
        )

        let result = await harness.bridge.perform(
            .click(element: ordinary, expectName: "Show more",
                   document: listing.document, waitMS: 0),
            on: harness.tab.id,
            by: .mcp
        )
        XCTAssertEqual(result.refusalReason, .nameMismatch)
        let clicks = await pageNumber(harness.webView, "window.__clicks || 0")
        XCTAssertEqual(clicks, 0, "the id still resolved, to something the model did not choose")
    }

    // MARK: - Irreversible interception, INSIDE a live session

    func testACommitmentShapedButtonIsRefusedEvenInsideALiveSession() async throws {
        let harness = try await self.harness(Page.counter)
        try await grant(harness)
        let listing = try await snapshot(harness)
        let commit = try id(of: listing, named: "Confirm transfer of $5000")

        let result = await harness.bridge.perform(
            .click(element: commit, expectName: "Confirm transfer of $5000",
                   document: listing.document, waitMS: 0),
            on: harness.tab.id,
            by: .mcp
        )
        guard case .refused(let refusal) = result else {
            return XCTFail("expected a refusal; got \(result)")
        }
        XCTAssertEqual(refusal.reason, .irreversible)
        XCTAssertEqual(refusal.name, "Confirm transfer of $5000",
                       "the user has to be told which control it was")
    }

    func testAFileInputIsRefusedByRoleBeforeAnythingOpensAPanel() async throws {
        let harness = try await self.harness(Page.counter)
        try await grant(harness)
        let listing = try await snapshot(harness)
        let upload = try id(of: listing, named: "Choose a file")

        let result = await harness.bridge.perform(
            .click(element: upload, expectName: "Choose a file",
                   document: listing.document, waitMS: 0),
            on: harness.tab.id,
            by: .mcp
        )
        XCTAssertEqual(result.refusalReason, .filePicker)
    }

    func testAPasswordFieldIsRefusedWhateverTheTextIs() async throws {
        let harness = try await self.harness(Page.counter)
        try await grant(harness)
        let listing = try await snapshot(harness)
        let secret = try id(of: listing, named: "Password")

        let result = await harness.bridge.perform(
            .type(element: secret, expectName: "Password", document: listing.document,
                  text: "hunter2", append: false, submit: false, waitMS: 0),
            on: harness.tab.id,
            by: .mcp
        )
        XCTAssertEqual(result.refusalReason, .passwordField)
        let value = await pageString(harness.webView, "document.getElementById('secret').value")
        XCTAssertEqual(value, "", "nothing was written into the password field")
    }

    func testAButtonIsNotSomethingToTypeInto() async throws {
        let harness = try await self.harness(Page.counter)
        try await grant(harness)
        let listing = try await snapshot(harness)
        let ordinary = try id(of: listing, named: "Show more")

        let result = await harness.bridge.perform(
            .type(element: ordinary, expectName: "Show more", document: listing.document,
                  text: "hello", append: false, submit: false, waitMS: 0),
            on: harness.tab.id,
            by: .mcp
        )
        XCTAssertEqual(result.refusalReason, .notATextField)
    }

    // MARK: - Outcomes

    func testAClickThatChangesNothingIsReportedAsNoEffect() async throws {
        let harness = try await self.harness(Page.counter)
        try await grant(harness)
        let listing = try await snapshot(harness)
        let quiet = try id(of: listing, named: "Does nothing visible")

        let result = await harness.bridge.perform(
            .click(element: quiet, expectName: "Does nothing visible",
                   document: listing.document, waitMS: 700),
            on: harness.tab.id,
            by: .mcp
        )
        XCTAssertEqual(result.outcome, .noEffect, "\(result)")
        // It really was clicked — `no_effect` is a statement about the PAGE, not
        // about whether Cherry did anything.
        let quietClicks = await pageNumber(harness.webView, "window.__quiet || 0")
        XCTAssertEqual(quietClicks, 1)
    }

    /// A same-document URL change is a new page to the user and to the site's own
    /// router, so it burns every element number — which is exactly what
    /// `navigated` means to a model.
    func testASameDocumentURLChangeIsReportedAsANavigation() async throws {
        let harness = try await self.harness(Page.counter)
        try await grant(harness)
        let listing = try await snapshot(harness)
        let link = try id(of: listing, named: "Jump to results")

        let result = await harness.bridge.perform(
            .click(element: link, expectName: "Jump to results",
                   document: listing.document, waitMS: 1_500),
            on: harness.tab.id,
            by: .mcp
        )
        guard case .acted(let acted) = result else {
            return XCTFail("expected an action; got \(result)")
        }
        XCTAssertEqual(acted.outcome, .navigated)
        XCTAssertTrue(acted.snapshotInvalidated)
        XCTAssertNotNil(acted.note)

        // A navigation within the same site does NOT end the grant — logging in
        // navigates, and a session that died on the first click would be a
        // session for nothing.
        XCTAssertTrue(harness.store.hasLiveSession(forTab: harness.tab.id))
    }

    // MARK: - Typing

    /// The difference between "the field contains the text" and "the app knows".
    func testTypingReachesTheApplicationsOwnStateAndNotJustTheDOM() async throws {
        let harness = try await self.harness(Page.tracked)
        try await grant(harness)
        let listing = try await snapshot(harness)
        let field = try id(of: listing, named: "Search with DuckDuckGo")

        let result = await harness.bridge.perform(
            .type(element: field, expectName: "Search with DuckDuckGo", document: listing.document,
                  text: "swift actor isolation", append: false, submit: false, waitMS: 800),
            on: harness.tab.id,
            by: .mcp
        )
        guard case .acted(let acted) = result else {
            return XCTFail("expected an action; got \(result)")
        }
        XCTAssertEqual(acted.valueAfter, "swift actor isolation")
        XCTAssertEqual(acted.frameworkObserved, true)

        let appState = await pageString(harness.webView, "window.__appState")
        XCTAssertEqual(appState, "swift actor isolation",
                       "the DOM showed the text but the application never saw it")
    }

    func testAppendAddsToTheEndRatherThanReplacing() async throws {
        let harness = try await self.harness(Page.tracked)
        try await grant(harness)
        let listing = try await snapshot(harness)
        let field = try id(of: listing, named: "Search with DuckDuckGo")

        _ = await harness.bridge.perform(
            .type(element: field, expectName: "Search with DuckDuckGo", document: listing.document,
                  text: "swift", append: false, submit: false, waitMS: 300),
            on: harness.tab.id, by: .mcp
        )
        let result = await harness.bridge.perform(
            .type(element: field, expectName: "Search with DuckDuckGo", document: listing.document,
                  text: " actors", append: true, submit: false, waitMS: 300),
            on: harness.tab.id, by: .mcp
        )
        guard case .acted(let acted) = result else {
            return XCTFail("expected an action; got \(result)")
        }
        XCTAssertEqual(acted.valueAfter, "swift actors")
    }

    // MARK: - submit: true, which is the hole the plan named

    /// Enter in a form presses that form's default button, so the default button
    /// is put through the same commitment rule a direct click on it would be.
    /// This is the difference between a warning in a description and a control.
    func testSubmitTrueIsRefusedWhenTheFormsOwnButtonLooksLikeACommitment() async throws {
        let harness = try await self.harness(Page.form(buttonLabel: "Pay now"))
        try await grant(harness)
        let listing = try await snapshot(harness)
        let field = try id(of: listing, named: "Search the store")

        let result = await harness.bridge.perform(
            .type(element: field, expectName: "Search the store", document: listing.document,
                  text: "1000", append: false, submit: true, waitMS: 500),
            on: harness.tab.id,
            by: .mcp
        )
        guard case .refused(let refusal) = result else {
            return XCTFail("expected a refusal; got \(result)")
        }
        XCTAssertEqual(refusal.reason, .irreversible)
        XCTAssertEqual(refusal.name, "Pay now")

        let value = await pageString(harness.webView, "document.getElementsByName('q')[0].value")
        XCTAssertEqual(value, "", "the refusal happened BEFORE anything was typed")
        let submits = await pageNumber(harness.webView, "window.__submitClicks || 0")
        XCTAssertEqual(submits, 0)
    }

    /// The same call with an ordinary button types and presses the button, which
    /// is what makes the refusal above a decision rather than a blanket ban.
    func testSubmitTrueTypesAndPressesAnOrdinaryFormButton() async throws {
        let harness = try await self.harness(Page.form(buttonLabel: "Search"))
        try await grant(harness)
        let listing = try await snapshot(harness)
        let field = try id(of: listing, named: "Search the store")

        let result = await harness.bridge.perform(
            .type(element: field, expectName: "Search the store", document: listing.document,
                  text: "socks", append: false, submit: true, waitMS: 700),
            on: harness.tab.id,
            by: .mcp
        )
        guard case .acted(let acted) = result else {
            return XCTFail("expected an action; got \(result)")
        }
        XCTAssertEqual(acted.submitted, true)
        let value = await pageString(harness.webView, "document.getElementsByName('q')[0].value")
        XCTAssertEqual(value, "socks")
        let submits = await pageNumber(harness.webView, "window.__submitClicks || 0")
        XCTAssertEqual(submits, 1, "Enter in a form is the form's button being pressed")
    }

    /// **Fix round 1, item 1.** The page inserts a commitment-shaped submit
    /// button from its own Enter handler, which runs synchronously inside
    /// Cherry's evaluation, before the old code re-queried the form.
    ///
    /// Before the fix this pressed "Confirm payment" on a call whose gate had
    /// passed on "Search". The button is now pinned by object identity at `arm`
    /// and re-verified immediately before the click, so the inserted one is not
    /// the one that gets pressed.
    func testAButtonTheEnterHandlerInsertsIsNotThePressedOne() async throws {
        let harness = try await self.harness(Page.formThatSwapsItsButtonOnEnter)
        try await grant(harness)
        let listing = try await snapshot(harness)
        let field = try id(of: listing, named: "Search the store")

        let result = await harness.bridge.perform(
            .type(element: field, expectName: "Search the store", document: listing.document,
                  text: "socks", append: false, submit: true, waitMS: 800),
            on: harness.tab.id,
            by: .mcp
        )

        let confirmed = await pageNumber(harness.webView, "window.__confirmClicks || 0")
        XCTAssertEqual(
            confirmed, 0,
            "Cherry pressed a button the page inserted after the commitment check had passed"
        )
        // And the inserted button really was there, so the test is not passing
        // because the fixture failed to fire.
        let inserted = await pageNumber(
            harness.webView, "document.getElementById('evil') ? 1 : 0"
        )
        XCTAssertEqual(inserted, 1, "the fixture never inserted its button, so nothing was tested")

        // The pinned button is now no longer the form's first submit control, so
        // Cherry declines to press anything rather than pressing the wrong one —
        // and says which it was.
        guard case .acted(let acted) = result else {
            return XCTFail("expected an action; got \(result)")
        }
        let searched = await pageNumber(harness.webView, "window.__searchClicks || 0")
        XCTAssertEqual(searched, 0, "the pinned button was displaced and must not be pressed either")
        XCTAssertEqual(acted.submitted, true, "Enter was pressed")
        XCTAssertNotNil(acted.note)
        XCTAssertTrue(
            acted.note?.contains("was NOT") == true,
            "the model must be told the form's button was not pressed: \(acted.note ?? "nil")"
        )
    }

    /// **Fix round 1, item 2.** Enter in a composer is where the web puts *send*,
    /// and no `<form>` is involved, so nothing was classified and the full Enter
    /// sequence was dispatched anyway.
    func testSubmitTrueIsRefusedInAComposerWithNothingToClassify() async throws {
        let harness = try await self.harness(Page.composer)
        try await grant(harness)
        let listing = try await snapshot(harness)
        let box = try id(of: listing, named: "Message")

        let result = await harness.bridge.perform(
            .type(element: box, expectName: "Message", document: listing.document,
                  text: "on my way", append: false, submit: true, waitMS: 500),
            on: harness.tab.id,
            by: .mcp
        )

        guard case .refused(let refusal) = result else {
            return XCTFail("expected a refusal; got \(result)")
        }
        XCTAssertEqual(refusal.reason, .unclassifiableSubmit)
        let sent = await pageNumber(harness.webView, "window.__sent || 0")
        XCTAssertEqual(sent, 0, "Enter reached the composer's own send handler")
        let text = await pageString(harness.webView, "document.getElementById('box').textContent")
        XCTAssertEqual(text, "", "the refusal must happen before anything is typed")
    }

    /// The other half, so the refusal above is a decision rather than "typing
    /// into a composer is broken": without `submit`, the same call works.
    func testTypingIntoAComposerWithoutSubmitStillWorks() async throws {
        let harness = try await self.harness(Page.composer)
        try await grant(harness)
        let listing = try await snapshot(harness)
        let box = try id(of: listing, named: "Message")

        let result = await harness.bridge.perform(
            .type(element: box, expectName: "Message", document: listing.document,
                  text: "on my way", append: false, submit: false, waitMS: 500),
            on: harness.tab.id,
            by: .mcp
        )
        XCTAssertEqual(result.outcome, .changed, "\(result)")
        let text = await pageString(harness.webView, "document.getElementById('box').textContent")
        XCTAssertEqual(text, "on my way")
        let sent = await pageNumber(harness.webView, "window.__sent || 0")
        XCTAssertEqual(sent, 0)
    }

    /// **Fix round 1, item 4.** The display form is capped at 100 characters, so
    /// a page can rewrite the tail of a long name and both sides still sanitise
    /// to the same `prefix(99) + "…"`.
    ///
    /// The raw name recorded at listing time — in the isolated world, where the
    /// page cannot reach it — is what makes the two distinguishable.
    func testRewritingTheInvisibleTailOfALongNameIsRefused() async throws {
        let harness = try await self.harness(Page.longNamed(tail: "and nothing else"))
        try await grant(harness)
        let listing = try await snapshot(harness)
        let shown = try XCTUnwrap(listing.elements.first)
        XCTAssertTrue(shown.name.hasSuffix("…"), "the fixture's name must be long enough to clip")

        // Rewrite only what the model cannot see.
        _ = try? await harness.webView.evaluateJavaScript(
            "document.getElementById('long').textContent = "
                + "document.getElementById('long').textContent"
                + ".replace('and nothing else', 'and Confirm transfer of $5000');"
        )

        let result = await harness.bridge.perform(
            .click(element: shown.id, expectName: shown.name,
                   document: listing.document, waitMS: 0),
            on: harness.tab.id,
            by: .mcp
        )
        XCTAssertEqual(result.refusalReason, .nameMismatch)
        let clicks = await pageNumber(harness.webView, "window.__longClicks || 0")
        XCTAssertEqual(clicks, 0)
    }

    /// And an unchanged long name still works, so the check above is not simply
    /// refusing everything with a clipped name.
    func testAnUnchangedLongNameIsStillClickable() async throws {
        let harness = try await self.harness(Page.longNamed(tail: "and nothing else"))
        try await grant(harness)
        let listing = try await snapshot(harness)
        let shown = try XCTUnwrap(listing.elements.first)

        let result = await harness.bridge.perform(
            .click(element: shown.id, expectName: shown.name,
                   document: listing.document, waitMS: 400),
            on: harness.tab.id,
            by: .mcp
        )
        XCTAssertNotNil(result.outcome, "\(result)")
        let clicks = await pageNumber(harness.webView, "window.__longClicks || 0")
        XCTAssertEqual(clicks, 1)
    }

    // MARK: - The audit log, through the real path

    func testTheAuditLogRecordsTheTypingWithoutTheText() async throws {
        let harness = try await self.harness(Page.tracked)
        try await grant(harness, purpose: "Search the docs for actor isolation")
        let listing = try await snapshot(harness)
        let field = try id(of: listing, named: "Search with DuckDuckGo")

        let secret = "correcthorsebatterystaple"
        let result = await harness.bridge.perform(
            .type(element: field, expectName: "Search with DuckDuckGo", document: listing.document,
                  text: secret, append: false, submit: false, waitMS: 400),
            on: harness.tab.id,
            by: .mcp
        )
        XCTAssertNotNil(result.outcome, "\(result)")

        let url = try XCTUnwrap(harness.audit.fileURL)
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(written.contains("\"chars_typed\":\(secret.count)"))
        XCTAssertTrue(written.contains("Search the docs for actor isolation"),
                      "the action is recorded against the purpose the session was opened for")

        let characters = Array(secret)
        for length in 4...characters.count {
            for start in 0...(characters.count - length) {
                let fragment = String(characters[start..<(start + length)])
                XCTAssertFalse(
                    written.lowercased().contains(fragment.lowercased()),
                    "the audit log contains \"\(fragment)\" — a fragment of what was typed"
                )
            }
        }
    }

    /// **Fix round 1, item 6.** The entry type has no field for typed text, and
    /// that was true of its shape and false of its contents.
    ///
    /// The accessible-name ladder's fourth rung is `el.innerText`. On a
    /// `contenteditable` that IS what was typed — so typing into a composer and
    /// then acting on the same element again wrote the first message into `name`.
    /// The earlier tests missed it because both typed into a plain `<input>` and
    /// acted once; this one is the sequence that leaks.
    func testTypingIntoAComposerTwiceDoesNotWriteTheFirstMessageToTheLog() async throws {
        let harness = try await self.harness(Page.unlabelledComposer)
        try await grant(harness, purpose: "Reply to the message in the composer")
        let listing = try await snapshot(harness)
        // While it is empty the ladder falls past the text rung all the way to
        // `id`, so the listing shows "composer". The moment anything is typed in,
        // the text rung fires first and the name becomes that text — which is the
        // whole leak.
        let box = try id(of: listing, named: "composer")

        let secret = "correcthorsebatterystaple"
        let first = await harness.bridge.perform(
            .type(element: box, expectName: "composer", document: listing.document,
                  text: secret, append: false, submit: false, waitMS: 400),
            on: harness.tab.id, by: .mcp
        )
        XCTAssertNotNil(first.outcome, "\(first)")

        // The element's accessible name IS the typed text now — re-list to get
        // the name the second call has to agree to, exactly as a model would.
        let second = try await snapshot(harness)
        let renamed = try XCTUnwrap(second.elements.first { $0.id == box })
        XCTAssertEqual(
            renamed.name, secret,
            "the fixture must reach the state where the name is the typed text"
        )

        let again = await harness.bridge.perform(
            .type(element: box, expectName: renamed.name, document: second.document,
                  text: " on my way", append: true, submit: false, waitMS: 400),
            on: harness.tab.id, by: .mcp
        )
        XCTAssertNotNil(again.outcome, "\(again)")

        let url = try XCTUnwrap(harness.audit.fileURL)
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(written.contains(WebActionBridge.withheldName),
                      "the entry must say the name was withheld, not simply omit it")

        let characters = Array(secret)
        for length in 4...characters.count {
            for start in 0...(characters.count - length) {
                let fragment = String(characters[start..<(start + length)])
                XCTAssertFalse(
                    written.lowercased().contains(fragment.lowercased()),
                    "the audit log contains \"\(fragment)\" — a fragment of what was typed, "
                        + "reached through the element's accessible name"
                )
            }
        }
    }

    /// The suppression is by NAME RUNG and editable host, not by tag, so an
    /// ordinary button whose label happens to be its text is still recorded — the
    /// audit log would be useless if every name were withheld.
    func testAnOrdinaryControlsNameIsStillRecorded() async throws {
        let harness = try await self.harness(Page.counter)
        try await grant(harness)
        let listing = try await snapshot(harness)
        let ordinary = try id(of: listing, named: "Show more")

        _ = await harness.bridge.perform(
            .click(element: ordinary, expectName: "Show more",
                   document: listing.document, waitMS: 400),
            on: harness.tab.id, by: .mcp
        )

        let url = try XCTUnwrap(harness.audit.fileURL)
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(written.contains("\"name\":\"Show more\""))
        XCTAssertFalse(written.contains(WebActionBridge.withheldName))
    }

    // MARK: - The audit log cannot be flushed by the actor it records

    /// Gate refusals are the only entries an unauthorised caller can produce, and
    /// the log rotates at a size cap. Sharing one file gave a token holder with
    /// no session a way to erase the record of the sessions that did happen.
    func testASessionlessCallerWritesToADifferentFile() async throws {
        let harness = try await self.harness(Page.counter)
        try await grant(harness)
        let listing = try await snapshot(harness)
        let ordinary = try id(of: listing, named: "Show more")

        // One real action, from a real session.
        _ = await harness.bridge.perform(
            .click(element: ordinary, expectName: "Show more",
                   document: listing.document, waitMS: 400),
            on: harness.tab.id, by: .mcp
        )
        let actionsURL = try XCTUnwrap(harness.audit.fileURL)
        let before = try String(contentsOf: actionsURL, encoding: .utf8)

        // Then a caller with no grant, hammering.
        for _ in 0..<20 {
            _ = await harness.bridge.perform(
                .click(element: 1, expectName: "x", document: "y", waitMS: 0),
                on: UUID(), by: .localAgent
            )
        }

        let after = try String(contentsOf: actionsURL, encoding: .utf8)
        XCTAssertEqual(before, after, "a sessionless caller wrote into the action log")

        let refusedURL = try XCTUnwrap(harness.audit.sessionlessURL)
        let refused = try String(contentsOf: refusedURL, encoding: .utf8)
        XCTAssertEqual(
            refused.split(separator: "\n", omittingEmptySubsequences: true).count, 20,
            "the refusals still have to be recorded, just not there"
        )
    }

    /// `document` arrives from the caller on the refusal paths, so an uncapped
    /// one is a rotation lever rather than a token.
    func testACallersDocumentCannotBeUnboundedInTheLog() async throws {
        let harness = try await self.harness(Page.counter)
        _ = await harness.bridge.perform(
            .click(element: 1, expectName: "x",
                   document: String(repeating: "A", count: 100_000), waitMS: 0),
            on: UUID(), by: .mcp
        )
        let refused = try String(
            contentsOf: try XCTUnwrap(harness.audit.sessionlessURL), encoding: .utf8
        )
        XCTAssertLessThan(refused.count, 2_000, "one refusal line carried 100,000 caller bytes")
        XCTAssertTrue(refused.contains("…"), "the cut has to be visible")
    }

    func testARefusedActionIsRecordedToo() async throws {
        let harness = try await self.harness(Page.counter)
        try await grant(harness)
        let listing = try await snapshot(harness)
        let commit = try id(of: listing, named: "Confirm transfer of $5000")

        _ = await harness.bridge.perform(
            .click(element: commit, expectName: "Confirm transfer of $5000",
                   document: listing.document, waitMS: 0),
            on: harness.tab.id,
            by: .mcp
        )

        let url = try XCTUnwrap(harness.audit.fileURL)
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(written.contains("\"decision\":\"refused\""))
        XCTAssertTrue(written.contains("\"result\":\"irreversible\""))
        XCTAssertTrue(written.contains("Confirm transfer of $5000"),
                      "what was refused has to be visible afterwards, not only what happened")
    }

    // MARK: - The tab has to be one that can be acted on at all

    func testASleepingTabCannotBeGrantedASession() async throws {
        let harness = try await self.harness(Page.counter)
        harness.tab.sleep()

        let result = await harness.bridge.requestSession(
            tabID: harness.tab.id, purpose: "Do something in this tab", minutes: 10, by: .mcp
        )
        guard case .refused(let refusal) = result else {
            return XCTFail("expected a refusal; got \(result)")
        }
        XCTAssertEqual(refusal.reason, .sleeping)
        XCTAssertTrue(harness.store.pending.isEmpty,
                      "the user was never asked about a tab there is nothing to act on")
    }

    func testASleepingTabEndsALiveSession() async throws {
        let harness = try await self.harness(Page.counter)
        try await grant(harness)
        XCTAssertTrue(harness.store.hasLiveSession(forTab: harness.tab.id))

        // `Tab.sleep()` ends grants through the shared store; the harness's store
        // is a separate instance, so this asserts the bridge's own ladder instead
        // — which is the enforcement that matters.
        harness.tab.sleep()

        let result = await harness.bridge.perform(
            .click(element: 1, expectName: "Show more", document: "any", waitMS: 0),
            on: harness.tab.id,
            by: .mcp
        )
        XCTAssertEqual(result.refusalReason, .sleeping)
        XCTAssertFalse(harness.store.hasLiveSession(forTab: harness.tab.id),
                       "a tab that can no longer be acted on takes its grant with it")
    }
}
