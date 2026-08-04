//
//  WebActionBridge.swift
//  Cherry Browser
//
//  The action layer's one door onto a page: list, click, type.
//
//  ## The enforcement point, and why it is here rather than in a description
//
//  A tool description is a hint to a model, and a model can be talked out of a
//  hint by the page it is reading. So the permission check is not written down
//  anywhere a model can see it — it is `perform(_:on:by:)`'s first statement,
//  and the only way to reach the two primitives that change a page is to hold a
//  `WebActionBridge.Authorisation`, which nothing outside this file can
//  construct. See that type for the full argument.
//
//  `snapshot` is deliberately OUTSIDE the gate. Listing a page's controls is no
//  more sensitive than `read_page`, which already ships behind the bearer token
//  alone, and requiring a grant to LOOK would force a model to ask the user for
//  permission to act before it knows whether it needs any.
//
//  ## What is audited, and what is not
//
//  Every click, every typing, and every refusal of either. Not `snapshot`: an
//  audit log answers "did it do something I did not intend", and reading a list
//  of controls does nothing. `read_page` is not audited either, and `snapshot`
//  is `read_page`-class.
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
    /// `@MainActor` on the closure TYPE, not just at the call site. Both stores
    /// are explicitly `@MainActor` singletons, and an unannotated closure would
    /// be reaching a main-actor global from a nonisolated default-argument
    /// context — a warning today and an error under the Swift 6 language mode.
    private let sessions: @MainActor () -> WebActionSessionStore
    private let auditLog: @MainActor () -> WebActionAuditLog

    /// - Parameter browser: injected so a test drives a bridge built over a
    ///   known set of windows rather than whatever the running app has open.
    /// - Parameter sessions: injected so a test can advance an expiry clock
    ///   instead of sleeping through ten real minutes, and so one test's grants
    ///   are not another's.
    /// - Parameter auditLog: injected so a test writes to a temporary directory
    ///   rather than into the developer's own Application Support.
    init(
        browser: @escaping () -> MCPBrowserBridge = { MCPBrowserBridge.shared },
        sessions: @escaping @MainActor () -> WebActionSessionStore = { WebActionSessionStore.shared },
        auditLog: @escaping @MainActor () -> WebActionAuditLog = { WebActionAuditLog.shared }
    ) {
        self.browser = browser
        self.sessions = sessions
        self.auditLog = auditLog
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
        // The row cap goes INTO the world. The budget below still applies — two
        // bounds, and the outer one is the authority — but without this one the
        // whole listing was assembled, stringified, sent over IPC and decoded on
        // the main actor before anything was allowed to cut it.
        let bounded = WebActionScripts.boundedFilter(filter)
        let script = WebActionScripts.snapshot(
            scope: scope.rawValue,
            filter: bounded.text,
            limit: MCPResultCaps.elementsListed
        )
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

        return .snapshot(assemble(
            result, identity: identity, requested: scope, filterWasCut: bounded.wasCut
        ))
    }

    // MARK: - The enforcement point

    /// Proof that a live session existed at the moment the check ran.
    ///
    /// **This type is the reason there is no second path.** Every method below
    /// that evaluates a script capable of changing a page takes one, and the only
    /// way to obtain one is `authorise(tabID:requester:)`, whose first statement
    /// is `WebActionSessionStore.shared.liveSession(forTab:requester:)`. The
    /// initialiser is private to this file, so no other file — not
    /// `MCPToolInvoker`, not a future local-agent loop, not a test — can
    /// construct one. A reviewer looking for "a path that acts without a live
    /// session" has to find a caller of `click(_:)` or `type(_:)` that produced
    /// one of these without going through the store, and there is nowhere in the
    /// language for such a caller to exist.
    ///
    /// It is a snapshot, not a lease: holding one proves the session was live a
    /// moment ago, which is why the gate is re-checked before firing and again
    /// after the action returns.
    struct Authorisation {
        let session: WebActionSession
        let viewModel: BrowserViewModel
        let tab: Tab
        fileprivate init(session: WebActionSession, viewModel: BrowserViewModel, tab: Tab) {
            self.session = session
            self.viewModel = viewModel
            self.tab = tab
        }
    }

    private var store: WebActionSessionStore { sessions() }
    private var audit: WebActionAuditLog { auditLog() }

    /// Resolve the session, THEN the tab. In that order, and the order is the
    /// point: nothing about the browser is read — not which windows exist, not
    /// whether a tab id is real, not whether it is private — until a grant has
    /// been found. A caller with no session cannot use a refusal to learn
    /// anything about the user's tabs, because no tab was looked at.
    private func authorise(
        tabID: UUID?,
        requester: WebActionRequester
    ) -> Result<Authorisation, WebActionRefusal> {
        let held = store.liveSessions(for: requester)

        let session: WebActionSession
        if let tabID {
            guard let live = store.liveSession(forTab: tabID, requester: requester) else {
                return .failure(missingSessionRefusal(tabID: tabID, requester: requester, held: held))
            }
            session = live
        } else {
            switch held.count {
            case 0:
                return .failure(WebActionRefusal(
                    .noSession,
                    "You have no action session, so there is no tab to act in. Call "
                        + "request_action_session first and expect the user to be asked."
                ))
            case 1:
                session = held[0]
            default:
                return .failure(WebActionRefusal(
                    .ambiguousTab,
                    "You hold action sessions for \(held.count) tabs, so leaving out tab_id does not "
                        + "say which one you mean. Pass the tab_id the session was granted for."
                ))
            }
        }

        guard let located = try? browser().resolveTab(tabID: session.tabID).get() else {
            // The grant names a tab nothing can reach any more — closed, or moved
            // into a private window. The session dies with it rather than waiting
            // for its clock.
            store.endSessions(forTab: session.tabID, reason: .tabUnavailable)
            return .failure(WebActionRefusal(
                .notFound,
                WebActionSessionEnd.tabUnavailable.detail
            ))
        }
        return .success(Authorisation(session: session, viewModel: located.window, tab: located.tab))
    }

    /// The sentence for "there is no live grant here", which is five different
    /// situations and five different next moves.
    private func missingSessionRefusal(
        tabID: UUID,
        requester: WebActionRequester,
        held: [WebActionSession]
    ) -> WebActionRefusal {
        if let ended = store.endedSession(forTab: tabID, requester: requester) {
            let reason: WebActionRefusalReason = switch ended.endReason {
            case .expired: .sessionExpired
            case .revokedByUser: .sessionRevoked
            case .originChanged: .originChanged
            default: .sessionRevoked
            }
            return WebActionRefusal(reason, (ended.endReason ?? .expired).detail)
        }
        if !held.isEmpty {
            return WebActionRefusal(
                .wrongTab,
                "Your action session is for a different tab. A grant covers one tab and does not "
                    + "extend to another; act in the tab it was granted for, or ask for that tab."
            )
        }
        return WebActionRefusal(
            .noSession,
            "You have no action session for this tab, so Cherry will not click or type in it. "
                + "Call request_action_session first and expect the user to be asked."
        )
    }

    // MARK: - request_action_session

    /// Ask the user for permission to click and type in one tab.
    ///
    /// The tab is resolved and run through the shared refusal ladder BEFORE the
    /// user is shown anything, so Cherry never asks for permission to act on a
    /// sleeping tab, a `cherry://` page, or a tab that has never been displayed.
    /// A prompt the user could only answer wrongly is worse than no prompt.
    func requestSession(
        tabID: UUID,
        purpose: String,
        minutes: Int,
        by requester: WebActionRequester
    ) async -> WebActionSessionResult {
        let viewModel: BrowserViewModel
        let tab: Tab
        switch browser().resolveTab(tabID: tabID) {
        case .success(let located):
            (viewModel, tab) = located
        case .failure(let refusal):
            return .refused(WebActionRefusal(.noSuchTab, refusal.detail))
        }

        let webView: WKWebView
        switch await browser().readableWebView(for: tab, MCPWebViewPurpose.listingElements) {
        case .success(let live):
            webView = live
        case .failure(let refusal):
            return .refused(WebActionRefusal(Self.refusalReason(for: refusal.reason), refusal.detail))
        }

        guard let origin = WebActionOrigin.of(webView.url) else {
            return .refused(WebActionRefusal(
                .noSuchTab,
                "This tab is not on a website Cherry can grant a session for — it has no site "
                    + "address to pin the permission to. Open a page first."
            ))
        }

        let decision = await store.requestSession(
            tabID: tabID,
            windowID: viewModel.windowID,
            tabTitle: tab.displayTitle,
            origin: origin,
            purpose: purpose,
            minutes: minutes,
            requester: requester
        )

        switch decision {
        case .granted(let session):
            audit.record(WebActionAuditEntry(
                action: "session_granted",
                at: Date(),
                sessionID: session.id.uuidString,
                requester: requester.rawValue,
                purpose: session.purpose,
                tabID: session.tabID.uuidString,
                windowID: session.windowID.uuidString,
                document: nil,
                urlBefore: origin,
                urlAfter: nil,
                element: nil, role: nil, name: nil, tag: nil, type: nil, href: nil,
                formAction: nil, formMethod: nil,
                charsTyped: nil, submitted: nil,
                decision: "granted",
                result: "\(session.grantedMinutes) minutes",
                revokedMidAction: nil,
                detail: nil
            ))
            return .granted(WebActionSessionGrant(
                sessionID: session.id.uuidString,
                tabID: session.tabID.uuidString,
                windowID: session.windowID.uuidString,
                origin: session.origin,
                purpose: session.purpose,
                expiresAt: session.expiresAt,
                grantedMinutes: session.grantedMinutes,
                note: "The user can end this at any moment from the bar above the page. It also "
                    + "ends if this tab leaves \(session.origin), closes, or goes to sleep. Every "
                    + "action result tells you if it has."
            ))

        case .declined:
            audit.record(Self.consentRefusalEntry(
                requester: requester, purpose: purpose, tabID: tabID,
                windowID: viewModel.windowID, origin: origin, result: "declined"
            ))
            return .refused(WebActionRefusal(
                .declined,
                "The user declined. Do not ask again for this tab, do not rephrase the purpose and "
                    + "retry, and do not look for another way in. Tell them what you could not do."
            ))

        case .declinedEarlier:
            return .refused(WebActionRefusal(
                .declinedEarlier,
                "The user already declined for this tab, and Cherry will not show them the same "
                    + "request again so soon. Asking twice is how a person is trained to press "
                    + "Allow without reading. Tell them what you could not do."
            ))

        case .alreadyAsking:
            return .refused(WebActionRefusal(
                .alreadyAsking,
                "Cherry is already asking the user about this tab. Wait for that answer rather "
                    + "than raising a second prompt."
            ))

        case .noAnswer:
            audit.record(Self.consentRefusalEntry(
                requester: requester, purpose: purpose, tabID: tabID,
                windowID: viewModel.windowID, origin: origin, result: "no_answer"
            ))
            return .refused(WebActionRefusal(
                .noAnswer,
                "The user did not answer, so nothing was granted. They may not be at the machine. "
                    + "Say what you were waiting for rather than trying again immediately."
            ))
        }
    }

    private static func consentRefusalEntry(
        requester: WebActionRequester,
        purpose: String,
        tabID: UUID,
        windowID: UUID,
        origin: String,
        result: String
    ) -> WebActionAuditEntry {
        WebActionAuditEntry(
            action: "session_declined",
            at: Date(),
            sessionID: nil,
            requester: requester.rawValue,
            purpose: WebActionText.sanitisePurpose(purpose),
            tabID: tabID.uuidString,
            windowID: windowID.uuidString,
            document: nil,
            urlBefore: origin,
            urlAfter: nil,
            element: nil, role: nil, name: nil, tag: nil, type: nil, href: nil,
            formAction: nil, formMethod: nil,
            charsTyped: nil, submitted: nil,
            decision: "refused",
            result: result,
            revokedMidAction: nil,
            detail: nil
        )
    }

    // MARK: - perform

    /// Click or type. **Every action goes through this and there is no second
    /// path.**
    ///
    /// The order of the first two statements is the whole security property: the
    /// session is resolved before the tab is, so a caller without a grant never
    /// causes a window to be enumerated, never learns whether a tab id is real,
    /// and never reaches a `WKWebView`. Everything after that is a narrowing —
    /// the refusal ladder, the origin pin, the document token, the element's
    /// identity, the commitment heuristic — and each one is checked where the
    /// action executes rather than described where a model reads.
    func perform(
        _ action: WebAction,
        on tabID: UUID?,
        by requester: WebActionRequester
    ) async -> WebActionResult {
        // 1. THE GATE. Before anything is resolved, read or evaluated.
        let authorisation: Authorisation
        switch authorise(tabID: tabID, requester: requester) {
        case .success(let granted):
            authorisation = granted
        case .failure(let refusal):
            // Recorded without a tab or window id when there is no session: the
            // refusal never looked at a tab, and the log must not invent one.
            audit.record(Self.gateRefusalEntry(
                action: action, requester: requester, tabID: tabID, refusal: refusal
            ))
            return .refused(refusal)
        }

        let session = authorisation.session
        let tab = authorisation.tab
        var context = ActionContext(
            action: action,
            session: session,
            windowID: authorisation.viewModel.windowID,
            urlBefore: tab.displayURL.mcpTruncated(to: MCPResultCaps.urlChars)
        )

        // 2. The same five rungs `read_page` and `read_elements` run. A tab that
        //    went to sleep or was covered by a cherry:// page under a live grant
        //    is a tab that can no longer be acted on, and the grant ends with it.
        let webView: WKWebView
        switch await browser().readableWebView(for: tab, MCPWebViewPurpose.listingElements) {
        case .success(let live):
            webView = live
        case .failure(let refusal):
            store.endSessions(forTab: session.tabID, reason: .tabUnavailable)
            return refuse(
                WebActionRefusal(Self.refusalReason(for: refusal.reason), refusal.detail),
                context
            )
        }

        // 3. The origin pin, against the LIVE document rather than the tab model.
        //    They diverge during navigation and across redirects, and this check
        //    is the one that must not be fooled by the gap.
        let liveOrigin = WebActionOrigin.of(webView.url)
        context.urlBefore = (webView.url?.absoluteString ?? context.urlBefore)
            .mcpTruncated(to: MCPResultCaps.urlChars)
        guard liveOrigin == session.origin else {
            store.endSessions(forTab: session.tabID, reason: .originChanged)
            return refuse(
                WebActionRefusal(
                    .originChanged,
                    "This tab is now on \(liveOrigin ?? "a page with no site address") and the "
                        + "user granted permission for \(session.origin). "
                        + WebActionSessionEnd.originChanged.detail
                ),
                context
            )
        }

        // 4. Describe the element without touching it. The document token is
        //    compared INSIDE the page, so a navigation committing between this
        //    call being issued and it running is caught by the page rather than
        //    guessed at from Swift.
        let wantsSubmit: Bool = if case .type(_, _, _, _, _, let submit, _) = action { submit } else { false }
        let armed: WebActionRawArm
        do {
            armed = try await decode(
                WebActionRawArm.self,
                from: WebActionScripts.arm(
                    id: action.element,
                    expectName: action.expectName,
                    document: action.document,
                    wantsSubmit: wantsSubmit
                ),
                in: webView
            )
        } catch {
            return .failed(
                "Cherry could not reach the page to check element \(action.element): "
                    + error.localizedDescription
            )
        }
        guard armed.ok, let token = armed.token else {
            return refuse(Self.armRefusal(armed, action: action), context)
        }

        context.document = armed.doc
        let shownName = WebActionScripts.sanitiseName(armed.nameNow)
        context.element = Self.auditIdentity(armed, element: action.element, name: shownName)

        // 5. Everything Swift decides, in one place, on the description above.
        if let refusal = Self.elementRefusal(
            armed, action: action, shownName: shownName, expected: action.expectName
        ) {
            return refuse(refusal, context)
        }

        // 6. The gate again. The description round trip is asynchronous IPC, and
        //    the user may have pressed End inside it.
        guard store.liveSession(forTab: session.tabID, requester: requester) != nil else {
            return refuse(
                WebActionRefusal(
                    .sessionRevoked,
                    "The action session ended while Cherry was checking the element. Nothing was "
                        + "clicked or typed.",
                    element: action.element,
                    name: shownName
                ),
                context
            )
        }

        // 7. Act. `fire` re-verifies the document, the element and its raw name
        //    inside the page, atomically with the action itself.
        let fired: WebActionRawFire
        do {
            fired = try await decode(
                WebActionRawFire.self,
                from: Self.fireScript(action, token: token, armed: armed),
                in: webView
            )
        } catch {
            // A throw here usually means the document went away mid-call, which
            // is a navigation, not a breakage — but Cherry does not know whether
            // the action landed first, and a model must not be told it did.
            return .failed(
                "Cherry lost the page while performing this action, so it cannot say whether the "
                    + "action happened. Do not retry: call read_elements to see where the tab is now."
            )
        }
        guard fired.ok else {
            return refuse(Self.fireRefusal(fired, action: action, shownName: shownName), context)
        }

        // 8. Watch.
        let waited = await watchOutcome(in: webView, waitMS: action.waitMS)
        _ = try? await webView.evaluateJavaScript(
            WebActionScripts.watchStop, in: nil, contentWorld: Self.actionWorld
        )

        // 9. The honest part about revocation. An action already inside
        //    `evaluateJavaScript` cannot be un-fired: the click has happened in
        //    the web content process. So the gate is re-checked AFTER the await,
        //    and a session that ended in the gap produces a refusal that says the
        //    action may have completed — because claiming instant revocation of
        //    an in-flight click would be a lie.
        let stillLive = store.liveSession(forTab: session.tabID, requester: requester) != nil
        let outcome = WebActionSettleWait.outcome(
            navigated: waited.navigated, mutations: waited.mutations
        )
        let urlAfter = (webView.url?.absoluteString ?? context.urlBefore)
            .mcpTruncated(to: MCPResultCaps.urlChars)

        if !stillLive {
            audit.record(context.entry(
                decision: "acted", result: outcome.rawValue, urlAfter: urlAfter,
                revokedMidAction: true,
                detail: "the user ended the session while this action was in flight"
            ))
            return .refused(WebActionRefusal(
                .sessionRevoked,
                "The user ended this session while the action was in flight. The \(action.kind) may "
                    + "have completed — Cherry cannot un-fire something the page has already seen. "
                    + "Do not retry; tell the user what you had attempted.",
                element: action.element,
                name: shownName,
                document: context.document
            ))
        }

        // 10. Report.
        //
        // A navigation does NOT end the session, and that is deliberate: logging
        // in navigates, and a grant that died on the first click would be a grant
        // for nothing. What ends it is leaving the ORIGIN, and that is checked at
        // the top of the next call against the live document rather than guessed
        // at from here — where the new page may not have committed yet.
        audit.record(context.entry(
            decision: "acted", result: outcome.rawValue, urlAfter: urlAfter,
            revokedMidAction: nil, detail: nil
        ))

        let value = fired.valueAfter.map { WebActionScripts.sanitiseName($0) }
        return .acted(WebActionActed(
            action: action.kind,
            outcome: outcome,
            tabID: session.tabID.uuidString,
            windowID: context.windowID.uuidString,
            element: action.element,
            role: armed.role ?? "element",
            name: shownName,
            urlBefore: context.urlBefore,
            urlAfter: urlAfter,
            document: armed.doc,
            snapshotInvalidated: outcome == .navigated,
            mutations: waited.mutations,
            waitedMS: waited.elapsedMS,
            obscuredBy: fired.obscuredBy.map { WebActionScripts.sanitiseName($0) },
            valueAfter: value,
            valueTruncated: fired.valueAfter.map { $0.count > WebActionScripts.nameChars },
            frameworkObserved: action.kind == "type" ? waited.mutations > 0 : nil,
            submitted: fired.submitted,
            note: Self.note(
                for: outcome, action: action, fired: fired,
                mutations: waited.mutations, origin: session.origin,
                auditFailed: audit.lastWriteFailed
            )
        ))
    }

    // MARK: - Watching

    private struct Watched {
        var mutations = 0
        var navigated = false
        var elapsedMS = 0
    }

    /// Sample the observer until the page goes quiet, navigates, or the window
    /// closes.
    private func watchOutcome(in webView: WKWebView, waitMS: Int) async -> Watched {
        var watched = Watched()
        let started = Date()

        while true {
            let raw: Any?
            do {
                // Deliberately NOT in a way that reinstalls the world — see
                // `WebActionScripts.watchPoll`. A missing world here IS the
                // navigation signal.
                raw = try await webView.evaluateJavaScript(
                    WebActionScripts.watchPoll, in: nil, contentWorld: Self.actionWorld
                )
            } catch {
                watched.navigated = true
                break
            }
            guard let json = raw as? String,
                  let data = json.data(using: .utf8),
                  let poll = try? JSONDecoder().decode(WebActionRawPoll.self, from: data)
            else {
                watched.navigated = true
                break
            }
            guard poll.ok else {
                // `gone` means the world went with the document. `not_watching`
                // means the world was rebuilt, which is the same thing seen from
                // the other side.
                watched.navigated = true
                break
            }
            watched.mutations = poll.mutations
            if poll.urlChanged {
                watched.navigated = true
                break
            }

            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            watched.elapsedMS = elapsed
            if WebActionSettleWait.shouldStop(
                mutations: poll.mutations,
                sinceLastMutationMS: poll.sinceLastMS,
                elapsedMS: elapsed,
                maxWaitMS: waitMS
            ) {
                break
            }
            try? await Task.sleep(for: .milliseconds(WebActionSettleWait.pollIntervalMS))
        }

        watched.elapsedMS = max(watched.elapsedMS, Int(Date().timeIntervalSince(started) * 1000))
        return watched
    }

    // MARK: - Decisions Swift makes, on the description the page gave

    /// Everything that stops an armed element from being acted on.
    ///
    /// `nonisolated static` on purpose: it is pure, it is where the security
    /// decisions concentrate, and a test can run every branch of it without a
    /// browser.
    nonisolated static func elementRefusal(
        _ armed: WebActionRawArm,
        action: WebAction,
        shownName: String,
        expected: String
    ) -> WebActionRefusal? {
        // The name the model agreed to, compared in the form it was shown. The
        // page compares the RAW form again inside `fire`; this one is what
        // catches "the id still resolves, but to something you did not choose".
        guard shownName == WebActionScripts.sanitiseName(expected) else {
            return WebActionRefusal(
                .nameMismatch,
                "Element \(action.element) is now \"\(shownName)\", not \"\(expected)\". The page "
                    + "changed under you, so nothing was done. Call read_elements again and choose "
                    + "from the new listing rather than guessing.",
                element: action.element,
                name: shownName,
                document: armed.doc
            )
        }

        if armed.disabled {
            return WebActionRefusal(
                .disabled,
                "\"\(shownName)\" is disabled, so nothing would happen. Something else on the page "
                    + "usually has to change first.",
                element: action.element,
                name: shownName
            )
        }

        // A file input's click opens a real macOS open panel — a modal window
        // over the user's browser, from a synthesised click. Cherry does not do
        // that on a model's say-so, and this refusal is by ROLE, before any
        // JavaScript touches the element.
        if armed.role == "file" {
            return WebActionRefusal(
                .filePicker,
                "\"\(shownName)\" opens a file chooser on the user's Mac. Cherry will not open one "
                    + "from a tool call. Ask the user to choose the file themselves.",
                element: action.element,
                name: shownName
            )
        }

        let descriptor = WebActionElementDescriptor(
            role: armed.role ?? "",
            name: armed.nameNow,
            tag: armed.tag,
            type: armed.type,
            hasHref: armed.hasHref,
            hrefIsNavigational: armed.nav,
            inForm: armed.inForm
        )

        switch action {
        case .click:
            if let verb = WebActionHeuristics.classify(descriptor).verb {
                return WebActionRefusal(
                    .irreversible,
                    "\"\(shownName)\" is a \(armed.tag.lowercased()) whose name carries "
                        + "\"\(verb)\", so it looks like it commits something that cannot be taken "
                        + "back. Cherry does not click these from a tool call. Tell the user what "
                        + "you were about to do and let them click it themselves — do not look for "
                        + "another element that does the same thing.",
                    element: action.element,
                    name: shownName
                )
            }

        case .type(_, _, _, let text, _, let submit, _):
            if (armed.type ?? "").lowercased() == "password" {
                return WebActionRefusal(
                    .passwordField,
                    "\"\(shownName)\" is a password field. Cherry will not type into one from a "
                        + "tool call, whatever the text is. Cherry stores the user's passwords and "
                        + "fills them itself when the user asks; stop and say a secret is needed.",
                    element: action.element,
                    name: shownName
                )
            }
            guard Self.acceptsTyping(armed) else {
                return WebActionRefusal(
                    .notATextField,
                    "\"\(shownName)\" is a \(armed.role ?? armed.tag.lowercased()) and there is "
                        + "nowhere in it to type. Use click_element for controls you press or "
                        + "choose from.",
                    element: action.element,
                    name: shownName
                )
            }
            if text.isEmpty {
                return WebActionRefusal(
                    .notATextField,
                    "text was empty. To clear a field, pass a single space or say so to the user; "
                        + "typing nothing is not an action Cherry performs.",
                    element: action.element,
                    name: shownName
                )
            }
            // THE hole the plan names as the largest in the design, closed the
            // only way it can be: Enter in a form presses that form's default
            // button, so the default button is classified by the same rule a
            // direct click on it would be, and a commitment-shaped one refuses
            // the whole call.
            if submit, let control = armed.submitControl {
                let submitName = WebActionScripts.sanitiseName(control.name)
                if let verb = WebActionHeuristics.classify(WebActionElementDescriptor(
                    role: control.role,
                    name: control.name,
                    tag: control.tag,
                    type: control.type,
                    hasHref: control.href,
                    hrefIsNavigational: control.nav,
                    inForm: true
                )).verb {
                    return WebActionRefusal(
                        .irreversible,
                        "Pressing Enter in \"\(shownName)\" submits its form, and that form's "
                            + "button is \"\(submitName)\", whose name carries \"\(verb)\". That is "
                            + "the same commitment as clicking it, so Cherry refuses it the same "
                            + "way. Type without submit: true and tell the user what is left to do.",
                        element: action.element,
                        name: submitName
                    )
                }
            }
        }
        return nil
    }

    /// Input types with nowhere to type. Everything else — text, email, search,
    /// url, tel, number, date, a bare `<input>`, a textarea, a contenteditable —
    /// accepts typing.
    nonisolated private static let untypeableInputTypes: Set<String> = [
        "checkbox", "radio", "submit", "button", "reset", "image", "file",
        "range", "color", "hidden",
    ]

    nonisolated static func acceptsTyping(_ armed: WebActionRawArm) -> Bool {
        if armed.editable { return true }
        if armed.tag == "TEXTAREA" { return true }
        guard armed.tag == "INPUT" else { return false }
        return !untypeableInputTypes.contains((armed.type ?? "text").lowercased())
    }

    // MARK: - Refusals from the page's own answers

    nonisolated static func armRefusal(_ armed: WebActionRawArm, action: WebAction) -> WebActionRefusal {
        switch armed.reason {
        case "snapshot_gone":
            WebActionRefusal(
                .snapshotGone,
                "The page has moved on since element \(action.element) was listed"
                    + (armed.doc.isEmpty ? "" : " — it is now on document \(armed.doc)")
                    + ". Every element number you are holding names nothing. Call read_elements "
                    + "again and use the numbers and the document it returns.",
                element: action.element,
                document: armed.doc.isEmpty ? nil : armed.doc
            )
        case "element_detached":
            WebActionRefusal(
                .elementDetached,
                "Element \(action.element) was on this page and has been removed from it. The page "
                    + "is still the same one; call read_elements again for what is there now.",
                element: action.element,
                document: armed.doc
            )
        default:
            WebActionRefusal(
                .unknownElement,
                "Element \(action.element) was never listed on this page. Do not guess a number — "
                    + "call read_elements and use one it gave you.",
                element: action.element,
                document: armed.doc
            )
        }
    }

    nonisolated static func fireRefusal(
        _ fired: WebActionRawFire,
        action: WebAction,
        shownName: String
    ) -> WebActionRefusal {
        switch fired.reason {
        case "name_mismatch":
            WebActionRefusal(
                .nameMismatch,
                "\"\(shownName)\" changed its name in the instant before Cherry acted, so nothing "
                    + "was done. Call read_elements again.",
                element: action.element,
                name: shownName,
                document: fired.doc
            )
        case "element_detached":
            WebActionRefusal(
                .elementDetached,
                "Element \(action.element) left the page in the instant before Cherry acted, so "
                    + "nothing was done.",
                element: action.element,
                document: fired.doc
            )
        case "click_threw", "type_threw":
            WebActionRefusal(
                .elementDetached,
                "The page refused the \(action.kind) on \"\(shownName)\" and nothing happened.",
                element: action.element,
                name: shownName,
                document: fired.doc
            )
        default:
            WebActionRefusal(
                .snapshotGone,
                "The page changed between Cherry checking element \(action.element) and acting on "
                    + "it, so nothing was done. Call read_elements again.",
                element: action.element,
                document: fired.doc.isEmpty ? nil : fired.doc
            )
        }
    }

    /// What the model should do next. Never nil after a navigation.
    nonisolated static func note(
        for outcome: WebActionOutcomeKind,
        action: WebAction,
        fired: WebActionRawFire,
        mutations: Int,
        origin: String,
        auditFailed: Bool
    ) -> String? {
        var parts: [String] = []
        switch outcome {
        case .navigated:
            parts.append("The page navigated. Every element number and the document token from "
                + "before this \(action.kind) are invalid; call read_elements again")
            parts.append("the action session survives a move within \(origin) — logging in "
                + "navigates — but ends the moment this tab reaches another site, and the next "
                + "call is where that is decided")
        case .changed:
            parts.append(action.kind == "type"
                ? "the page's own code reacted to the typing (\(mutations) DOM changes), so the "
                    + "field is live rather than merely filled"
                : "the page changed in place (\(mutations) DOM changes) — element numbers still "
                    + "stand, but what is on screen has moved, so re-list before choosing again")
        case .noEffect:
            parts.append("nothing observably happened within the wait. That usually means the "
                + "wrong element rather than a slow one; do not simply try again")
        }
        if let obscured = fired.obscuredBy {
            parts.append("the element was underneath \(WebActionScripts.sanitiseName(obscured)) — "
                + "the \(action.kind) still went through, but a user could not have made it, so "
                + "deal with the overlay before you continue")
        }
        if case .type(_, _, _, _, _, true, _) = action, fired.submitButtonClicked != true {
            parts.append("Enter was pressed, but this field is not in a form with a submit button, "
                + "so whether that submitted anything is up to the page's own code — read the "
                + "elements again to find out")
        }
        if auditFailed {
            parts.append("Cherry could not write this action to its action log")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: ". ") + "."
    }

    // MARK: - Audit plumbing

    /// Everything an audit entry needs, gathered as the action proceeds.
    private struct ActionContext {
        let action: WebAction
        let session: WebActionSession
        let windowID: UUID
        var urlBefore: String
        var document: String?
        var element: AuditIdentity?

        func entry(
            decision: String,
            result: String,
            urlAfter: String?,
            revokedMidAction: Bool?,
            detail: String?
        ) -> WebActionAuditEntry {
            let charsTyped: Int? = if case .type(_, _, _, let text, _, _, _) = action {
                text.count
            } else {
                nil
            }
            let submitted: Bool? = if case .type(_, _, _, _, _, let submit, _) = action {
                submit
            } else {
                nil
            }
            return WebActionAuditEntry(
                action: action.kind,
                at: Date(),
                sessionID: session.id.uuidString,
                requester: session.requester.rawValue,
                purpose: session.purpose,
                tabID: session.tabID.uuidString,
                windowID: windowID.uuidString,
                document: document,
                urlBefore: urlBefore,
                urlAfter: urlAfter,
                element: element?.element ?? action.element,
                role: element?.role,
                name: element?.name,
                tag: element?.tag,
                type: element?.type,
                href: element?.href,
                formAction: element?.formAction,
                formMethod: element?.formMethod,
                charsTyped: charsTyped,
                submitted: submitted,
                decision: decision,
                result: result,
                revokedMidAction: revokedMidAction,
                detail: detail
            )
        }
    }

    /// The element's identity as the audit log records it. Every string here has
    /// been through `sanitiseName`, because they are page-authored and a log line
    /// is read by a person.
    struct AuditIdentity {
        let element: Int
        let role: String
        let name: String
        let tag: String
        let type: String?
        let href: String?
        let formAction: String?
        let formMethod: String?
    }

    private static func auditIdentity(_ armed: WebActionRawArm, element: Int, name: String) -> AuditIdentity {
        AuditIdentity(
            element: element,
            role: armed.role ?? "",
            name: name,
            tag: armed.tag,
            type: armed.type.map { WebActionScripts.sanitiseName($0) },
            href: armed.href.map { WebActionScripts.sanitiseName($0) },
            formAction: armed.formAction.map { WebActionScripts.sanitiseName($0) },
            formMethod: armed.formMethod.map { WebActionScripts.sanitiseName($0) }
        )
    }

    private static func gateRefusalEntry(
        action: WebAction,
        requester: WebActionRequester,
        tabID: UUID?,
        refusal: WebActionRefusal
    ) -> WebActionAuditEntry {
        WebActionAuditEntry(
            action: action.kind,
            at: Date(),
            sessionID: nil,
            requester: requester.rawValue,
            purpose: "",
            tabID: tabID?.uuidString ?? "",
            windowID: "",
            document: action.document,
            urlBefore: "",
            urlAfter: nil,
            element: action.element,
            role: nil,
            name: nil,
            tag: nil,
            type: nil,
            href: nil,
            formAction: nil,
            formMethod: nil,
            charsTyped: {
                if case .type(_, _, _, let text, _, _, _) = action { return text.count }
                return nil
            }(),
            submitted: nil,
            decision: "refused",
            result: refusal.reason.rawValue,
            revokedMidAction: nil,
            detail: nil
        )
    }

    private func refuse(_ refusal: WebActionRefusal, _ context: ActionContext) -> WebActionResult {
        audit.record(context.entry(
            decision: "refused",
            result: refusal.reason.rawValue,
            urlAfter: nil,
            revokedMidAction: nil,
            detail: nil
        ))
        return .refused(refusal)
    }

    /// The read ladder's vocabulary, in the acting vocabulary. One mapping, so
    /// the two cannot drift into disagreeing about what `sleeping` means.
    nonisolated static func refusalReason(for reason: MCPUnreadableReason) -> WebActionRefusalReason {
        switch reason {
        case .notFound: .notFound
        case .sleeping: .sleeping
        case .internalPage: .internalPage
        case .homePage: .homePage
        case .pdf: .pdf
        case .notRendered: .notRendered
        case .noContent: .notFound
        }
    }

    private static func fireScript(_ action: WebAction, token: String, armed: WebActionRawArm) -> String {
        switch action {
        case .click:
            return WebActionScripts.fireClick(token: token)
        case .type(_, _, _, let text, let append, let submit, _):
            return WebActionScripts.fireType(
                token: token,
                text: text,
                append: append,
                submit: submit,
                // Only ever true once the default button has been through the
                // commitment rule above and come back ordinary.
                clickDefaultButton: submit && armed.submitControl != nil
            )
        }
    }

    private func decode<Payload: Decodable>(
        _ type: Payload.Type,
        from script: String,
        in webView: WKWebView
    ) async throws -> Payload {
        let raw = try await webView.evaluateJavaScript(script, in: nil, contentWorld: Self.actionWorld)
        guard let json = raw as? String, let data = json.data(using: .utf8) else {
            throw WebActionScriptFailure.unreadable
        }
        return try JSONDecoder().decode(Payload.self, from: data)
    }

    enum WebActionScriptFailure: Error { case unreadable }

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
        requested: WebActionScope,
        filterWasCut: Bool
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

        // Against `listable`, not against `elements.count` — the isolated world
        // now caps rows too, and measuring the cut against a number the cap
        // already shrank would report "500 of 500" on a page with 20,000
        // controls, which is the silent-cap failure in its purest form.
        let truncated = elements.count < raw.listable

        /// "1 element" / "3 elements", because a note that reads as machine
        /// output is a note a model skims.
        func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

        var notes: [String] = []
        if truncated {
            let reason = raw.rowCapped && elements.count == raw.elements.count
                ? "cap of \(MCPResultCaps.elementsListed) reached"
                : budget.limitHitDescription
            notes.append("\(elements.count) of \(count(raw.listable, "element")) shown "
                + "(\(reason)); pass filter to narrow to the control you want")
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
            notes.append("this page has \(raw.framesCapped ? "at least " : "")\(raw.frames) frames and "
                + "Cherry lists the main one only, so controls inside the other "
                + "\(raw.frames - 1) are missing from this list")
        } else if raw.framesCapped {
            notes.append("this page nests frames deeper than Cherry counts, so there are frames it "
                + "did not reach and cannot list")
        }
        if raw.closedShadowHosts > 0 {
            notes.append("\(count(raw.closedShadowHosts, "element")) "
                + "\(raw.closedShadowHosts == 1 ? "looks" : "look") like "
                + "\(raw.closedShadowHosts == 1 ? "it hides" : "they hide") a closed shadow root, "
                + "whose contents no browser can list")
        }
        if raw.unwalkedShadowHosts > 0 {
            notes.append("\(count(raw.unwalkedShadowHosts, "shadow root")) "
                + "\(raw.unwalkedShadowHosts == 1 ? "was" : "were") nested deeper than Cherry walks, "
                + "so \(raw.unwalkedShadowHosts == 1 ? "its" : "their") controls are not in this list "
                + "even though they could have been read")
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
        if filterWasCut {
            notes.append("the filter you passed was longer than \(WebActionScripts.filterChars) "
                + "characters and only its first \(WebActionScripts.filterChars) were applied, so "
                + "this list may be wider than you asked for")
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
            listable: raw.listable,
            droppedNoLayout: raw.droppedNoLayout,
            offscreenNotListed: raw.offscreenNotListed,
            filteredOut: raw.filteredOut,
            frames: raw.frames,
            framesCapped: raw.framesCapped,
            unwalkedShadowHosts: raw.unwalkedShadowHosts,
            closedShadowHosts: raw.closedShadowHosts,
            shadowRootsEntered: raw.shadowRootsEntered,
            pageVisible: raw.pageVisible,
            visibility: raw.visibility,
            walkCapped: raw.walkCapped,
            filterWasCut: filterWasCut,
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
        let doc: String
        let url: String
        let title: String
        let scope: String
        let pageVisible: Bool
        let visibility: String
        let frames: Int
        let framesCapped: Bool
        let matched: Int
        let listable: Int
        let rowCapped: Bool
        let droppedNoLayout: Int
        let offscreenNotListed: Int
        let filteredOut: Int
        let shadowRootsEntered: Int
        let closedShadowHosts: Int
        let unwalkedShadowHosts: Int
        let walkCapped: Bool
        let elements: [RawElement]

        private enum CodingKeys: String, CodingKey {
            case ok, gen, doc, url, title, scope, frames, matched, listable, visibility, elements
            case framesCapped = "frames_capped"
            case rowCapped = "row_capped"
            case pageVisible = "page_visible"
            case droppedNoLayout = "dropped_no_layout"
            case offscreenNotListed = "offscreen_not_listed"
            case filteredOut = "filtered_out"
            case shadowRootsEntered = "shadow_roots_entered"
            case closedShadowHosts = "closed_shadow_hosts"
            case unwalkedShadowHosts = "unwalked_shadow_hosts"
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
            doc = try box.decodeIfPresent(String.self, forKey: .doc) ?? ""
            url = try box.decodeIfPresent(String.self, forKey: .url) ?? ""
            title = try box.decodeIfPresent(String.self, forKey: .title) ?? ""
            scope = try box.decodeIfPresent(String.self, forKey: .scope) ?? ""
            pageVisible = try box.decodeIfPresent(Bool.self, forKey: .pageVisible) ?? true
            visibility = try box.decodeIfPresent(String.self, forKey: .visibility) ?? ""
            frames = try box.decodeIfPresent(Int.self, forKey: .frames) ?? 1
            framesCapped = try box.decodeIfPresent(Bool.self, forKey: .framesCapped) ?? false
            matched = try box.decodeIfPresent(Int.self, forKey: .matched) ?? 0
            listable = try box.decodeIfPresent(Int.self, forKey: .listable) ?? 0
            rowCapped = try box.decodeIfPresent(Bool.self, forKey: .rowCapped) ?? false
            droppedNoLayout = try box.decodeIfPresent(Int.self, forKey: .droppedNoLayout) ?? 0
            offscreenNotListed = try box.decodeIfPresent(Int.self, forKey: .offscreenNotListed) ?? 0
            filteredOut = try box.decodeIfPresent(Int.self, forKey: .filteredOut) ?? 0
            shadowRootsEntered = try box.decodeIfPresent(Int.self, forKey: .shadowRootsEntered) ?? 0
            closedShadowHosts = try box.decodeIfPresent(Int.self, forKey: .closedShadowHosts) ?? 0
            unwalkedShadowHosts = try box.decodeIfPresent(Int.self, forKey: .unwalkedShadowHosts) ?? 0
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

// MARK: - What the isolated world hands back when acting

/// The three wire shapes between the acting scripts and the bridge.
///
/// `nonisolated` and file-scope rather than nested, for two reasons: the pure
/// decision functions that consume them (`elementRefusal`, `acceptsTyping`,
/// `armRefusal`) are `nonisolated static` so a test can run every branch of them
/// without a browser, and a nested type in this target would be main-actor
/// isolated by default and could not appear in their signatures.
///
/// Every field is `decodeIfPresent` with a default, exactly as `RawSnapshot` is
/// and for the same reason: the `ok: false` answers carry three keys, and a
/// synthesised `init(from:)` would throw on the twenty missing ones — turning
/// "the page moved on", which is a refusal a model can act on, into "Cherry
/// could not read its own output", which is a failure it cannot.
nonisolated struct WebActionRawArm: Decodable {
    var ok = false
    var reason = ""
    var doc = ""
    var token: String?
    var role: String?
    var nameNow = ""
    var tag = ""
    var type: String?
    var hasHref = false
    var href: String?
    var nav = false
    var inForm = false
    var formAction: String?
    var formMethod: String?
    var disabled = false
    var editable = false
    var onscreen = false
    var hit = ""
    var obscuredBy: String?
    var url = ""
    var submitControl: WebActionRawControl?

    private enum CodingKeys: String, CodingKey {
        case ok, reason, doc, token, role, tag, type, href, nav, disabled, editable, onscreen, hit, url
        case nameNow = "name_now"
        case hasHref = "has_href"
        case inForm = "in_form"
        case formAction = "form_action"
        case formMethod = "form_method"
        case obscuredBy = "obscured_by"
        case submitControl = "submit_control"
    }

    init() {}

    init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        ok = try box.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        reason = try box.decodeIfPresent(String.self, forKey: .reason) ?? ""
        doc = try box.decodeIfPresent(String.self, forKey: .doc) ?? ""
        token = try box.decodeIfPresent(String.self, forKey: .token)
        role = try box.decodeIfPresent(String.self, forKey: .role)
        nameNow = try box.decodeIfPresent(String.self, forKey: .nameNow) ?? ""
        tag = try box.decodeIfPresent(String.self, forKey: .tag) ?? ""
        type = try box.decodeIfPresent(String.self, forKey: .type)
        hasHref = try box.decodeIfPresent(Bool.self, forKey: .hasHref) ?? false
        href = try box.decodeIfPresent(String.self, forKey: .href)
        nav = try box.decodeIfPresent(Bool.self, forKey: .nav) ?? false
        inForm = try box.decodeIfPresent(Bool.self, forKey: .inForm) ?? false
        formAction = try box.decodeIfPresent(String.self, forKey: .formAction)
        formMethod = try box.decodeIfPresent(String.self, forKey: .formMethod)
        disabled = try box.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
        editable = try box.decodeIfPresent(Bool.self, forKey: .editable) ?? false
        onscreen = try box.decodeIfPresent(Bool.self, forKey: .onscreen) ?? false
        hit = try box.decodeIfPresent(String.self, forKey: .hit) ?? ""
        obscuredBy = try box.decodeIfPresent(String.self, forKey: .obscuredBy)
        url = try box.decodeIfPresent(String.self, forKey: .url) ?? ""
        submitControl = try box.decodeIfPresent(WebActionRawControl.self, forKey: .submitControl)
    }
}

/// The form's default submit button, described and not pressed.
nonisolated struct WebActionRawControl: Decodable {
    var id = 0
    var role = ""
    var name = ""
    var tag = ""
    var type: String?
    var href = false
    var nav = false
    var form = true

    init() {}

    init(from decoder: any Decoder) throws {
        enum Key: String, CodingKey { case id, role, name, tag, type, href, nav, form }
        let box = try decoder.container(keyedBy: Key.self)
        id = try box.decodeIfPresent(Int.self, forKey: .id) ?? 0
        role = try box.decodeIfPresent(String.self, forKey: .role) ?? ""
        name = try box.decodeIfPresent(String.self, forKey: .name) ?? ""
        tag = try box.decodeIfPresent(String.self, forKey: .tag) ?? ""
        type = try box.decodeIfPresent(String.self, forKey: .type)
        href = try box.decodeIfPresent(Bool.self, forKey: .href) ?? false
        nav = try box.decodeIfPresent(Bool.self, forKey: .nav) ?? false
        form = try box.decodeIfPresent(Bool.self, forKey: .form) ?? true
    }
}

nonisolated struct WebActionRawFire: Decodable {
    var ok = false
    var reason = ""
    var doc = ""
    var urlBefore = ""
    var hit = ""
    var obscuredBy: String?
    var valueAfter: String?
    var submitted: Bool?
    var submitButtonClicked: Bool?
    var nameNow: String?

    private enum CodingKeys: String, CodingKey {
        case ok, reason, doc, hit, submitted
        case urlBefore = "url_before"
        case obscuredBy = "obscured_by"
        case valueAfter = "value_after"
        case submitButtonClicked = "submit_button_clicked"
        case nameNow = "name_now"
    }

    init() {}

    init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        ok = try box.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        reason = try box.decodeIfPresent(String.self, forKey: .reason) ?? ""
        doc = try box.decodeIfPresent(String.self, forKey: .doc) ?? ""
        urlBefore = try box.decodeIfPresent(String.self, forKey: .urlBefore) ?? ""
        hit = try box.decodeIfPresent(String.self, forKey: .hit) ?? ""
        obscuredBy = try box.decodeIfPresent(String.self, forKey: .obscuredBy)
        valueAfter = try box.decodeIfPresent(String.self, forKey: .valueAfter)
        submitted = try box.decodeIfPresent(Bool.self, forKey: .submitted)
        submitButtonClicked = try box.decodeIfPresent(Bool.self, forKey: .submitButtonClicked)
        nameNow = try box.decodeIfPresent(String.self, forKey: .nameNow)
    }
}

nonisolated struct WebActionRawPoll: Decodable {
    var ok = false
    var reason = ""
    var doc = ""
    var mutations = 0
    var elapsedMS = 0
    var sinceLastMS = 0
    var url = ""
    var urlChanged = false

    private enum CodingKeys: String, CodingKey {
        case ok, reason, doc, mutations, url
        case elapsedMS = "elapsed_ms"
        case sinceLastMS = "since_last_ms"
        case urlChanged = "url_changed"
    }

    init() {}

    init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        ok = try box.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        reason = try box.decodeIfPresent(String.self, forKey: .reason) ?? ""
        doc = try box.decodeIfPresent(String.self, forKey: .doc) ?? ""
        mutations = try box.decodeIfPresent(Int.self, forKey: .mutations) ?? 0
        elapsedMS = try box.decodeIfPresent(Int.self, forKey: .elapsedMS) ?? 0
        sinceLastMS = try box.decodeIfPresent(Int.self, forKey: .sinceLastMS) ?? 0
        url = try box.decodeIfPresent(String.self, forKey: .url) ?? ""
        urlChanged = try box.decodeIfPresent(Bool.self, forKey: .urlChanged) ?? false
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
