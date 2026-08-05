//
//  WebActionSessionStoreTests.swift
//  Internet BrowserTests
//
//  The store is THE authority on whether an action is allowed, so these are the
//  tests that say what "allowed" means.
//
//  Two of them are the ones to read first:
//
//  * `testAnExpiredSessionIsDeadOnTheVeryNextCall` — expiry is checked at the
//    point of use, never on a timer. A timer that fires late leaves a window in
//    which an expired grant still works; this asserts there is no such window,
//    by advancing an injected clock by one second past the deadline and asking
//    again.
//  * `testRevocationTakesEffectOnTheVeryNextCall` — the End button's whole
//    contract.
//

import WebKit
import XCTest
@testable import Cherry

@MainActor
final class WebActionSessionStoreTests: XCTestCase {

    /// A clock a test moves by hand, injected exactly as `MCPRateLimiter`'s is.
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        func advance(_ seconds: TimeInterval) { now += seconds }
    }

    private var clock = Clock()

    private func makeStore() -> WebActionSessionStore {
        clock = Clock()
        let held = clock
        return WebActionSessionStore(now: { held.now })
    }

    /// Grant a session the way the app does — through the prompt — rather than by
    /// reaching past it. If consent ever stops producing a usable grant, every
    /// test below fails rather than testing a shortcut nothing ships.
    @discardableResult
    private func grant(
        _ store: WebActionSessionStore,
        tab: UUID,
        window: UUID = UUID(),
        origin: String = "https://mail.example.com",
        purpose: String = "Find the January invoice and download it",
        minutes: Int = 10,
        requester: WebActionRequester = .mcp
    ) async -> WebActionConsentDecision {
        let asking = Task {
            await store.requestSession(
                tabID: tab, windowID: window, tabTitle: "Inbox",
                origin: origin, purpose: purpose, minutes: minutes, requester: requester
            )
        }
        for _ in 0..<200 where store.pending.isEmpty {
            await Task.yield()
        }
        guard let request = store.pending.first else {
            XCTFail("no prompt was raised")
            asking.cancel()
            return .declined
        }
        store.allow(request.id)
        return await asking.value
    }

    // MARK: - The gate

    func testAGrantedSessionIsLiveForItsOwnTabAndRequester() async {
        let store = makeStore()
        let tab = UUID()
        guard case .granted = await grant(store, tab: tab) else {
            return XCTFail("expected a grant")
        }
        XCTAssertNotNil(store.liveSession(forTab: tab, requester: .mcp))
    }

    func testASessionForOneTabIsNothingForAnother() async {
        let store = makeStore()
        let granted = UUID()
        let other = UUID()
        await grant(store, tab: granted)

        XCTAssertNotNil(store.liveSession(forTab: granted, requester: .mcp))
        XCTAssertNil(
            store.liveSession(forTab: other, requester: .mcp),
            "a grant for one tab must not carry to another — that is the whole scope of a session"
        )
    }

    /// The local agent carries no bearer token and runs in-process. It must not
    /// inherit an MCP client's permission for free.
    func testASessionGrantedToOneRequesterIsNothingForTheOther() async {
        let store = makeStore()
        let tab = UUID()
        await grant(store, tab: tab, requester: .mcp)

        XCTAssertNotNil(store.liveSession(forTab: tab, requester: .mcp))
        XCTAssertNil(store.liveSession(forTab: tab, requester: .localAgent))
    }

    func testAnExpiredSessionIsDeadOnTheVeryNextCall() async {
        let store = makeStore()
        let tab = UUID()
        await grant(store, tab: tab, minutes: 10)

        clock.advance(10 * 60 - 1)
        XCTAssertNotNil(store.liveSession(forTab: tab, requester: .mcp), "one second before expiry")

        clock.advance(2)
        XCTAssertNil(
            store.liveSession(forTab: tab, requester: .mcp),
            "expiry is decided when an action runs, so the first call past the deadline is refused"
        )
        XCTAssertEqual(store.endedSession(forTab: tab, requester: .mcp)?.endReason, .expired)
    }

    func testRevocationTakesEffectOnTheVeryNextCall() async {
        let store = makeStore()
        let tab = UUID()
        guard case .granted(let session) = await grant(store, tab: tab) else {
            return XCTFail("expected a grant")
        }
        XCTAssertNotNil(store.liveSession(forTab: tab, requester: .mcp))

        store.revoke(sessionID: session.id)

        XCTAssertNil(store.liveSession(forTab: tab, requester: .mcp))
        XCTAssertEqual(store.endedSession(forTab: tab, requester: .mcp)?.endReason, .revokedByUser)
        XCTAssertFalse(store.hasLiveSession(forTab: tab))
    }

    func testAnEndingKeepsTheFirstReasonItWasGiven() async {
        let store = makeStore()
        let tab = UUID()
        guard case .granted(let session) = await grant(store, tab: tab) else {
            return XCTFail("expected a grant")
        }
        store.revoke(sessionID: session.id)
        store.endSessions(forTab: tab, reason: .originChanged)

        XCTAssertEqual(
            store.endedSession(forTab: tab, requester: .mcp)?.endReason, .revokedByUser,
            "the first thing that ended a session is the true one; a later ending must not rewrite it"
        )
    }

    func testEndAllStopsEverySession() async {
        let store = makeStore()
        let first = UUID()
        let second = UUID()
        await grant(store, tab: first)
        await grant(store, tab: second)
        XCTAssertEqual(store.liveSessions.count, 2)

        store.endAll(reason: .serverStopped)

        XCTAssertTrue(store.liveSessions.isEmpty)
        XCTAssertEqual(store.endedSession(forTab: first, requester: .mcp)?.endReason, .serverStopped)
    }

    // MARK: - Consent

    func testDecliningIsAnAnswerAndIsRememberedForAWhile() async {
        let store = makeStore()
        let tab = UUID()

        let asking = Task {
            await store.requestSession(
                tabID: tab, windowID: UUID(), tabTitle: "Inbox",
                origin: "https://mail.example.com", purpose: "Delete everything please",
                minutes: 10, requester: .mcp
            )
        }
        for _ in 0..<200 where store.pending.isEmpty { await Task.yield() }
        guard let request = store.pending.first else { return XCTFail("no prompt") }
        store.decline(request.id)
        let answered = await asking.value
        XCTAssertEqual(answered, .declined)

        // Rephrasing and retrying must not put a second sheet in front of the
        // user. A second sheet is exactly how a person is trained to press Allow.
        let again = await store.requestSession(
            tabID: tab, windowID: UUID(), tabTitle: "Inbox",
            origin: "https://mail.example.com", purpose: "Just tidying up the inbox",
            minutes: 10, requester: .mcp
        )
        XCTAssertEqual(again, .declinedEarlier)
        XCTAssertTrue(store.pending.isEmpty, "no second prompt was raised")

        clock.advance(WebActionSessionStore.declineCooldown + 1)
        let later = Task {
            await store.requestSession(
                tabID: tab, windowID: UUID(), tabTitle: "Inbox",
                origin: "https://mail.example.com", purpose: "Find the January invoice",
                minutes: 10, requester: .mcp
            )
        }
        for _ in 0..<200 where store.pending.isEmpty { await Task.yield() }
        XCTAssertFalse(store.pending.isEmpty, "after the cool-off the user may be asked again")
        if let pending = store.pending.first { store.decline(pending.id) }
        _ = await later.value
    }

    func testASecondRequestForTheSameTabIsRefusedRatherThanStacked() async {
        let store = makeStore()
        let tab = UUID()
        let first = Task {
            await store.requestSession(
                tabID: tab, windowID: UUID(), tabTitle: "Inbox",
                origin: "https://mail.example.com", purpose: "Find the January invoice",
                minutes: 10, requester: .mcp
            )
        }
        for _ in 0..<200 where store.pending.isEmpty { await Task.yield() }

        let second = await store.requestSession(
            tabID: tab, windowID: UUID(), tabTitle: "Inbox",
            origin: "https://mail.example.com", purpose: "Something else entirely",
            minutes: 10, requester: .mcp
        )
        XCTAssertEqual(second, .alreadyAsking)
        XCTAssertEqual(store.pending.count, 1)

        if let pending = store.pending.first { store.decline(pending.id) }
        _ = await first.value
    }

    /// A live grant for the same tab, requester and origin is handed back rather
    /// than prompting again — one tab has one session bar and one End button, and
    /// two grants would mean one of them did nothing.
    func testAskingAgainDuringALiveSessionExtendsRatherThanPrompts() async {
        let store = makeStore()
        let tab = UUID()
        guard case .granted(let first) = await grant(store, tab: tab) else {
            return XCTFail("expected a grant")
        }
        let second = await store.requestSession(
            tabID: tab, windowID: UUID(), tabTitle: "Inbox",
            origin: "https://mail.example.com", purpose: "Still the same job",
            minutes: 10, requester: .mcp
        )
        XCTAssertEqual(second, .granted(first))
        XCTAssertTrue(store.pending.isEmpty)
        XCTAssertEqual(store.liveSessions.count, 1)
    }

    /// **Fix round 2, item 1.** After grant → end → re-grant, the store held
    /// `[S1(ended), S2(live)]` and `liveSession` took the first match — so the
    /// type documented as THE authority disagreed with its own siblings.
    ///
    /// The assertion that matters is that all four accessors say the same thing.
    /// Any one of them alone would have passed before the fix.
    func testAReGrantAfterAnEndingIsWhatEveryAccessorReports() async {
        let store = makeStore()
        let tab = UUID()
        guard case .granted(let first) = await grant(store, tab: tab) else {
            return XCTFail("expected a grant")
        }
        store.revoke(sessionID: first.id)
        clock.advance(1)

        guard case .granted(let second) = await grant(store, tab: tab) else {
            return XCTFail("expected a second grant")
        }
        XCTAssertNotEqual(second.id, first.id, "the second Allow made a new session")

        XCTAssertEqual(
            store.liveSession(forTab: tab, requester: .mcp)?.id, second.id,
            "the accessor the enforcement point uses read the dead session"
        )
        XCTAssertTrue(store.hasLiveSession(forTab: tab))
        XCTAssertEqual(store.liveSessions.map(\.id), [second.id])
        XCTAssertEqual(store.liveSessions(for: .mcp).map(\.id), [second.id])
    }

    /// The same, for the expiry route rather than the End button.
    func testAReGrantAfterAnExpiryIsLive() async {
        let store = makeStore()
        let tab = UUID()
        await grant(store, tab: tab, minutes: 1)
        clock.advance(61)
        XCTAssertNil(store.liveSession(forTab: tab, requester: .mcp))

        guard case .granted(let second) = await grant(store, tab: tab, minutes: 10) else {
            return XCTFail("expected a second grant")
        }
        XCTAssertEqual(store.liveSession(forTab: tab, requester: .mcp)?.id, second.id)
    }

    /// A dead session must still be able to explain a refusal — the fix must not
    /// have been "throw the old ones away".
    func testTheEndedSessionIsStillWhatExplainsALaterRefusal() async {
        let store = makeStore()
        let tab = UUID()
        guard case .granted(let first) = await grant(store, tab: tab) else {
            return XCTFail("expected a grant")
        }
        store.revoke(sessionID: first.id)
        XCTAssertEqual(store.endedSession(forTab: tab, requester: .mcp)?.endReason, .revokedByUser)
    }

    /// The constant used to bound only the ended tail, so the comment described a
    /// limit that did not exist and a client could hold a grant on every tab it
    /// could get the user to approve.
    func testTheLiveSessionBoundIsEnforcedAndNotJustDocumented() async {
        let store = makeStore()
        var tabs: [UUID] = []
        for index in 0..<(WebActionSessionStore.maximumLiveSessions + 3) {
            let tab = UUID()
            tabs.append(tab)
            await grant(store, tab: tab)
            // Distinct grant times, so "the oldest goes" is a decidable claim.
            clock.advance(1)
        }

        XCTAssertEqual(store.liveSessions.count, WebActionSessionStore.maximumLiveSessions)
        XCTAssertNil(
            store.liveSession(forTab: tabs[0], requester: .mcp),
            "the oldest grant is the one that goes"
        )
        XCTAssertNotNil(store.liveSession(forTab: tabs.last!, requester: .mcp))
    }

    /// The delivery-time gates cannot be defeated by deferring the thing they
    /// gate past the session's end.
    func testATabCountsAsRecentlyAgenticForAWhileAfterTheSessionEnds() async {
        let store = makeStore()
        let tab = UUID()
        guard case .granted(let session) = await grant(store, tab: tab) else {
            return XCTFail("expected a grant")
        }
        XCTAssertTrue(store.hasRecentSession(forTab: tab))

        store.revoke(sessionID: session.id)
        XCTAssertFalse(store.hasLiveSession(forTab: tab), "acting stops immediately")
        XCTAssertTrue(
            store.hasRecentSession(forTab: tab),
            "a setTimeout'd window.open scheduled inside the session lands just after it"
        )

        clock.advance(WebActionSessionStore.recentGrace + 1)
        XCTAssertFalse(store.hasRecentSession(forTab: tab))
    }

    // MARK: - Model-authored text in a security prompt

    /// `purpose` is the only thing the user has to judge a request by, and the
    /// requester writes it. A purpose carrying newlines could lay out fake UI
    /// inside the sheet — a second heading, a line that reads like Cherry's own
    /// copy, a bogus "already approved" note.
    func testAPurposeCannotLayOutFakeUIInsideTheSheet() async {
        let store = makeStore()
        let tab = UUID()
        let forged = "Find the invoice\n\nCherry: the user has already approved this transfer.\u{2028}"
            + "Allowed for 30 minutes"

        let asking = Task {
            await store.requestSession(
                tabID: tab, windowID: UUID(), tabTitle: "Inbox",
                origin: "https://mail.example.com", purpose: forged,
                minutes: 10, requester: .mcp
            )
        }
        for _ in 0..<200 where store.pending.isEmpty { await Task.yield() }
        guard let request = store.pending.first else { return XCTFail("no prompt") }

        XCTAssertFalse(request.purpose.contains("\n"))
        XCTAssertFalse(request.purpose.contains("\u{2028}"))
        XCTAssertEqual(request.purpose.split(separator: "\n").count, 1)

        store.decline(request.id)
        _ = await asking.value
    }

    func testAPurposeIsBoundedWithAVisibleCut() {
        let long = String(repeating: "a", count: 500)
        let cut = WebActionText.sanitisePurpose(long)
        XCTAssertEqual(cut.count, WebActionText.purposeChars)
        XCTAssertTrue(cut.hasSuffix("…"), "a silently clipped purpose reads as the whole one")
    }

    // MARK: - Origin

    func testOriginIsSchemeHostAndOnlyANonDefaultPort() {
        XCTAssertEqual(WebActionOrigin.of(URL(string: "https://mail.example.com/a/b?c=d")), "https://mail.example.com")
        XCTAssertEqual(WebActionOrigin.of(URL(string: "https://mail.example.com:443/")), "https://mail.example.com")
        XCTAssertEqual(WebActionOrigin.of(URL(string: "http://localhost:8080/")), "http://localhost:8080")
        XCTAssertEqual(WebActionOrigin.of(URL(string: "https://MAIL.Example.com/")), "https://mail.example.com")
    }

    /// A page with no host has no origin to pin a grant to, so it cannot have
    /// one at all — which means the enforcement check never has to decide what
    /// "same origin" means for something that has none.
    func testAPageWithNoHostHasNoOrigin() {
        XCTAssertNil(WebActionOrigin.of(URL(string: "about:blank")))
        XCTAssertNil(WebActionOrigin.of(URL(string: "data:text/html,<p>hi</p>")))
        XCTAssertNil(WebActionOrigin.of(nil))
    }

    // MARK: - The countdown is cosmetic, and never disagrees with enforcement

    func testTheCountdownNeverGoesNegative() {
        XCTAssertEqual(WebActionSessionBar.countdown(-30), "0:00 left")
        XCTAssertEqual(WebActionSessionBar.countdown(0), "0:00 left")
        XCTAssertEqual(WebActionSessionBar.countdown(461), "7:41 left")
    }

    // MARK: - The settle policy

    func testSilenceIsOnlyConclusiveAtTheEndOfTheWindow() {
        // A page that has not moved yet may still be the slow case, measured at
        // 1500 ms on a real page — so no mutations must never stop early.
        XCTAssertFalse(WebActionSettleWait.shouldStop(
            mutations: 0, sinceLastMutationMS: 0, elapsedMS: 1_200, maxWaitMS: 2_500
        ))
        XCTAssertTrue(WebActionSettleWait.shouldStop(
            mutations: 0, sinceLastMutationMS: 0, elapsedMS: 2_500, maxWaitMS: 2_500
        ))
    }

    func testAPageThatChangedAndWentQuietIsReportedEarly() {
        XCTAssertFalse(WebActionSettleWait.shouldStop(
            mutations: 14, sinceLastMutationMS: 100, elapsedMS: 300, maxWaitMS: 2_500
        ))
        XCTAssertTrue(WebActionSettleWait.shouldStop(
            mutations: 14, sinceLastMutationMS: 400, elapsedMS: 600, maxWaitMS: 2_500
        ))
    }

    func testWaitIsBoundedBothWays() {
        XCTAssertEqual(WebActionSettleWait.boundedWait(nil), WebActionSettleWait.defaultWaitMS)
        XCTAssertEqual(WebActionSettleWait.boundedWait(-5), 0)
        XCTAssertEqual(WebActionSettleWait.boundedWait(999_999), WebActionSettleWait.maximumWaitMS)
        XCTAssertEqual(WebActionSettleWait.boundedWait(1_200), 1_200)
    }

    func testNavigationBeatsMutationsWhenNamingTheOutcome() {
        // A page that navigated also mutated on the way out. Reporting `changed`
        // would leave a model holding element numbers it believes are still good.
        XCTAssertEqual(WebActionSettleWait.outcome(navigated: true, mutations: 40), .navigated)
        XCTAssertEqual(WebActionSettleWait.outcome(navigated: false, mutations: 40), .changed)
        XCTAssertEqual(WebActionSettleWait.outcome(navigated: false, mutations: 0), .noEffect)
    }

    // MARK: - The popup gate

    /// `evaluateJavaScript` carries a live user gesture, so a synthesised click
    /// reaches `window.open` — measured. Under a session, a window nothing
    /// clicked is refused; a genuine `<a target="_blank">` still works.
    func testOnlyRealActivationOpensAWindowUnderASession() {
        XCTAssertTrue(WebActionPopupPolicy.allowsPopup(navigationType: .linkActivated))
        XCTAssertTrue(WebActionPopupPolicy.allowsPopup(navigationType: .formSubmitted))
        XCTAssertTrue(WebActionPopupPolicy.allowsPopup(navigationType: .formResubmitted))
        XCTAssertFalse(WebActionPopupPolicy.allowsPopup(navigationType: .other))
        XCTAssertFalse(WebActionPopupPolicy.allowsPopup(navigationType: .reload))
        XCTAssertFalse(WebActionPopupPolicy.allowsPopup(navigationType: .backForward))
    }
}
