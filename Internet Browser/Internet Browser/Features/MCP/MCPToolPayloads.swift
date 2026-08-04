//
//  MCPToolPayloads.swift
//  Cherry Browser
//
//  Everything the five tools send back, as flat `Sendable` structs.
//
//  ## Why these types exist at all
//
//  This is the boundary. `MCPBrowserBridge` runs on the main actor and reads
//  `TabManager`, `BrowserViewModel`, `HistoryRepository`, `BookmarkRepository`
//  and live `WKWebView`s. None of those may cross to the SDK's executor: they
//  are main-actor-isolated, and `HistoryItem`/`Bookmark` carry an `NSImage`
//  favicon that an MCP client has no use for anyway. So the bridge projects to
//  the structs below — `String`, `Int`, `Bool`, `Date` only — and those are the
//  ONLY things that come back off the main actor.
//
//  ## Why the JSON keys are written out by hand
//
//  These key names are part of the tool contract a model reads. They are spelled
//  in `CodingKeys` rather than produced by `.convertToSnakeCase` so that the wire
//  shape is visible in this file and cannot drift when a property is renamed.
//
//  ## Why every payload is `Encodable` and not `Codable`
//
//  Nothing in Cherry ever decodes one. Tests read the emitted JSON with
//  `JSONSerialization`, which is what a client sees, rather than round-tripping
//  through a decoder that would happily accept a shape no client would.
//

import Foundation
import MCP

// MARK: - Encoding

nonisolated enum MCPPayloadEncoding {

    /// Compact, ISO-8601 dates, stable key order.
    ///
    /// Compact because every byte of this lands in a model's context window.
    /// Sorted keys because a stable serialisation is worth more in a diff and a
    /// test than a hand-picked field order is to a JSON reader.
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// A tool result carrying `payload` as one JSON text block.
    ///
    /// One block, not several, because that is the unit Claude Code counts
    /// against its output-token limits.
    static func result(_ payload: some Encodable) -> CallTool.Result {
        guard let data = try? encoder.encode(payload),
              let json = String(data: data, encoding: .utf8)
        else {
            // Unreachable for these payloads — every field is a String, Int,
            // Bool, Date or an array of those. Answering `isError` rather than
            // returning half a document is still the right failure: a model that
            // receives a truncated success invents the rest.
            return MCPPayloadEncoding.failure(
                "Cherry could not serialise the result of this tool call."
            )
        }
        return CallTool.Result(content: [.text(text: json, annotations: nil, _meta: nil)])
    }

    /// A protocol-level failure: the call itself was wrong (unknown tool, an
    /// argument Cherry cannot use). Distinct from a *refusal*, which is a
    /// successful call whose answer is "there is nothing here to give you" —
    /// those come back as `isError: false` with a machine-readable `reason`, so
    /// the model can act on them instead of retrying blindly.
    static func failure(_ message: String) -> CallTool.Result {
        CallTool.Result(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            isError: true
        )
    }
}

// MARK: - Caps

/// The output budget, in one place.
///
/// These results land in an LLM's context window; Claude Code warns above
/// ~10,000 tokens and hard-limits at ~25,000. A tool that floods the context is
/// worse than one that refuses, so every cap here is paired with something in
/// the payload that says it was hit — `truncated`, `has_more`, `next_offset`,
/// `note` — and never with silence.
nonisolated enum MCPResultCaps {

    /// The ceiling on ONE tool result's JSON body, for every tool.
    ///
    /// This exists because per-field and per-item caps do not bound a payload.
    /// 300 tabs at 120 title + 500 url + scaffolding is ~210,000 characters;
    /// 200 bookmarks is ~168,000; 100 history rows ~73,000 — all single-call, none
    /// chunked, and all far past the ~25,000-token hard limit this file's header
    /// names as the design constraint. A user with 300 tabs trips that without
    /// anyone being adversarial.
    ///
    /// 40,000 characters is ~10k tokens, the same number `read_page` chunks at, so
    /// every tool now answers within one budget and every tool that hits it says
    /// so. Paired with `anthropic/maxResultSizeChars = 60,000` declared on all four
    /// data-returning tools, which leaves the JSON envelope room on top.
    static let payloadChars = 40_000

    /// Tab titles. Long enough to identify a page, short enough that many of them
    /// are not the whole payload.
    static let tabTitleChars = 120

    /// URLs, everywhere. A long URL is still the identity of a page; 500 keeps
    /// pathological `data:` URLs out.
    static let urlChars = 500

    /// History and bookmark titles get more room than tab titles: they are the
    /// only thing identifying a page the user cannot see.
    static let entryTitleChars = 200

    /// Bookmark folder names.
    static let folderChars = 120

    /// Hard ceiling on tabs in one `list_tabs` answer, across all windows.
    static let tabs = 300

    /// Characters of page text per `read_page` call. ~10k tokens, i.e. Claude
    /// Code's warning threshold, and it pairs with the tool's declared
    /// `anthropic/maxResultSizeChars` of 60,000 so the JSON envelope has room.
    static let readPageChars = 40_000

    /// The most extracted text `read_page` will ever make reachable from one page,
    /// i.e. ten full chunks.
    ///
    /// Without this, nothing bounded the extracted string at all: the per-call cap
    /// applies AFTER the whole page is in hand, so a client walking an N-character
    /// page by `next_offset` did O(N) main-actor work per call for O(N/40000)
    /// calls, unbounded and unrated-limited. Clamping the page bounds every call to
    /// this size, and the payload says when it clamped.
    static let readPageTotalChars = 400_000

    /// Hard ceiling on elements in one `read_elements` answer.
    ///
    /// The binding limit is almost always `payloadChars` rather than this — a
    /// whole Wikipedia article's control list is 961 elements and ~36,000
    /// characters, so the size budget bites first. This is here for the page that
    /// is all short buttons, and it is paired with a `note` that says what was
    /// cut and what to do instead, like every other cap in this file.
    static let elementsListed = 500

    /// The most text one `type_text` call will carry, matching the tool's input
    /// schema. The SDK validates no schema at all, so this is what enforces it.
    static let typedTextChars = 10_000

    /// `search_history`'s `limit`, matching the tool's input schema.
    static let historyLimitDefault = 25
    static let historyLimitMaximum = 100

    /// `search_bookmarks`'s `limit`, matching the tool's input schema.
    static let bookmarkLimitDefault = 50
    static let bookmarkLimitMaximum = 200
}

/// A running character-and-item allowance for one tool result.
///
/// Built while a payload is assembled rather than checked afterwards, so nothing
/// is serialised only to be thrown away, and so the reason the answer stopped is
/// known and can be said out loud.
nonisolated struct MCPBudget {

    private let charLimit: Int
    private let itemLimit: Int
    private var chars = 0
    private var items = 0

    /// Which limit ran out first. `nil` while both still have room.
    private(set) var exhaustedBy: Limit?

    enum Limit { case chars, items }

    init(chars: Int, items: Int) {
        self.charLimit = chars
        self.itemLimit = items
    }

    var hasRoom: Bool { exhaustedBy == nil }

    /// Charges `chars` to the budget and says whether the item fits.
    ///
    /// The first item is always admitted, whatever it costs: an answer of "nothing,
    /// because the first row was too big" is useless, and a single row is bounded
    /// by the per-field caps anyway.
    mutating func admit(chars cost: Int) -> Bool {
        guard hasRoom else { return false }
        if items > 0, self.chars + cost > charLimit {
            exhaustedBy = .chars
            return false
        }
        self.chars += cost
        items += 1
        if items >= itemLimit { exhaustedBy = .items }
        return true
    }

    /// What to put in a `note`, so a client knows whether to narrow its query or
    /// simply ask for the next page.
    var limitHitDescription: String {
        switch exhaustedBy {
        case .chars: "result size limit of \(charLimit) characters reached"
        case .items: "cap of \(itemLimit) reached"
        case nil: "no limit reached"
        }
    }
}

extension MCPTabPayload {
    /// Roughly how many characters this row costs once serialised. Deliberately an
    /// over-estimate: the constant covers the key names, quoting and the booleans.
    var approximateChars: Int { title.count + url.count + tabID.count + 130 }
}

extension MCPHistoryEntryPayload {
    var approximateChars: Int { title.count + url.count + 90 }
}

extension MCPBookmarkEntryPayload {
    var approximateChars: Int { title.count + url.count + (folder?.count ?? 0) + 110 }
}

extension String {
    /// Truncated to `limit` characters with a visible marker.
    ///
    /// The marker matters: a silently clipped title reads as the page's real
    /// title, and a model will quote it back to the user as one.
    ///
    /// `nonisolated` because this target's default isolation would otherwise make
    /// it main-actor-only, and the off-main half of the tool path — encoding, and
    /// `MCPBrowserBridge.chunk` — needs it too. It is pure string work either way.
    nonisolated func mcpTruncated(to limit: Int) -> String {
        guard count > limit else { return self }
        return String(prefix(limit)) + "…"
    }
}

// MARK: - list_tabs

nonisolated struct MCPTabPayload: Encodable, Sendable {
    let tabID: String
    let title: String
    let url: String
    let selected: Bool
    let pinned: Bool
    let sleeping: Bool
    let loading: Bool

    /// `"settings"` / `"history"` / … while the tab's location is a `cherry://`
    /// page, else null.
    ///
    /// `url` for such a tab is the `cherry://` address, NOT the site the page is
    /// covering. That distinction is load-bearing: `Tab.openInternalPage` keeps
    /// the covered site's live web view, and reporting the covered URL here
    /// would tell a client to `read_page` a page the user is not looking at.
    let internalPage: String?

    private enum CodingKeys: String, CodingKey {
        case tabID = "tab_id"
        case title, url, selected, pinned, sleeping, loading
        case internalPage = "internal_page"
    }

    /// Hand-written only so `internal_page` encodes as an explicit `null`
    /// instead of vanishing — "this key is absent" and "this tab is not an
    /// internal page" are not the same statement to a model.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tabID, forKey: .tabID)
        try container.encode(title, forKey: .title)
        try container.encode(url, forKey: .url)
        try container.encode(selected, forKey: .selected)
        try container.encode(pinned, forKey: .pinned)
        try container.encode(sleeping, forKey: .sleeping)
        try container.encode(loading, forKey: .loading)
        try container.encode(internalPage, forKey: .internalPage)
    }
}

nonisolated struct MCPWindowPayload: Encodable, Sendable {
    let windowID: String
    let isActive: Bool

    /// How many tabs the window really holds — which can exceed `tabs.count`
    /// when the 300-tab cap cut this window short.
    let tabCount: Int
    let tabs: [MCPTabPayload]

    private enum CodingKeys: String, CodingKey {
        case windowID = "window_id"
        case isActive = "is_active"
        case tabCount = "tab_count"
        case tabs
    }
}

nonisolated struct MCPListTabsPayload: Encodable, Sendable {
    let windows: [MCPWindowPayload]

    /// Across every non-private window, before the cap.
    let totalTabs: Int
    let truncated: Bool
    let note: String?

    private enum CodingKeys: String, CodingKey {
        case windows
        case totalTabs = "total_tabs"
        case truncated, note
    }
}

// MARK: - read_page

/// Why a page could not be read. One value per genuinely different situation,
/// because the model's next move differs for each: wake vs. switch vs. give up.
nonisolated enum MCPUnreadableReason: String, Encodable, Sendable {
    /// No such tab in any non-private window. Also what a private tab's id
    /// returns — the existence of a private window is itself the secret, so it
    /// is indistinguishable from an id that never existed.
    case notFound = "not_found"
    case sleeping
    case internalPage = "internal_page"
    case homePage = "home_page"
    case pdf

    /// The tab exists and is a normal web page, but has never been displayed, so
    /// no `WKWebView` was ever created for it and nothing has loaded.
    case notRendered = "not_rendered"

    /// There is a live page and extraction still found nothing worth returning.
    case noContent = "no_content"
}

/// What a tool wanted the web view FOR.
///
/// The refusal ladder is one ladder — `MCPBrowserBridge.readableWebView(for:_:)`
/// — because two would drift, and the `cherry://` trap this codebase has already
/// been bitten by twice is exactly what drift reintroduces. But three of its
/// rungs end in a sentence about what did not happen, and "nothing was read" is
/// the wrong sentence for a tool that lists controls. So the CONDITIONS and
/// their ORDER live in one place and only the closing clause varies, chosen from
/// here rather than written twice.
nonisolated enum MCPWebViewPurpose: Sendable {
    case readingText
    case listingElements

    /// Why an internal page has nothing to offer this caller.
    var internalPageClause: String {
        switch self {
        case .readingText: "which has no readable page text. Nothing was read."
        case .listingElements: "which has no web page under it to list controls from. Nothing was listed."
        }
    }

    /// The same, for the new-tab page, which also says what to do instead.
    var homePageClause: String {
        switch self {
        case .readingText: "which has no article text. Use open_tab to load a page, then read it."
        case .listingElements: "which has no page controls to list. Use open_tab to load a page, then list its elements."
        }
    }

    /// The same, for WebKit's PDF viewer.
    var pdfClause: String {
        switch self {
        case .readingText:
            "Cherry's text extraction does not apply to WebKit's PDF viewer, so nothing was read."
        case .listingElements:
            "WebKit's PDF viewer is not a web page with controls Cherry can list, so nothing was listed."
        }
    }
}

/// One rung's answer: there is no live page here, and why.
///
/// Deliberately NOT a payload. The payload types below carry a tab id, a window
/// id and a URL, which the caller knows and the ladder does not; the ladder's
/// whole job is the reason and the sentence. `urlOverride` is the one exception,
/// and it exists because of the trap: on a `cherry://` tab the tab's `displayURL`
/// is the address of the page the user is NOT looking at, so that rung supplies
/// the internal page's own address and the caller must use it.
nonisolated struct MCPUnreadableRefusal: Error, Sendable {
    let reason: MCPUnreadableReason
    let detail: String
    let urlOverride: String?

    init(_ reason: MCPUnreadableReason, _ detail: String, urlOverride: String? = nil) {
        self.reason = reason
        self.detail = detail
        self.urlOverride = urlOverride
    }
}

nonisolated struct MCPUnreadablePayload: Encodable, Sendable {
    let status = "unreadable"
    let reason: MCPUnreadableReason
    let detail: String
    let tabID: String?
    let windowID: String?

    /// The tab's own location, when there is a tab. Given so a model can act —
    /// `open_tab` it, or tell the user which tab to switch to — without a second
    /// `list_tabs` round trip.
    let url: String?

    private enum CodingKeys: String, CodingKey {
        case status, reason, detail, url
        case tabID = "tab_id"
        case windowID = "window_id"
    }
}

nonisolated struct MCPReadPagePayload: Encodable, Sendable {
    let status = "ok"
    let tabID: String
    let windowID: String
    let title: String
    let url: String
    let text: String
    let offset: Int
    let returnedChars: Int
    let totalChars: Int
    let hasMore: Bool

    /// Where the next call should start. Exactly `offset + returned_chars`, so
    /// walking a page produces no overlap and no gap.
    let nextOffset: Int?

    /// True when the page was still loading. The read is attempted anyway —
    /// `PageAIExtractor` has a layout-independent last resort — and this flag
    /// says the text may be incomplete rather than wrong.
    let loading: Bool

    /// Which branch of the extractor produced `text` (`PageTextSource`).
    ///
    /// The tool's description promises what is "genuinely displayed", and that
    /// promise holds at the tab boundary — a sleeping tab, a `cherry://` page and a
    /// PDF are all refused. Below the tab boundary it does not always hold: the
    /// extractor's last-resort branches read `textContent`, which is
    /// layout-independent and so also picks up `display:none` panels, collapsed
    /// accordions and off-screen nav. Those branches fire exactly on app-shaped
    /// pages — SPAs, webmail, dashboards — where hidden DOM is most likely to hold
    /// something the user never displayed.
    ///
    /// Reporting it was chosen over constraining extraction to the visible-text
    /// paths, because those same branches are what make a mid-load or
    /// never-laid-out page readable at all, which the plan explicitly wants. So the
    /// model is told which kind of text it got and can weigh it.
    let textSource: String?

    /// The one-bit form of `text_source`: whether the element the text came from
    /// was being laid out at all. False means it was not — the text is DOM the user
    /// cannot see. Absent when the extractor reported no path.
    ///
    /// It does NOT claim that every character of a `true` result was visible: a
    /// displayed container is read via `textContent`, so its own collapsed or hidden
    /// descendants come along. That caveat is in the tool's description, where it
    /// belongs, rather than repeated in every payload.
    let sourceDisplayed: Bool?

    /// True when the extracted page was longer than `read_page` will serve and was
    /// cut. Absent otherwise, so its presence is the signal.
    let pageClamped: Bool?

    let note: String?

    private enum CodingKeys: String, CodingKey {
        case status, title, url, text, offset, loading, note
        case tabID = "tab_id"
        case windowID = "window_id"
        case returnedChars = "returned_chars"
        case totalChars = "total_chars"
        case hasMore = "has_more"
        case nextOffset = "next_offset"
        case textSource = "text_source"
        case sourceDisplayed = "source_displayed"
        case pageClamped = "page_clamped"
    }
}

nonisolated enum MCPReadPageOutcome: Encodable, Sendable {
    case page(MCPReadPagePayload)
    case unreadable(MCPUnreadablePayload)

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .page(let payload): try payload.encode(to: encoder)
        case .unreadable(let payload): try payload.encode(to: encoder)
        }
    }

    var reason: MCPUnreadableReason? {
        switch self {
        case .page: nil
        case .unreadable(let payload): payload.reason
        }
    }

    var text: String? {
        switch self {
        case .page(let payload): payload.text
        case .unreadable: nil
        }
    }
}

// MARK: - read_elements

/// One `read_elements` answer.
///
/// The projection of a `WebActionSnapshot` — which is the consumer-agnostic
/// value the action layer actually produces — into MCP's wire shape. The split
/// is the seam local agent mode attaches at: `WebActionBridge` answers in Swift
/// values, and each consumer decides how to say them.
nonisolated struct MCPReadElementsPayload: Encodable, Sendable {
    let status = "ok"
    let tabID: String
    let windowID: String
    let url: String
    let title: String

    /// Which snapshot this is, counted within `document`.
    let snapshot: Int

    /// An opaque name for the document these element numbers were minted in.
    ///
    /// Not a counter, and deliberately not one. The counters live in the page's
    /// isolated world and a navigation destroys it, so a reload — which Cherry
    /// performs on every tab when ad blocking is toggled — restarted them and
    /// made two listings of the same URL indistinguishable while their numbers
    /// meant different elements. A model should treat a change here as every
    /// number becoming invalid at once.
    let document: String

    let scope: String

    /// One pre-rendered string, newline separated, NOT an array of objects.
    ///
    /// Two reasons, and the second is the important one. A model reads
    /// `[9] searchbox "Search Amazon"` more reliably than the equivalent JSON and
    /// at roughly a third the tokens. And a closed one-line-per-element format is
    /// what makes a page unable to forge a ROW: see
    /// `WebActionScripts.sanitiseName`, which is the half of that property that
    /// can actually be tested.
    let elements: String

    let listed: Int

    /// Laid out, but not on screen, and so not listed. `scope: "page"` returns
    /// them.
    let offscreenNotListed: Int

    /// Including the main frame. v1 lists the main frame only, so anything above
    /// 1 means there are controls this list does not contain — said out loud,
    /// because the alternative is a model inferring an empty page.
    let frames: Int

    /// Elements that look like they hide a closed shadow root. Counted, not
    /// shown, because no browser can show them.
    let closedShadowHosts: Int

    /// False when the tab has no viewport at all, in which case `scope` fell back
    /// to `"page"`.
    let pageVisible: Bool

    let truncated: Bool
    let note: String?

    init(_ snapshot: WebActionSnapshot) {
        self.tabID = snapshot.tabID
        self.windowID = snapshot.windowID
        self.url = snapshot.url
        self.title = snapshot.title
        self.snapshot = snapshot.generation
        self.document = snapshot.document
        self.scope = snapshot.scope.rawValue
        self.elements = snapshot.elements.map(\.listingLine).joined(separator: "\n")
        self.listed = snapshot.elements.count
        self.offscreenNotListed = snapshot.offscreenNotListed
        self.frames = snapshot.frames
        self.closedShadowHosts = snapshot.closedShadowHosts
        self.pageVisible = snapshot.pageVisible
        self.truncated = snapshot.truncated
        self.note = snapshot.note
    }

    private enum CodingKeys: String, CodingKey {
        case status, url, title, snapshot, document, scope, elements, listed, frames, truncated, note
        case tabID = "tab_id"
        case windowID = "window_id"
        case offscreenNotListed = "offscreen_not_listed"
        case closedShadowHosts = "closed_shadow_hosts"
        case pageVisible = "page_visible"
    }

    /// Hand-written only so `note` encodes as an explicit `null` rather than
    /// vanishing — "nothing was cut" and "this key is absent" are not the same
    /// statement to a model.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try container.encode(tabID, forKey: .tabID)
        try container.encode(windowID, forKey: .windowID)
        try container.encode(url, forKey: .url)
        try container.encode(title, forKey: .title)
        try container.encode(snapshot, forKey: .snapshot)
        try container.encode(document, forKey: .document)
        try container.encode(scope, forKey: .scope)
        try container.encode(elements, forKey: .elements)
        try container.encode(listed, forKey: .listed)
        try container.encode(offscreenNotListed, forKey: .offscreenNotListed)
        try container.encode(frames, forKey: .frames)
        try container.encode(closedShadowHosts, forKey: .closedShadowHosts)
        try container.encode(pageVisible, forKey: .pageVisible)
        try container.encode(truncated, forKey: .truncated)
        try container.encode(note, forKey: .note)
    }
}

/// The encodable face of `WebActionSnapshotOutcome`.
///
/// `.failed` is deliberately absent: a failure is not a payload. It leaves
/// through `MCPPayloadEncoding.failure` with `isError: true`, which is the
/// distinction `MCPToolInvoker`'s header describes and the reason a refusal here
/// and a breakage here do not look alike to a model.
nonisolated enum MCPReadElementsOutcome: Encodable, Sendable {
    case elements(MCPReadElementsPayload)
    case unreadable(MCPUnreadablePayload)

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .elements(let payload): try payload.encode(to: encoder)
        case .unreadable(let payload): try payload.encode(to: encoder)
        }
    }

    var reason: MCPUnreadableReason? {
        switch self {
        case .elements: nil
        case .unreadable(let payload): payload.reason
        }
    }
}

// MARK: - click_element / type_text / request_action_session

/// One acted-on element, as a client reads it.
///
/// The projection of `WebActionActed`, which is the consumer-agnostic value the
/// action layer produces. Same split as `read_elements`, same reason: the bridge
/// answers in Swift values and each consumer decides how to say them.
nonisolated struct MCPActionResultPayload: Encodable, Sendable {
    let status = "acted"
    let action: String
    let outcome: String
    let tabID: String
    let windowID: String

    /// True when every element number the caller holds is now meaningless. Said
    /// out loud rather than left to be inferred from `outcome`, because "the page
    /// navigated" and "your numbers are void" are the same fact and a model that
    /// reads only one of them keeps using the numbers.
    let snapshotInvalidated: Bool

    /// The document these numbers belonged to. After a navigation this names the
    /// page load that has GONE, which is why the flag above sits beside it.
    let document: String

    let element: Int
    let role: String
    let name: String

    let urlBefore: String
    let urlAfter: String
    let mutations: Int
    let waitedMS: Int
    let obscuredBy: String?

    let valueAfter: String?
    let valueTruncated: Bool?
    let frameworkObserved: Bool?
    let submitted: Bool?

    let note: String?

    init(_ acted: WebActionActed) {
        self.action = acted.action
        self.outcome = acted.outcome.rawValue
        self.tabID = acted.tabID
        self.windowID = acted.windowID
        self.snapshotInvalidated = acted.snapshotInvalidated
        self.document = acted.document
        self.element = acted.element
        self.role = acted.role
        self.name = acted.name
        self.urlBefore = acted.urlBefore
        self.urlAfter = acted.urlAfter
        self.mutations = acted.mutations
        self.waitedMS = acted.waitedMS
        self.obscuredBy = acted.obscuredBy
        self.valueAfter = acted.valueAfter
        self.valueTruncated = acted.valueTruncated
        self.frameworkObserved = acted.frameworkObserved
        self.submitted = acted.submitted
        self.note = acted.note
    }

    private enum CodingKeys: String, CodingKey {
        case status, action, outcome, document, element, role, name, mutations, submitted, note
        case tabID = "tab_id"
        case windowID = "window_id"
        case snapshotInvalidated = "snapshot_invalidated"
        case urlBefore = "url_before"
        case urlAfter = "url_after"
        case waitedMS = "waited_ms"
        case obscuredBy = "obscured_by"
        case valueAfter = "value_after"
        case valueTruncated = "value_truncated"
        case frameworkObserved = "framework_observed"
    }

    /// Hand-written so `obscured_by` and `note` encode as explicit nulls. "The
    /// element was not covered" and "this key is absent" are not the same
    /// statement to a model.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try container.encode(action, forKey: .action)
        try container.encode(outcome, forKey: .outcome)
        try container.encode(tabID, forKey: .tabID)
        try container.encode(windowID, forKey: .windowID)
        try container.encode(snapshotInvalidated, forKey: .snapshotInvalidated)
        try container.encode(document, forKey: .document)
        try container.encode(element, forKey: .element)
        try container.encode(role, forKey: .role)
        try container.encode(name, forKey: .name)
        try container.encode(urlBefore, forKey: .urlBefore)
        try container.encode(urlAfter, forKey: .urlAfter)
        try container.encode(mutations, forKey: .mutations)
        try container.encode(waitedMS, forKey: .waitedMS)
        try container.encode(obscuredBy, forKey: .obscuredBy)
        try container.encodeIfPresent(valueAfter, forKey: .valueAfter)
        try container.encodeIfPresent(valueTruncated, forKey: .valueTruncated)
        try container.encodeIfPresent(frameworkObserved, forKey: .frameworkObserved)
        try container.encodeIfPresent(submitted, forKey: .submitted)
        try container.encode(note, forKey: .note)
    }
}

/// One refusal. `isError: false` on the way out — the call was well-formed and
/// the answer is "no", so a model should pick a different move rather than retry.
nonisolated struct MCPActionRefusalPayload: Encodable, Sendable {
    let status = "refused"
    let reason: WebActionRefusalReason
    let detail: String
    let element: Int?
    let name: String?

    /// The document the tab is ACTUALLY on, when the caller's was stale. Given so
    /// a model can tell "I am one listing behind" from "I invented a number"
    /// without a second round trip.
    let document: String?

    init(_ refusal: WebActionRefusal) {
        self.reason = refusal.reason
        self.detail = refusal.detail
        self.element = refusal.element
        self.name = refusal.name
        self.document = refusal.document
    }

    private enum CodingKeys: String, CodingKey {
        case status, reason, detail, element, name, document
    }
}

nonisolated enum MCPActionOutcome: Encodable, Sendable {
    case acted(MCPActionResultPayload)
    case refused(MCPActionRefusalPayload)

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .acted(let payload): try payload.encode(to: encoder)
        case .refused(let payload): try payload.encode(to: encoder)
        }
    }
}

nonisolated struct MCPActionSessionPayload: Encodable, Sendable {
    let status = "granted"
    let sessionID: String
    let tabID: String
    let windowID: String
    let origin: String
    let purpose: String
    let expiresAt: Date
    let grantedMinutes: Int
    let note: String

    init(_ grant: WebActionSessionGrant) {
        self.sessionID = grant.sessionID
        self.tabID = grant.tabID
        self.windowID = grant.windowID
        self.origin = grant.origin
        self.purpose = grant.purpose
        self.expiresAt = grant.expiresAt
        self.grantedMinutes = grant.grantedMinutes
        self.note = grant.note
    }

    private enum CodingKeys: String, CodingKey {
        case status, origin, purpose, note
        case sessionID = "session_id"
        case tabID = "tab_id"
        case windowID = "window_id"
        case expiresAt = "expires_at"
        case grantedMinutes = "granted_minutes"
    }
}

nonisolated enum MCPActionSessionOutcome: Encodable, Sendable {
    case granted(MCPActionSessionPayload)
    case refused(MCPActionRefusalPayload)

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .granted(let payload): try payload.encode(to: encoder)
        case .refused(let payload): try payload.encode(to: encoder)
        }
    }
}

// MARK: - search_history

nonisolated struct MCPHistoryEntryPayload: Encodable, Sendable {
    let title: String
    let url: String
    let visitedAt: Date
    let visitCount: Int

    private enum CodingKeys: String, CodingKey {
        case title, url
        case visitedAt = "visited_at"
        case visitCount = "visit_count"
    }
}

nonisolated struct MCPSearchHistoryPayload: Encodable, Sendable {
    let query: String
    let results: [MCPHistoryEntryPayload]
    let returned: Int
    let totalMatches: Int
    let truncated: Bool
    let note: String?

    private enum CodingKeys: String, CodingKey {
        case query, results, returned, truncated, note
        case totalMatches = "total_matches"
    }
}

// MARK: - search_bookmarks

nonisolated struct MCPBookmarkEntryPayload: Encodable, Sendable {
    let title: String
    let url: String
    let folder: String?
    let inBookmarkBar: Bool
    let createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case title, url, folder
        case inBookmarkBar = "in_bookmark_bar"
        case createdAt = "created_at"
    }
}

nonisolated struct MCPSearchBookmarksPayload: Encodable, Sendable {
    let query: String
    let results: [MCPBookmarkEntryPayload]
    let returned: Int
    let totalMatches: Int
    let truncated: Bool
    let note: String?

    private enum CodingKeys: String, CodingKey {
        case query, results, returned, truncated, note
        case totalMatches = "total_matches"
    }
}

// MARK: - open_tab

nonisolated struct MCPOpenTabPayload: Encodable, Sendable {
    let status = "ok"
    let tabID: String
    let windowID: String
    let url: String
    let activated: Bool

    private enum CodingKeys: String, CodingKey {
        case status, url, activated
        case tabID = "tab_id"
        case windowID = "window_id"
    }
}

/// Why a tab was not opened. Every one of these is a deliberate "no", not a
/// failure — hence `isError: false` on the way out.
nonisolated enum MCPOpenTabRefusalReason: String, Encodable, Sendable {
    /// Not a URL Cherry can act on at all.
    case invalidURL = "invalid_url"

    /// A scheme `open_tab` will not open. `file:`, `data:` and `javascript:`
    /// are obvious; `cherry:` matters just as much, because
    /// `BrowserViewModel.navigate(to:in:)` routes it to Cherry's own internal
    /// pages, which would let a client drive the browser's UI.
    case unsupportedScheme = "unsupported_scheme"

    /// More than five tabs in a minute. This is the one tool that can spam the
    /// user's screen.
    case rateLimited = "rate_limited"

    /// Cherry has no non-private window to open a tab in.
    case noWindow = "no_window"
}

nonisolated struct MCPOpenTabRefusalPayload: Encodable, Sendable {
    let status = "refused"
    let reason: MCPOpenTabRefusalReason
    let detail: String

    /// The offending scheme, named so the model does not have to parse `detail`.
    let scheme: String?

    /// Seconds until the rate limiter will allow another tab.
    let retryAfterSeconds: Int?

    private enum CodingKeys: String, CodingKey {
        case status, reason, detail, scheme
        case retryAfterSeconds = "retry_after_seconds"
    }
}

nonisolated enum MCPOpenTabOutcome: Encodable, Sendable {
    case opened(MCPOpenTabPayload)
    case refused(MCPOpenTabRefusalPayload)

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .opened(let payload): try payload.encode(to: encoder)
        case .refused(let payload): try payload.encode(to: encoder)
        }
    }

    var refusalReason: MCPOpenTabRefusalReason? {
        switch self {
        case .opened: nil
        case .refused(let payload): payload.reason
        }
    }
}
