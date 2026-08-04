//
//  WebActionBridge.swift
//  Cherry Browser
//
//  The action layer's one door onto a page. In this slice it only reads.
//
//  ## What this file does NOT do, and where those things attach
//
//  * **Consent (plan step 2).** Nothing here writes, so nothing here needs a
//    grant. `snapshot` is deliberately outside any future gate: requiring
//    permission to LOOK would force a model to ask for permission to act before
//    it knows whether it needs any. When `click`/`type` land they get a
//    `WebActionSessionStore.liveSession(forTab:requester:)` check as the FIRST
//    statement of a `perform(_:on:by:)` that they, and not this method, go
//    through.
//  * **Auditing (plan step 3).** An audit log answers "did it do something I did
//    not intend", and reading a list of controls does nothing. `read_page` is
//    not audited either, and this is `read_page`-class.
//  * **Acting (plan step 5).** `WebActionScripts.resolve(id:expectName:)` is
//    already written and already returns the hit test and both names; what is
//    missing is the outcome watcher and the two element-level primitives.
//
//  ## Two things it inherits rather than re-implements
//
//  **Privacy.** Every tab reaches this file through
//  `MCPBrowserBridge.resolveTab(tabID:)`, which is the single window
//  enumeration and the two-level (window `isPrivateMode`, tab `isPrivate`)
//  gate. There is deliberately no second enumeration here: one misplaced
//  predicate in a second one is an incognito leak, and the leak is silent.
//
//  **The refusal ladder.** `MCPBrowserBridge.readableWebView(for:_:)` — sleeping,
//  `cherry://`, home page, never-rendered, PDF. An element snapshot of a
//  `cherry://settings` tab must be exactly as impossible as reading one, and the
//  way to guarantee that is to run the same five rungs and not a copy of them.
//
//  ## Isolation
//
//  `@MainActor` by construction (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`),
//  like `MCPBrowserBridge` and every browser type it touches. It returns
//  `Sendable` values only, so the SDK's executor never sees a `Tab` or a
//  `WKWebView`.
//

import Foundation
import WebKit

final class WebActionBridge {

    static let shared = WebActionBridge()

    /// The isolated world, HELD.
    ///
    /// Not an inline `.world(name:)` at the call site, and this is the bug that
    /// found it. `WKContentWorld.world(name:)` vends the world, but nothing keeps
    /// it alive on the caller's behalf: let the object go between calls and the
    /// world's script context goes with it, taking `window.__cherryAct` and every
    /// handle in it. The symptom was the exact defect this whole design exists to
    /// prevent — a second snapshot of an unchanged page reissued its ids from 1,
    /// so a number the model already held silently came to mean a different
    /// element. `testHandleIdsSurviveTheReshuffleThatBreaksPositionalIds` is what
    /// caught it and is what would catch it again.
    private static let actionWorld = WKContentWorld.world(name: WebActionScripts.worldName)

    private let browser: () -> MCPBrowserBridge

    /// - Parameter browser: injected so a test drives a bridge built over a
    ///   known set of windows rather than whatever the running app has open.
    init(browser: @escaping () -> MCPBrowserBridge = { MCPBrowserBridge.shared }) {
        self.browser = browser
    }

    // MARK: - snapshot

    /// List what can be clicked and typed into, in one tab's main frame.
    func snapshot(
        tabID: UUID?,
        scope: WebActionScope,
        filter: String?
    ) async -> WebActionSnapshotOutcome {
        let bridge = browser()

        let viewModel: BrowserViewModel
        let tab: Tab
        switch bridge.resolveTab(tabID: tabID) {
        case .success(let located):
            (viewModel, tab) = located
        case .failure(let refusal):
            return .unreadable(MCPUnreadablePayload(
                reason: refusal.reason,
                detail: refusal.detail,
                tabID: tabID?.uuidString,
                windowID: nil,
                url: nil
            ))
        }

        let identity = (
            tabID: tab.id.uuidString,
            windowID: viewModel.windowID.uuidString,
            url: tab.displayURL.mcpTruncated(to: MCPResultCaps.urlChars)
        )

        let webView: WKWebView
        switch await bridge.readableWebView(for: tab, MCPWebViewPurpose.listingElements) {
        case .success(let live):
            webView = live
        case .failure(let refusal):
            return .unreadable(MCPUnreadablePayload(
                reason: refusal.reason,
                detail: refusal.detail,
                tabID: identity.tabID,
                windowID: identity.windowID,
                // The cherry:// rung's own address, never the covered site's.
                url: refusal.urlOverride ?? identity.url
            ))
        }

        // One call, in the isolated world. `installWorld` is prepended to the
        // snapshot rather than sent first, so there is no window in which a
        // navigation between the two leaves the second talking to a world that
        // no longer exists.
        let script = WebActionScripts.snapshot(scope: scope.rawValue, filter: filter)
        let raw: Any?
        do {
            raw = try await webView.evaluateJavaScript(script, in: nil, contentWorld: Self.actionWorld)
        } catch {
            // A failure, not a refusal: the call was well-formed and Cherry could
            // not carry it out. A model handed an empty success would paper over
            // it and tell the user the page has no controls.
            return .failed(
                "Cherry could not build an element snapshot of this page: "
                    + error.localizedDescription
            )
        }

        guard let json = raw as? String,
              let data = json.data(using: .utf8),
              let result = try? JSONDecoder().decode(RawSnapshot.self, from: data)
        else {
            return .failed(
                "Cherry's element snapshot returned something it could not read back. "
                    + "Do not retry, and do not guess what the page contains."
            )
        }

        guard result.ok else {
            // The only `ok: false` this slice can produce is a world that was not
            // there a statement after being installed, i.e. the document went away
            // mid-call.
            return .unreadable(MCPUnreadablePayload(
                reason: .noContent,
                detail: "The page changed while Cherry was listing its controls, so the listing was "
                    + "abandoned. Call read_elements again.",
                tabID: identity.tabID,
                windowID: identity.windowID,
                url: identity.url
            ))
        }

        return .snapshot(assemble(result, identity: identity, requested: scope))
    }

    // MARK: - Assembly

    /// Sanitise, classify, render and cap — in that order, in Swift.
    ///
    /// The order matters. Nothing the page wrote is rendered before it has been
    /// through `sanitiseName`, and the cap is applied to the RENDERED line, so
    /// the budget counts the characters that actually reach a model rather than
    /// an estimate of them.
    private func assemble(
        _ raw: RawSnapshot,
        identity: (tabID: String, windowID: String, url: String),
        requested: WebActionScope
    ) -> WebActionSnapshot {
        var budget = MCPBudget(chars: MCPResultCaps.payloadChars, items: MCPResultCaps.elementsListed)
        var elements: [WebActionElement] = []

        for row in raw.elements {
            let name = WebActionScripts.sanitiseName(row.name)
            let commitment = WebActionHeuristics.classify(WebActionElementDescriptor(
                role: row.role,
                // The RAW name, deliberately. `sanitiseName` is for display; a
                // verb test run over the display form would match differently for
                // `"Buy\u{2028}now"` than for `"Buy now"`, and a page picks which
                // one it writes.
                name: row.name,
                tag: row.tag,
                type: row.type,
                hasHref: row.href,
                hrefIsNavigational: row.nav,
                inForm: row.form
            ))
            let element = WebActionElement(
                id: row.id,
                role: row.role,
                name: name,
                commitment: commitment,
                disabled: row.disabled,
                checked: row.checked,
                expanded: row.expanded,
                value: row.value.map { WebActionScripts.sanitiseName($0) },
                offscreen: row.offscreen
            )
            // +1 for the newline that will join it.
            guard budget.admit(chars: element.listingLine.count + 1) else { break }
            elements.append(element)
        }

        let effective = WebActionScope(rawValue: raw.scope) ?? requested
        let truncated = elements.count < raw.elements.count

        /// "1 element" / "3 elements", because a note that reads as machine
        /// output is a note a model skims.
        func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

        var notes: [String] = []
        if truncated {
            notes.append("\(elements.count) of \(count(raw.elements.count, "element")) shown "
                + "(\(budget.limitHitDescription)); pass filter to narrow to the control you want")
        }
        if effective == .viewport, raw.offscreenNotListed > 0 {
            notes.append("\(count(raw.offscreenNotListed, "more element")) "
                + "\(raw.offscreenNotListed == 1 ? "is" : "are") laid out but off screen; "
                + "pass scope: \"page\" for those too")
        }
        if !raw.pageVisible {
            notes.append("this tab is not being displayed, so it has no viewport and the on-screen "
                + "filter could not apply — every laid-out element is listed instead")
        }
        if raw.frames > 1 {
            notes.append("this page has \(raw.frames) frames and Cherry lists the main one only, so "
                + "controls inside the other \(raw.frames - 1) are missing from this list")
        }
        if raw.closedShadowHosts > 0 {
            notes.append("\(count(raw.closedShadowHosts, "element")) "
                + "\(raw.closedShadowHosts == 1 ? "looks" : "look") like "
                + "\(raw.closedShadowHosts == 1 ? "it hides" : "they hide") a closed shadow root, "
                + "whose contents no browser can list")
        }
        if raw.walkCapped {
            notes.append("this page has more elements than Cherry will walk in one pass, so the list "
                + "stops partway through the document")
        }
        if raw.filteredOut > 0 {
            notes.append("\(count(raw.filteredOut, "element")) "
                + "\(raw.filteredOut == 1 ? "was" : "were") left out because "
                + "\(raw.filteredOut == 1 ? "its name does" : "their names do") not contain the filter")
        }

        return WebActionSnapshot(
            tabID: identity.tabID,
            windowID: identity.windowID,
            url: raw.url.mcpTruncated(to: MCPResultCaps.urlChars),
            title: raw.title.mcpTruncated(to: MCPResultCaps.entryTitleChars),
            generation: raw.gen,
            document: raw.doc,
            scope: effective,
            elements: elements,
            matched: raw.matched,
            droppedNoLayout: raw.droppedNoLayout,
            offscreenNotListed: raw.offscreenNotListed,
            filteredOut: raw.filteredOut,
            frames: raw.frames,
            closedShadowHosts: raw.closedShadowHosts,
            shadowRootsEntered: raw.shadowRootsEntered,
            pageVisible: raw.pageVisible,
            visibility: raw.visibility,
            walkCapped: raw.walkCapped,
            truncated: truncated,
            note: notes.isEmpty ? nil : notes.joined(separator: ". ") + "."
        )
    }

    // MARK: - What the isolated world hands back

    /// The wire shape between `WebActionScripts` and this file, and nowhere else.
    ///
    /// `Decodable` — the one direction the payload types in `MCPToolPayloads` are
    /// deliberately not, because this is a page talking to Cherry rather than
    /// Cherry talking to a client, and every field in it is untrusted.
    private struct RawSnapshot: Decodable {
        let ok: Bool
        let gen: Int
        let doc: Int
        let url: String
        let title: String
        let scope: String
        let pageVisible: Bool
        let visibility: String
        let frames: Int
        let matched: Int
        let droppedNoLayout: Int
        let offscreenNotListed: Int
        let filteredOut: Int
        let shadowRootsEntered: Int
        let closedShadowHosts: Int
        let walkCapped: Bool
        let elements: [RawElement]

        private enum CodingKeys: String, CodingKey {
            case ok, gen, doc, url, title, scope, frames, matched, visibility, elements
            case pageVisible = "page_visible"
            case droppedNoLayout = "dropped_no_layout"
            case offscreenNotListed = "offscreen_not_listed"
            case filteredOut = "filtered_out"
            case shadowRootsEntered = "shadow_roots_entered"
            case closedShadowHosts = "closed_shadow_hosts"
            case walkCapped = "walk_capped"
        }

        /// Hand-written because the `ok: false` answer carries `ok` and a reason
        /// and nothing else, and a synthesised `init(from:)` would throw on the
        /// sixteen missing keys — turning "the document went away mid-call", which
        /// is a refusal a model can act on, into "Cherry could not read its own
        /// output", which is a failure it cannot. Swift does NOT fall back to a
        /// property's default value for a missing key; only `decodeIfPresent`
        /// does, which is why every field below is spelled out.
        init(from decoder: any Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            ok = try box.decodeIfPresent(Bool.self, forKey: .ok) ?? false
            gen = try box.decodeIfPresent(Int.self, forKey: .gen) ?? 0
            doc = try box.decodeIfPresent(Int.self, forKey: .doc) ?? 0
            url = try box.decodeIfPresent(String.self, forKey: .url) ?? ""
            title = try box.decodeIfPresent(String.self, forKey: .title) ?? ""
            scope = try box.decodeIfPresent(String.self, forKey: .scope) ?? ""
            pageVisible = try box.decodeIfPresent(Bool.self, forKey: .pageVisible) ?? true
            visibility = try box.decodeIfPresent(String.self, forKey: .visibility) ?? ""
            frames = try box.decodeIfPresent(Int.self, forKey: .frames) ?? 1
            matched = try box.decodeIfPresent(Int.self, forKey: .matched) ?? 0
            droppedNoLayout = try box.decodeIfPresent(Int.self, forKey: .droppedNoLayout) ?? 0
            offscreenNotListed = try box.decodeIfPresent(Int.self, forKey: .offscreenNotListed) ?? 0
            filteredOut = try box.decodeIfPresent(Int.self, forKey: .filteredOut) ?? 0
            shadowRootsEntered = try box.decodeIfPresent(Int.self, forKey: .shadowRootsEntered) ?? 0
            closedShadowHosts = try box.decodeIfPresent(Int.self, forKey: .closedShadowHosts) ?? 0
            walkCapped = try box.decodeIfPresent(Bool.self, forKey: .walkCapped) ?? false
            elements = try box.decodeIfPresent([RawElement].self, forKey: .elements) ?? []
        }
    }

    private struct RawElement: Decodable {
        let id: Int
        let role: String
        let name: String
        let tag: String
        let type: String?
        let href: Bool
        let nav: Bool
        let form: Bool
        let disabled: Bool
        let checked: Bool?
        let expanded: String?
        let value: String?
        let offscreen: Bool
    }
}

// MARK: - Outcome

/// Three genuinely different answers, shaped differently on purpose.
///
/// A REFUSAL is a successful call whose answer is "there is nothing here" — a
/// sleeping tab, a `cherry://` page — and carries `isError: false` so a model
/// picks a different move. A FAILURE is a call Cherry could not carry out, and
/// says so, because a model handed an empty success invents the rest.
nonisolated enum WebActionSnapshotOutcome: Sendable {
    case snapshot(WebActionSnapshot)
    case unreadable(MCPUnreadablePayload)
    case failed(String)

    var reason: MCPUnreadableReason? {
        if case .unreadable(let payload) = self { return payload.reason }
        return nil
    }

    var elements: [WebActionElement] {
        if case .snapshot(let payload) = self { return payload.elements }
        return []
    }
}
