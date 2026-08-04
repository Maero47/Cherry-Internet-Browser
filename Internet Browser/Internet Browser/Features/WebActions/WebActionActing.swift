//
//  WebActionActing.swift
//  Cherry Browser
//
//  What an action IS, and what it can answer, before anyone decides how to say
//  it.
//
//  These are Swift values, not JSON, for the same reason `WebActionSnapshot` is:
//  `WebActionBridge` sits BELOW MCP. MCP's job is to turn `CallTool.Parameters`
//  into one of the `WebAction` cases below; the local agent's job is to turn its
//  own tool-call format into one of the same cases. Neither owns the vocabulary,
//  and neither can quietly grow a capability the other does not have.
//

import Foundation

// MARK: - What was asked for

/// One thing to do to one element.
///
/// Every case carries `document`, and that is not incidental — it is the whole
/// reason the token exists. An element number is meaningless on its own: a
/// navigation, a reload, or an SPA route change mints a new document token and
/// every id from before it names nothing. A tool that accepted a bare number
/// would be the positional-id defect wearing a different hat, so both acting
/// cases require the caller to say which page load it was reading when it chose.
nonisolated enum WebAction: Sendable, Equatable {

    case click(element: Int, expectName: String, document: String, waitMS: Int)

    case type(
        element: Int,
        expectName: String,
        document: String,
        text: String,
        append: Bool,
        submit: Bool,
        waitMS: Int
    )

    var element: Int {
        switch self {
        case .click(let element, _, _, _): element
        case .type(let element, _, _, _, _, _, _): element
        }
    }

    var expectName: String {
        switch self {
        case .click(_, let name, _, _): name
        case .type(_, let name, _, _, _, _, _): name
        }
    }

    var document: String {
        switch self {
        case .click(_, _, let document, _): document
        case .type(_, _, let document, _, _, _, _): document
        }
    }

    var waitMS: Int {
        switch self {
        case .click(_, _, _, let wait): wait
        case .type(_, _, _, _, _, _, let wait): wait
        }
    }

    /// `"click"` / `"type"`, for the audit log.
    var kind: String {
        switch self {
        case .click: "click"
        case .type: "type"
        }
    }
}

// MARK: - Why an action did not happen

/// Every refusal the action layer can produce, as one flat vocabulary.
///
/// A refusal is `isError: false` on the way out: the call was well-formed and
/// the answer is "no". A model handed one should pick a different move, and the
/// reason is what tells it which — the next step after `name_mismatch` (re-list
/// the page) is nothing like the next step after `irreversible` (tell the user
/// and stop).
nonisolated enum WebActionRefusalReason: String, Sendable, Encodable {

    // --- The session gate. Checked before anything else, always. -------------

    /// No grant at all for this tab and this requester.
    case noSession = "no_session"

    /// There was one and its time ran out.
    case sessionExpired = "session_expired"

    /// There was one and the user ended it.
    case sessionRevoked = "session_revoked"

    /// The grant is for a different tab. Named separately from `no_session`
    /// because the fix is different: act in the tab you were given.
    case wrongTab = "wrong_tab"

    /// The tab left the origin the user granted permission for.
    case originChanged = "origin_changed"

    // --- The element. --------------------------------------------------------

    /// The `document` the caller passed is not the page load this tab is showing.
    /// Every element number the caller holds is meaningless.
    case snapshotGone = "snapshot_gone"

    /// The number was minted in this document and its element has since left the
    /// DOM.
    case elementDetached = "element_detached"

    /// The number was never issued in this document at all.
    case unknownElement = "unknown_element"

    /// The element is still there and is no longer the thing the caller agreed
    /// to. THE case the naive design lost silently.
    case nameMismatch = "name_mismatch"

    case disabled

    /// The control looks like it commits something that cannot be undone.
    case irreversible

    /// A file input. Clicking one opens a real macOS open panel over the user's
    /// browser, and Cherry does not do that on a model's say-so.
    case filePicker = "file_picker"

    /// `type_text` aimed at something with nowhere to type.
    case notATextField = "not_a_text_field"

    /// `type_text` aimed at a password field. Refused by construction — the tool
    /// says never to type a secret, and this is the half of that which is a
    /// control rather than a sentence.
    case passwordField = "password_field"

    /// `submit: true` where Cherry cannot see what Enter would do.
    ///
    /// Enter presses a form's default submit button, and that button is what the
    /// commitment rule classifies. When there is no form, or a form with no
    /// submit control, there is nothing to classify — and Enter in a
    /// contenteditable is where the modern web puts *send*: Slack, X, Discord,
    /// WhatsApp Web, Gmail's compose body. None of them is a `<form>`, so the
    /// most common irreversible action on the web was the one case the gate
    /// structurally could not see. Refusing is the only honest answer: Cherry
    /// does not press a key whose effect it cannot describe.
    case unclassifiableSubmit = "unclassifiable_submit"

    /// Too many actions in too short a window, inside one session.
    case rateLimited = "rate_limited"

    // --- There is no page here. Shared with `read_page`'s ladder. ------------

    case notFound = "not_found"
    case sleeping
    case internalPage = "internal_page"
    case homePage = "home_page"
    case notRendered = "not_rendered"
    case pdf

    /// The tab named for a session is not one a session can be granted for.
    case noSuchTab = "no_such_tab"

    /// The user was asked and said no.
    case declined

    /// The user was asked and did not answer inside the time the client allows.
    case noAnswer = "no_answer"

    /// The user already said no about this tab, recently.
    case declinedEarlier = "declined_earlier"

    /// Another request for this tab is already on screen.
    case alreadyAsking = "already_asking"

    /// A `tab_id` was omitted and the requester holds grants for more than one
    /// tab, so there is no unambiguous answer to "which tab".
    case ambiguousTab = "ambiguous_tab"
}

/// One refusal, with everything a model needs to choose its next move.
///
/// `Error` only so it can be a `Result`'s failure inside the bridge. It is never
/// thrown and never surfaces as one: a refusal leaves with `isError: false`,
/// because the call was well-formed and the answer is "no".
nonisolated struct WebActionRefusal: Error, Sendable, Equatable {
    let reason: WebActionRefusalReason

    /// Written by Cherry, never by the page and never by the requester.
    let detail: String

    /// The element the call named, when it named one.
    let element: Int?

    /// The element's name AS THE MODEL WAS SHOWN IT — sanitised. Present on the
    /// refusals where knowing which control it was changes what to say to the
    /// user, which is `irreversible` above all.
    let name: String?

    /// The document token the page is actually on, when the caller's was stale.
    /// Given so a model can tell "I am one snapshot behind" from "I invented a
    /// number", without a second round trip.
    let document: String?

    init(
        _ reason: WebActionRefusalReason,
        _ detail: String,
        element: Int? = nil,
        name: String? = nil,
        document: String? = nil
    ) {
        self.reason = reason
        self.detail = detail
        self.element = element
        self.name = name
        self.document = document
    }
}

// MARK: - What happened when it did

/// What the page did in response. Three genuinely different answers.
nonisolated enum WebActionOutcomeKind: String, Sendable, Encodable {

    /// The document went away. Every element number is invalid at once.
    case navigated

    /// The page mutated in place.
    case changed

    /// Nothing observably happened inside the wait. Usually means the wrong
    /// element, not that it should be clicked again.
    case noEffect = "no_effect"
}

/// One completed action.
nonisolated struct WebActionActed: Sendable, Equatable {

    let action: String
    let outcome: WebActionOutcomeKind

    let tabID: String
    let windowID: String

    /// The element, as the caller named it and as the page presented it at the
    /// moment of the action. `name` is sanitised.
    let element: Int
    let role: String
    let name: String

    let urlBefore: String
    let urlAfter: String

    /// The document token the action ran against. After a navigation this is the
    /// token that is now GONE, which is why `snapshot_invalidated` exists beside
    /// it rather than being inferred.
    let document: String

    /// True when every element number the caller holds is now meaningless.
    let snapshotInvalidated: Bool

    let mutations: Int
    let waitedMS: Int

    /// `"div#cookie-banner"` when the element was underneath something at the
    /// moment of the click. The click still went through — `element.click()`
    /// reaches an element buried under a full-screen overlay, where a faithful
    /// pointer sequence would have hit the overlay instead — but a user could not
    /// have made it, so it is reported rather than hidden.
    let obscuredBy: String?

    // --- typing only ---------------------------------------------------------

    /// The field's contents afterwards, sanitised and capped. Never a password
    /// field's: those are refused outright.
    let valueAfter: String?
    let valueTruncated: Bool?

    /// Whether the page's own JavaScript reacted. The difference between "the
    /// field contains the text" and "the app knows" — React drops a change event
    /// whose tracked value already matches, so a naive assignment leaves the DOM
    /// showing the text while application state stays empty.
    let frameworkObserved: Bool?

    let submitted: Bool?

    /// What Cherry wants the model to do next. Never nil after a navigation.
    let note: String?
}

// MARK: - The answer

nonisolated enum WebActionResult: Sendable {
    case acted(WebActionActed)
    case refused(WebActionRefusal)

    /// Cherry could not carry out a well-formed call. `isError: true` on the way
    /// out — a model handed an empty success invents the rest.
    case failed(String)

    var refusalReason: WebActionRefusalReason? {
        if case .refused(let refusal) = self { return refusal.reason }
        return nil
    }

    var outcome: WebActionOutcomeKind? {
        if case .acted(let acted) = self { return acted.outcome }
        return nil
    }
}

// MARK: - Asking for a session

/// What `request_action_session` answers.
nonisolated enum WebActionSessionResult: Sendable {
    case granted(WebActionSessionGrant)
    case refused(WebActionRefusal)
    case failed(String)
}

nonisolated struct WebActionSessionGrant: Sendable, Equatable {
    let sessionID: String
    let tabID: String
    let windowID: String
    let origin: String
    let purpose: String
    let expiresAt: Date
    let grantedMinutes: Int
    let note: String
}
