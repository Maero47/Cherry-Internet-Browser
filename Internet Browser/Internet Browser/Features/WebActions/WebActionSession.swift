//
//  WebActionSession.swift
//  Cherry Browser
//
//  What one grant of "you may click and type in this tab" IS.
//
//  A value, not an object, and deliberately so: it is read on the main actor by
//  the store, copied into an audit record, and rendered by two views. Nothing
//  about it may be mutated behind the store's back, and nothing that holds one
//  can decide on its own that it is still valid — `WebActionSessionStore` is the
//  only type allowed to answer that question, and `WebActionBridge` is the only
//  caller allowed to ask it.
//
//  ## One tab, one requester, one origin, one clock
//
//  Every field below narrows what the grant covers, and each narrowing is
//  enforced at the point an action executes rather than at the point it was
//  granted:
//
//  * `tabID` — the session is for ONE tab. A tab id is not transferable.
//  * `requester` — a grant to an MCP client is not a grant to Cherry's own local
//    agent, and vice versa. The local agent carries no bearer token and would
//    otherwise inherit a client's permission for free.
//  * `origin` — the page's `scheme://host[:port]` at grant time. A cross-origin
//    navigation is a different site with the same tab id, and a grant given for
//    one is not a grant for the other.
//  * `expiresAt` — checked when an action runs, never on a timer. A timer that
//    fires late leaves a window in which an expired session still works.
//
//  ## Never persisted
//
//  There is no `Codable` conformance and no store on disk. A restart is a
//  revocation. That is the one place in Cherry where losing state is the correct
//  behaviour: a permission the user granted to a program yesterday, silently
//  still live today, is a permission they did not grant.
//

import Foundation

// MARK: - Who is asking

/// Which consumer of the action layer wants to act.
///
/// Two cases and no associated client name, which is a security decision rather
/// than an omission. An MCP client announces its own name in `initialize`, and
/// Cherry cannot verify one word of it — a hostile client would announce
/// "Claude Code". A self-declared name rendered inside a permission prompt is a
/// spoofing surface, so the consent sheet says what Cherry actually knows:
/// something holding the browser's connection token is asking.
nonisolated enum WebActionRequester: String, Sendable, Equatable, Hashable, CaseIterable {

    /// Something on the far end of the MCP socket, holding Cherry's bearer token.
    case mcp

    /// Cherry's own in-app assistant. Carries no token, runs in-process, and is
    /// therefore a different principal — a grant to one is never a grant to the
    /// other.
    case localAgent = "local_agent"

    /// How the consent sheet and the session bar name this requester.
    var displayName: String {
        switch self {
        case .mcp: "A connected app"
        case .localAgent: "Cherry's assistant"
        }
    }

    /// The longer form, for the one line of the sheet that has room to be exact.
    var identityDetail: String {
        switch self {
        case .mcp:
            "a program outside Cherry, connected with this browser's MCP token. "
                + "Cherry cannot verify what it calls itself, so it does not show you a name it "
                + "was told."
        case .localAgent:
            "Cherry's own assistant, running inside this browser."
        }
    }
}

// MARK: - The grant

nonisolated struct WebActionSession: Sendable, Equatable, Identifiable {

    let id: UUID

    /// The one tab this grant covers.
    let tabID: UUID

    /// The window that tab was in when the user granted it — used to put the
    /// session bar in the right place, never to widen what is permitted.
    let windowID: UUID

    /// `scheme://host[:port]` at grant time, as `WebActionOrigin.of(_:)` derives
    /// it. A cross-origin navigation ends the session.
    let origin: String

    /// The requester's own words, shown to the user verbatim and recorded in
    /// every audit entry. Sanitised on the way in — it is model-authored text
    /// rendered in a security prompt.
    let purpose: String

    let requester: WebActionRequester

    let grantedAt: Date
    let expiresAt: Date

    /// Set the instant the session stops being usable, by any route. Never
    /// cleared: an ended session is finished, not paused.
    var endedAt: Date?

    /// Why it ended, for the audit log and for the sentence a later call is
    /// given. `nil` while it is live.
    var endReason: WebActionSessionEnd?

    /// Whole minutes granted, as the user was shown them.
    var grantedMinutes: Int {
        max(1, Int((expiresAt.timeIntervalSince(grantedAt) / 60).rounded()))
    }

    /// Live at `moment` — the only definition, and the store is the only caller.
    func isLive(at moment: Date) -> Bool {
        endedAt == nil && moment < expiresAt
    }

    /// Whole seconds left, floored at zero. For the session bar's countdown.
    func secondsRemaining(at moment: Date) -> Int {
        max(0, Int(expiresAt.timeIntervalSince(moment).rounded(.down)))
    }
}

// MARK: - How a session ends

/// Every way a grant stops being usable. One case per genuinely different
/// sentence, because what a model should do next differs for each.
nonisolated enum WebActionSessionEnd: String, Sendable, Equatable {

    /// The clock ran out. Detected at the point of use.
    case expired

    /// The user pressed End on the session bar.
    case revokedByUser = "revoked_by_user"

    /// The tab left the origin the grant was given for.
    case originChanged = "origin_changed"

    /// The tab is gone, asleep, showing a `cherry://` page, or otherwise no
    /// longer something that can be acted on.
    case tabUnavailable = "tab_unavailable"

    /// The MCP server was switched off, or Cherry is shutting down.
    case serverStopped = "server_stopped"

    /// What a refused call is told, phrased for a model deciding what to do next.
    var detail: String {
        switch self {
        case .expired:
            "The action session for this tab has expired. Ask for a new one with "
                + "request_action_session if the user still wants this done; do not assume they do."
        case .revokedByUser:
            "The user ended the action session for this tab. Stop acting in it. Do not ask for "
                + "another one for the same task — tell the user what you had not finished."
        case .originChanged:
            "This tab has left the site the user granted permission for, so the action session "
                + "ended. A grant is for one site, not for whatever the tab shows next."
        case .tabUnavailable:
            "The tab this action session was granted for is no longer available — it was closed, "
                + "went to sleep, or is showing one of Cherry's own pages."
        case .serverStopped:
            "Cherry's connection to outside programs was switched off, which ended every action "
                + "session."
        }
    }
}

// MARK: - Model-authored text in a security prompt

/// The one-line, bounded form of a string a requester wrote.
///
/// `purpose` is the only thing the user has to judge a grant by, and it is
/// written by whoever is asking. So it gets the same treatment a control's name
/// gets before it reaches a model, for the same reason and in the other
/// direction: a `purpose` carrying newlines can lay out fake UI inside the
/// sheet — a second heading, a line that reads like Cherry's own copy, a bogus
/// "already approved by the user" note under the real text.
///
/// Deliberately NOT `WebActionScripts.sanitiseName`. That function defends a
/// LISTING, so it also neutralises `[` and `]` because a row is named by its
/// bracketed id; here there are no rows, brackets are ordinary punctuation in a
/// sentence, and mangling them would make a legitimate purpose read as damaged.
/// What both share is the rule that matters: one line, always.
nonisolated enum WebActionText {

    /// The longest purpose Cherry will show, matching the tool's schema.
    static let purposeChars = 200

    /// The shortest that can mean anything. "Do stuff" is not a purpose, and the
    /// schema's `minLength` is a hint a client may ignore, so it is enforced.
    static let purposeMinimumChars = 10

    static func sanitisePurpose(_ raw: String) -> String {
        singleLine(raw, limit: purposeChars)
    }

    /// One line, collapsed runs of blank, bounded, with a visible cut marker.
    static func singleLine(_ raw: String, limit: Int) -> String {
        var scalars = String.UnicodeScalarView()
        var lastWasSpace = true // leading blank is dropped
        for scalar in raw.unicodeScalars {
            let isBlank: Bool
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .spaceSeparator:
                isBlank = true
            default:
                isBlank = scalar.properties.isWhitespace
            }
            if isBlank {
                if !lastWasSpace { scalars.append(" ") }
                lastWasSpace = true
            } else {
                scalars.append(scalar)
                lastWasSpace = false
            }
        }
        var text = String(scalars)
        while text.hasSuffix(" ") { text.removeLast() }
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }
}

// MARK: - Origin

/// `scheme://host[:port]`, derived once so the grant, the enforcement check and
/// the audit record cannot disagree about what "the same site" means.
nonisolated enum WebActionOrigin {

    /// Nil for anything with no host to speak of — `about:blank`, a `data:` URL,
    /// a file. A session cannot be granted for one, which means the enforcement
    /// check never has to decide what "same origin" means for something that has
    /// none.
    static func of(_ url: URL?) -> String? {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              !host.isEmpty
        else {
            return nil
        }
        if let port = url.port, port != defaultPort(for: scheme) {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }

    private static func defaultPort(for scheme: String) -> Int? {
        switch scheme {
        case "http": 80
        case "https": 443
        default: nil
        }
    }
}
