//
//  WebActionSessionStore.swift
//  Cherry Browser
//
//  THE authority on whether an action is allowed. No other type may decide.
//
//  ## Why this is a store and not a check
//
//  A permission that lives in a tool description is not a permission — a
//  description is a hint to a model, and a model can be talked out of a hint by
//  the page it is reading. So the grant is a value in one main-actor-isolated
//  store, `liveSession(forTab:requester:)` is the only way to read it, and
//  `WebActionBridge.perform` calls it as its first statement, before a tab is
//  resolved, before a web view is touched, before one character of JavaScript is
//  evaluated.
//
//  ## Expiry, revocation and every other ending are checked AT THE POINT OF USE
//
//  There is no timer that ends sessions. A timer that fires late leaves a window
//  in which an expired grant still works, and a timer that fires on a background
//  queue leaves a race with the action it was supposed to stop. Instead every
//  ending is a question asked at the instant an action runs:
//
//  | Ending | Where it is detected |
//  | --- | --- |
//  | Expiry | `isLive(at:)`, here, on every read |
//  | Revocation | `endedAt`, set by the session bar's End button |
//  | Cross-origin navigation | `WebActionBridge`, against the LIVE document |
//  | Tab closed / asleep / `cherry://` | the shared refusal ladder, in the bridge |
//  | Server switched off, app quitting | `endAll(_:)` |
//
//  The countdown the session bar draws is cosmetic and is driven by the view's
//  own timer. Nothing about enforcement depends on it running.
//
//  ## The consent prompt lives here, not in the caller
//
//  `requestSession` presents the sheet and awaits the answer, so MCP and the
//  local agent get the same prompt from the same code and neither can write its
//  own. It is bounded to `consentTimeout` — under Claude Code's 60-second
//  first-byte timer — because a prompt that outlives the request that raised it
//  would be a dialog the user answers into nothing.
//
//  ## Never persisted
//
//  No file, no `UserDefaults`, no `Codable`. A restart is a revocation.
//

import Foundation
import Observation

// MARK: - Consent

/// A prompt waiting on the user. One per pending `request_action_session`.
///
/// `Identifiable` so SwiftUI can present it; `Equatable` so a re-render does not
/// re-present it.
nonisolated struct WebActionConsentRequest: Sendable, Identifiable, Equatable {
    let id: UUID
    let tabID: UUID
    let windowID: UUID

    /// What the user is being asked about, in their terms.
    let tabTitle: String
    let origin: String

    /// The requester's own words, already through `WebActionText.sanitisePurpose`.
    let purpose: String

    let requester: WebActionRequester
    let minutes: Int
}

/// What the user, or the clock, said.
nonisolated enum WebActionConsentDecision: Sendable, Equatable {
    case granted(WebActionSession)
    case declined

    /// Nobody answered inside `consentTimeout`. Distinct from `declined`: the
    /// user did not say no, they said nothing, and a model should tell them so
    /// rather than reporting a refusal they never made.
    case noAnswer

    /// Asked again too soon after a decline. See `declineCooldown`.
    case declinedEarlier

    /// Something is already being asked about this tab. Two sheets on one tab is
    /// how a user ends up clicking Allow on the second one without reading it.
    case alreadyAsking
}

// MARK: - Store

@MainActor
@Observable
final class WebActionSessionStore {

    static let shared = WebActionSessionStore()

    /// How long a consent sheet waits for an answer.
    ///
    /// Claude Code's per-request first-byte timer is 60 seconds, so a prompt that
    /// could block longer would be answered into a request that has already
    /// given up. 55 leaves room for the answer to travel back.
    static let consentTimeout: TimeInterval = 55

    /// How long a decline is remembered.
    ///
    /// The tool's description says "do not ask again"; this is the half of that
    /// which is a control rather than a hint. A model that rephrases its purpose
    /// and immediately retries gets the same answer without the user seeing a
    /// second sheet, because the second sheet is exactly how a user is trained to
    /// press Allow.
    static let declineCooldown: TimeInterval = 120

    /// The most simultaneous grants Cherry will hold, and it is enforced in
    /// `allow(_:)` rather than merely written down.
    ///
    /// It used to be neither: the constant only bounded the ended tail, so the
    /// comment described a limit that did not exist. Granting the ninth now ends
    /// the oldest live one, because eight session bars is already more than a
    /// person can hold in their head, and a permission the user has lost track of
    /// is a permission they did not really give.
    static let maximumLiveSessions = 8

    /// How long after a session ends its tab still counts as "recently agentic".
    ///
    /// For the gates that must not be defeated by deferral — a `setTimeout`ed
    /// `window.open` scheduled during a session and delivered a second after it
    /// expires is the same popup, and keying the block on liveness alone let it
    /// through. Enforcement of ACTIONS uses `liveSession` and never this.
    static let recentGrace: TimeInterval = 10

    // MARK: State

    /// Live and recently-ended grants, keyed by session id. Ended ones are kept
    /// briefly so a call arriving just after an ending is told WHY rather than
    /// being told there was never a session.
    private(set) var sessions: [WebActionSession] = []

    /// Prompts currently on screen, in the order they were raised.
    private(set) var pending: [WebActionConsentRequest] = []

    private var continuations: [UUID: CheckedContinuation<WebActionConsentDecision, Never>] = [:]

    /// (tab, requester) → when the user last said no.
    private var declines: [DeclineKey: Date] = [:]

    private struct DeclineKey: Hashable {
        let tabID: UUID
        let requester: WebActionRequester
    }

    /// Injected exactly as `MCPRateLimiter` injects it, so expiry is testable
    /// without sleeping through ten real minutes.
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    // MARK: - The one accessor

    /// The live grant for `tabID` held by `requester`, or nil.
    ///
    /// **This is the enforcement point's other half.** Nil for absent, expired,
    /// ended, wrong tab and wrong requester alike, because the caller's next move
    /// is the same for all of them: do not act. `endedSession(forTab:requester:)`
    /// is what supplies the sentence explaining which it was.
    ///
    /// ## Why this scans instead of taking the first match
    ///
    /// It used to be `sessions.firstIndex(where:)`, and that was a real defect
    /// rather than a style point. `allow(_:)` ENDS prior grants for a tab and
    /// APPENDS the new one, and `pruneEndedSessions` leaves up to sixteen entries
    /// standing — so after a perfectly ordinary sequence (grant, let it expire or
    /// press End, ask again, user allows) the array holds `[S1(ended),
    /// S2(live)]`. `firstIndex` found S1, saw it was not live, and returned nil.
    ///
    /// The store then gave three different answers to the same question: a click
    /// naming the tab was refused `session_expired` for a grant made seconds
    /// earlier, `liveSessions` / `hasLiveSession` / the session bar all reported
    /// the session as live, and a click that omitted `tab_id` resolved S2 and
    /// acted. A type whose header calls it THE authority cannot disagree with its
    /// own siblings, and the user cannot be shown a live session bar over a
    /// feature that refuses everything.
    ///
    /// So: visit every match, record any lapse into `endReason` on the way past,
    /// and answer with the live one. There is at most one — `allow(_:)` ends the
    /// rest before appending — and taking the last is what makes that true even
    /// if that invariant is ever weakened.
    func liveSession(forTab tabID: UUID, requester: WebActionRequester) -> WebActionSession? {
        let moment = now()
        var live: WebActionSession?
        for index in sessions.indices
        where sessions[index].tabID == tabID && sessions[index].requester == requester {
            // Expiry is recorded the first time it is noticed, so the audit log
            // and the next refusal both say "expired" rather than "no session".
            if sessions[index].endedAt == nil, moment >= sessions[index].expiresAt {
                sessions[index].endedAt = sessions[index].expiresAt
                sessions[index].endReason = .expired
            }
            if sessions[index].isLive(at: moment) { live = sessions[index] }
        }
        return live
    }

    /// Every live grant `requester` holds. Used only to resolve an action that
    /// named no tab — never to widen one grant into another.
    func liveSessions(for requester: WebActionRequester) -> [WebActionSession] {
        let moment = now()
        return sessions.filter { $0.requester == requester && $0.isLive(at: moment) }
    }

    /// The most recently ended grant for this tab and requester, if there is one.
    ///
    /// Only ever used to explain a refusal. It can never make one succeed:
    /// `isLive` is false for everything this returns, by construction.
    func endedSession(forTab tabID: UUID, requester: WebActionRequester) -> WebActionSession? {
        let moment = now()
        _ = liveSession(forTab: tabID, requester: requester) // records a lapse into `endReason`
        return sessions
            .filter { $0.tabID == tabID && $0.requester == requester && !$0.isLive(at: moment) }
            .max { ($0.endedAt ?? .distantPast) < ($1.endedAt ?? .distantPast) }
    }

    /// Whether any live grant covers `tabID`, whoever holds it.
    ///
    /// For the parts of the browser that must behave differently while an agent
    /// is acting — the session bar, the popup gate, the file-panel gate — and for
    /// nothing that decides whether an action is permitted.
    func hasLiveSession(forTab tabID: UUID) -> Bool {
        let moment = now()
        return sessions.contains { $0.tabID == tabID && $0.isLive(at: moment) }
    }

    /// Live, or ended within `recentGrace`.
    ///
    /// The gates that fire on DELIVERY rather than on the action use this. A
    /// `window.open` or a file panel scheduled by a `setTimeout` during a session
    /// arrives after it, and a gate keyed on liveness alone waves through exactly
    /// the thing it exists to stop. Never used to permit an action.
    func hasRecentSession(forTab tabID: UUID) -> Bool {
        let moment = now()
        return sessions.contains { session in
            guard session.tabID == tabID else { return false }
            if session.isLive(at: moment) { return true }
            guard let endedAt = session.endedAt else { return false }
            return moment.timeIntervalSince(endedAt) < Self.recentGrace
        }
    }

    /// Every live grant, front to back. Drives the session bar.
    var liveSessions: [WebActionSession] {
        let moment = now()
        return sessions.filter { $0.isLive(at: moment) }
    }

    // MARK: - Ending

    /// The user pressed End.
    func revoke(sessionID: UUID) {
        end(sessionID: sessionID, reason: .revokedByUser)
    }

    /// End one grant. Idempotent: an already-ended session keeps its first
    /// reason, because the first thing that ended it is the true one.
    func end(sessionID: UUID, reason: WebActionSessionEnd) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
              sessions[index].endedAt == nil
        else {
            return
        }
        sessions[index].endedAt = now()
        sessions[index].endReason = reason
    }

    /// End every grant for one tab — its origin changed, it closed, it slept.
    func endSessions(forTab tabID: UUID, reason: WebActionSessionEnd) {
        for session in sessions where session.tabID == tabID && session.endedAt == nil {
            end(sessionID: session.id, reason: reason)
        }
    }

    /// End everything. The MCP server was switched off, or Cherry is quitting.
    func endAll(reason: WebActionSessionEnd) {
        for session in sessions where session.endedAt == nil {
            end(sessionID: session.id, reason: reason)
        }
        // Anyone still waiting on a prompt is told no. A pending grant that
        // outlived the server would be a grant nobody could revoke.
        for request in pending { answer(request.id, with: .declined) }
    }

    // MARK: - Asking

    /// Present the consent sheet and wait for an answer.
    ///
    /// Returns `.granted` with the session already recorded, so there is no
    /// window between "the user said yes" and "the store knows".
    func requestSession(
        tabID: UUID,
        windowID: UUID,
        tabTitle: String,
        origin: String,
        purpose: String,
        minutes: Int,
        requester: WebActionRequester
    ) async -> WebActionConsentDecision {
        let moment = now()

        if let declinedAt = declines[DeclineKey(tabID: tabID, requester: requester)],
           moment.timeIntervalSince(declinedAt) < Self.declineCooldown {
            return .declinedEarlier
        }
        guard !pending.contains(where: { $0.tabID == tabID }) else {
            return .alreadyAsking
        }

        // An existing live grant for the same tab and requester is extended in
        // place rather than stacked. Two grants for one tab would mean two
        // session bars and two End buttons, one of which would not work.
        if let existing = liveSession(forTab: tabID, requester: requester), existing.origin == origin {
            return .granted(existing)
        }

        let request = WebActionConsentRequest(
            id: UUID(),
            tabID: tabID,
            windowID: windowID,
            tabTitle: WebActionText.singleLine(tabTitle, limit: 120),
            origin: origin,
            purpose: WebActionText.sanitisePurpose(purpose),
            requester: requester,
            minutes: minutes
        )
        pending.append(request)

        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.consentTimeout))
            guard !Task.isCancelled else { return }
            self?.answer(request.id, with: .noAnswer)
        }
        defer { timeout.cancel() }

        return await withCheckedContinuation { continuation in
            continuations[request.id] = continuation
        }
    }

    /// The sheet's Allow button.
    func allow(_ requestID: UUID) {
        guard let request = pending.first(where: { $0.id == requestID }) else { return }
        let moment = now()
        let session = WebActionSession(
            id: UUID(),
            tabID: request.tabID,
            windowID: request.windowID,
            origin: request.origin,
            purpose: request.purpose,
            requester: request.requester,
            grantedAt: moment,
            expiresAt: moment.addingTimeInterval(TimeInterval(request.minutes) * 60),
            endedAt: nil,
            endReason: nil
        )
        // One grant per tab and requester, always: the extend-in-place path above
        // handles the same-origin case, so anything still here is superseded.
        endSessions(forTab: request.tabID, reason: .tabUnavailable)

        // And no more than `maximumLiveSessions` at once. The oldest goes,
        // because a permission the user has lost track of is one they did not
        // really give — and because eight bars is already more than a window can
        // show without becoming wallpaper.
        var live = sessions.filter { $0.isLive(at: moment) }
        while live.count >= Self.maximumLiveSessions {
            guard let oldest = live.min(by: { $0.grantedAt < $1.grantedAt }) else { break }
            end(sessionID: oldest.id, reason: .revokedByUser)
            live.removeAll { $0.id == oldest.id }
        }

        sessions.append(session)
        pruneEndedSessions()
        answer(requestID, with: .granted(session))
    }

    /// The sheet's "Not now" button.
    func decline(_ requestID: UUID) {
        guard let request = pending.first(where: { $0.id == requestID }) else { return }
        declines[DeclineKey(tabID: request.tabID, requester: request.requester)] = now()
        answer(requestID, with: .declined)
    }

    /// The prompt a window should present, if any.
    ///
    /// Selected by the TAB, not by the window the request named. A window's id is
    /// frozen at the moment the request was raised, and a tab can be dragged into
    /// another window inside the fifty-five seconds the prompt waits — after
    /// which the sheet would be asking window A about a tab window B is showing.
    /// Exactly one window holds a given tab, so exactly one presents.
    func pendingRequest(forTabIn tabIDs: Set<UUID>) -> WebActionConsentRequest? {
        pending.first { tabIDs.contains($0.tabID) }
    }

    // MARK: - Internals

    private func answer(_ requestID: UUID, with decision: WebActionConsentDecision) {
        pending.removeAll { $0.id == requestID }
        guard let continuation = continuations.removeValue(forKey: requestID) else { return }
        continuation.resume(returning: decision)
    }

    /// Keep the ended tail bounded. Ended sessions exist only to explain a
    /// refusal, so a handful is plenty and an unbounded list is a leak.
    private func pruneEndedSessions() {
        let moment = now()
        guard sessions.count > Self.maximumLiveSessions * 2 else { return }
        let live = sessions.filter { $0.isLive(at: moment) }
        let ended = sessions
            .filter { !$0.isLive(at: moment) }
            .sorted { ($0.endedAt ?? .distantPast) > ($1.endedAt ?? .distantPast) }
            .prefix(Self.maximumLiveSessions)
        sessions = live + ended
    }
}
