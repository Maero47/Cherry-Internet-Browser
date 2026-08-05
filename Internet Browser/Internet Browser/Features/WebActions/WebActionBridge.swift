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
    private let actionLimiter: MCPRateLimiter

    /// How many clicks and typings one Cherry will perform in a rolling minute,
    /// across every session.
    ///
    /// Generous — a person driving an agent through a form does not come close —
    /// and the point is not the number. Each action is several `evaluateJavaScript`
    /// round trips plus an observation window on the main actor, and nothing else
    /// bounded how many a grant holder could ask for in a loop.
    static let actionsPerMinute = 120

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
        auditLog: @escaping @MainActor () -> WebActionAuditLog = { WebActionAuditLog.shared },
        actionLimiter: MCPRateLimiter? = nil
    ) {
        self.browser = browser
        self.sessions = sessions
        self.auditLog = auditLog
        self.actionLimiter = actionLimiter
            ?? MCPRateLimiter(limit: Self.actionsPerMinute, window: 60)
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
            //
            // And recorded to a DIFFERENT FILE. Gate refusals are the only audit
            // entries an unauthorised caller can produce, and the log rotates at
            // a size cap — so writing them alongside granted-session actions gave
            // a token holder with no session a way to flush the record of the
            // sessions that did happen, by looping calls until rotation dropped
            // them. The actor the log exists to record was the actor who could
            // erase it. Two files, two rotations: filling one cannot touch the
            // other.
            audit.recordSessionless(Self.gateRefusalEntry(
                action: action, requester: requester, tabID: tabID, refusal: refusal
            ))
            return .refused(refusal)
        }

        let session = authorisation.session
        let tab = authorisation.tab

        // The context is built BEFORE the limiter, so a rate-limited call is
        // audited like every other refusal. It used to return `.refused` directly
        // and leave no trace — which made it the one refusal class with a live
        // session, a known tab and a known element that both file headers claimed
        // was recorded and was not. A client looping itself into the limiter is
        // exactly the behaviour a log should show.
        var context = ActionContext(
            action: action,
            session: session,
            windowID: authorisation.viewModel.windowID,
            urlBefore: tab.displayURL.mcpTruncated(to: MCPResultCaps.urlChars)
        )

        // The limiter sits AFTER the gate, deliberately. Before it, an
        // unauthorised caller could spend a budget that is not theirs and
        // rate-limit the user's own agent out of its session. After it, only a
        // grant holder can reach it, and what it bounds is main-actor JavaScript
        // evaluation in a loop.
        guard actionLimiter.allow() else {
            return refuse(
                WebActionRefusal(
                    .rateLimited,
                    "Cherry is limiting actions to \(Self.actionsPerMinute) a minute and this "
                        + "session has reached it. Wait \(actionLimiter.retryAfterSeconds()) "
                        + "seconds. If you are looping, stop and tell the user what is not working."
                ),
                context
            )
        }

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
            armed = try await describe(
                action, wantsSubmit: wantsSubmit, in: webView, authorisation
            )
        } catch {
            // Audited. `arm` touches nothing, so nothing can have happened — but
            // an action that was attempted and produced no record at all is a gap
            // in the one thing the log exists to answer.
            audit.record(context.entry(
                decision: "failed", result: "unreachable", urlAfter: nil,
                revokedMidAction: nil,
                detail: "Cherry could not reach the page to describe the element; nothing was done"
            ))
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
            fired = try await self.fire(action, token: token, armed: armed, in: webView, authorisation)
        } catch {
            // A throw here usually means the document went away mid-call, which
            // is a navigation, not a breakage — but Cherry does not know whether
            // the action landed first, and a model must not be told it did.
            //
            // THIS is the entry that must exist. By the comment above it is the
            // single situation in the whole design where an action may have
            // executed unobserved, and it was the one that left no trace at all.
            // Recorded with an explicit unknown outcome rather than as an action
            // or as a refusal, because it is neither.
            audit.record(context.entry(
                decision: "failed", result: "unknown", urlAfter: nil,
                revokedMidAction: nil,
                detail: "the page went away mid-action; Cherry cannot say whether it landed"
            ))
            return .failed(
                "Cherry lost the page while performing this action, so it cannot say whether the "
                    + "action happened. Do not retry: call read_elements to see where the tab is now."
            )
        }
        guard fired.ok else {
            return refuse(Self.fireRefusal(fired, action: action, shownName: shownName), context)
        }

        // What the page actually did with Enter, as opposed to what was asked
        // for. Recorded from here on, including on the refusal paths below.
        if case .type(_, _, _, _, _, true, _) = action {
            context.didSubmit = fired.submitButtonClicked == true
            context.submitControl = (fired.submitButtonClicked == true)
                ? armed.submitControl.map { WebActionScripts.sanitiseName($0.name) }
                : nil
        }

        // 8. Watch.
        let waited = await watchOutcome(in: webView, waitMS: action.waitMS, authorisation)
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
            // Whether a form was actually submitted through its button, not
            // whether Enter was asked for. The key events happened either way and
            // the `note` says so; this field is about the control.
            submitted: fired.submitted == true ? fired.submitButtonClicked == true : nil,
            note: Self.note(
                for: outcome, action: action, fired: fired,
                mutations: waited.mutations, origin: session.origin,
                auditFailed: audit.lastWriteFailed
            )
        ))
    }

    // MARK: - The primitives, which require the proof

    /// Describe the element and pin it. Touches nothing.
    ///
    /// Takes an `Authorisation` and does not read it. That is not decoration and
    /// it is not a comment: the parameter is what makes "you cannot reach this
    /// without a live session" a fact the compiler checks rather than a claim in
    /// a header. `Authorisation`'s initialiser is `fileprivate` and `authorise`
    /// is its only caller, so a future file that wanted a second acting path
    /// would have to add one here — visibly, in this file, next to this comment
    /// — instead of quietly assembling `WebActionScripts.arm` and an
    /// `evaluateJavaScript` of its own.
    ///
    /// What that does NOT prove, said plainly because the last report overstated
    /// it: `WebActionScripts` is `internal` and `evaluateJavaScript` is available
    /// module-wide, so nothing stops a new file from writing its own copy of this
    /// method. What is guaranteed is that such a file cannot call THIS one, and
    /// that the gate is not something a caller can forget to run before it.
    private func describe(
        _ action: WebAction,
        wantsSubmit: Bool,
        in webView: WKWebView,
        _ authorisation: Authorisation
    ) async throws -> WebActionRawArm {
        try await decode(
            WebActionRawArm.self,
            from: WebActionScripts.arm(
                id: action.element,
                expectName: action.expectName,
                document: action.document,
                wantsSubmit: wantsSubmit
            ),
            in: webView
        )
    }

    /// Act. The one method in Cherry that changes a page on a tool call's say-so.
    private func fire(
        _ action: WebAction,
        token: String,
        armed: WebActionRawArm,
        in webView: WKWebView,
        _ authorisation: Authorisation
    ) async throws -> WebActionRawFire {
        let script: String = switch action {
        case .click:
            WebActionScripts.fireClick(token: token)
        case .type(_, _, _, let text, let append, let submit, _):
            WebActionScripts.fireType(token: token, text: text, append: append, submit: submit)
        }
        return try await decode(WebActionRawFire.self, from: script, in: webView)
    }

    // MARK: - Watching

    private struct Watched {
        var mutations = 0
        var navigated = false
        var elapsedMS = 0
    }

    /// Sample the observer until the page goes quiet, navigates, or the window
    /// closes.
    private func watchOutcome(
        in webView: WKWebView,
        waitMS: Int,
        _ authorisation: Authorisation
    ) async -> Watched {
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

        // And the RAW name, against the raw name the LISTING was built from.
        //
        // The comparison above is on the display form, and the display form is
        // lossy on purpose: capped at 100 characters, `"`→`”`, `[`→`(`. So a page
        // could list a 200-character innocuous name, wait for the model to choose
        // it, rewrite the tail to "…Confirm transfer of $5,000" and rewire the
        // handler — and both sides would still sanitise to the same
        // `prefix(99) + "…"`. `Pay [now]` and `Pay (now)` collide the same way.
        //
        // `name_listed` is kept in the isolated world, which the page can neither
        // read nor write, and it is the pre-sanitisation string the row the model
        // read was rendered from. Requiring byte equality closes the collision
        // without asking the model to carry anything it was not already given.
        // (A page CAN of course change a name and get relisted — but then the
        // model is choosing from the new listing, whose row was built from the
        // new raw name and classified from it, so there is no deception left.)
        if armed.nameWasListed, armed.nameListed != armed.nameNow {
            return WebActionRefusal(
                .nameMismatch,
                "Element \(action.element) still shows as \"\(shownName)\", but its underlying name "
                    + "has changed since the listing you chose from — the visible part is the same "
                    + "and the rest is not. Nothing was done. Call read_elements again.",
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
            // THE hole the plan names as the largest in the design. Enter presses
            // a form's default submit button, so that button goes through the
            // same rule a direct click on it would.
            //
            // And when there is NO such button, Cherry does not press Enter at
            // all. That case is not an edge: Enter in a contenteditable is where
            // the modern web puts *send* — Slack, X, Discord, WhatsApp Web,
            // Gmail's compose body, none of them a `<form>` — so leaving it
            // unclassified meant the single most common irreversible action on
            // the web was the one the gate structurally could not see, while the
            // consent sheet told the user commitments were refused. A screen that
            // overstates its own coverage is the failure this refusal exists to
            // prevent.
            if submit {
                guard let control = armed.submitControl else {
                    return WebActionRefusal(
                        .unclassifiableSubmit,
                        "Cherry will not press Enter in \"\(shownName)\" because it cannot see what "
                            + "Enter would do there: this field is not in a form with a submit "
                            + "button, so the key goes straight to the page's own handler and "
                            + "there is nothing for Cherry's commitment check to look at. In a "
                            + "message composer that handler is usually Send. Type without "
                            + "submit: true, call read_elements, and click the control you can "
                            + "see — that one does go through the check.",
                        element: action.element,
                        name: shownName
                    )
                }
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
        // `submit: true` only reaches here having found a default button AND
        // cleared it through the commitment rule, so a button that was not
        // pressed means the page moved it under Cherry between the check and the
        // keystroke. Said out loud: "Enter was pressed and the form was not
        // submitted" is a different fact from "the form was submitted", and a
        // model told the second stops watching.
        // Only when the page did NOT then do something itself. A search box that
        // calls preventDefault and navigates has submitted; telling a model "the
        // form is probably not submitted" while handing it `outcome: navigated`
        // would be Cherry contradicting itself in one payload.
        if case .type(_, _, _, _, _, true, _) = action,
           fired.submitButtonClicked != true,
           outcome != .navigated {
            let because = switch fired.submitNotPressed {
            case "submit_renamed": "its name changed in the instant before Cherry pressed it"
            case "submit_detached": "it was removed from the page in that instant"
            case "submit_displaced": "the page put a different submit button ahead of it in that instant"
            case "submit_cancelled": "the page's own Enter handler cancelled the keystroke"
            default: "there was nothing left to press"
            }
            parts.append("Enter was pressed but the form's button was NOT — \(because), so Cherry "
                + "did not press a control it had not checked. Do not assume the form was "
                + "submitted; read the elements again")
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

        /// Whether a form's submit button was ACTUALLY pressed, and which one.
        ///
        /// Both nil until `fire` has answered. `submitted` used to be read
        /// straight off the request — `if case .type(…, submit, …)` — so every
        /// entry for a `submit: true` call said `"submitted":true`, including the
        /// scenario `testAButtonTheEnterHandlerInsertsIsNotThePressedOne` exists
        /// for, where Cherry correctly presses nothing. The log recorded the
        /// intention and called it the outcome, which is the one thing a log must
        /// never do.
        ///
        /// `submitControl` is the other half: a real submit is the one action
        /// that commits through a control the entry otherwise never names. The
        /// field, the form and its method were all recorded; the button that was
        /// pressed was not.
        var didSubmit: Bool?
        var submitControl: String?

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
                submitted: didSubmit,
                submitControl: submitControl,
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

    /// Whether this element's accessible name IS its own editable contents.
    ///
    /// The name ladder's fourth rung is `el.innerText`. On a plain control that
    /// is a label; on a `contenteditable` it is whatever was last typed into it,
    /// which after one `type_text` is the agent's own text. `WebActionAuditEntry`
    /// having no field for typed text is true of its SHAPE and was not true of
    /// its contents: type into a composer, act on the same element again, and the
    /// name written to the log is the previous message.
    ///
    /// The test is the RUNG and the HOST rather than the tag, so it covers any
    /// editable element whose name is its own contents. It does NOT cover a page
    /// that mirrors a field's contents into another control's `aria-label` — that
    /// is the `aria-label` rung on a non-editable element and it is recorded.
    /// Withholding every `aria-label`-derived name would empty the log of the
    /// identities it exists to hold; the edge is stated in this file's header and
    /// in the report rather than quietly claimed as covered.
    nonisolated static func nameIsOwnContents(_ armed: WebActionRawArm) -> Bool {
        armed.editable && armed.nameFrom == "text"
    }

    /// What the audit log records instead. Deliberately a sentence and not an
    /// empty string: "this was withheld, and why" is a different fact from "this
    /// element had no name", and a log that cannot tell them apart is a log that
    /// reads wrong in the one situation it exists for.
    static let withheldName = "(withheld: this element's name is its own editable contents)"

    private static func auditIdentity(_ armed: WebActionRawArm, element: Int, name: String) -> AuditIdentity {
        AuditIdentity(
            element: element,
            role: armed.role ?? "",
            name: nameIsOwnContents(armed) ? withheldName : name,
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

    /// Which rung of the accessible-name ladder produced `nameNow`. `"text"` on
    /// an editable host means the name IS the element's own contents.
    var nameFrom = ""

    /// The raw name the most recent listing of this id was built from, and
    /// whether there was one. The identity `expect_name` cannot be — see
    /// `A.names` in `WebActionScripts`.
    var nameListed: String?
    var nameWasListed = false

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
        case nameFrom = "name_from"
        case nameListed = "name_listed"
        case nameWasListed = "name_was_listed"
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
        nameFrom = try box.decodeIfPresent(String.self, forKey: .nameFrom) ?? ""
        nameListed = try box.decodeIfPresent(String.self, forKey: .nameListed)
        nameWasListed = try box.decodeIfPresent(Bool.self, forKey: .nameWasListed) ?? false
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

    /// Why the pinned submit button was NOT pressed, when it was not:
    /// `submit_detached`, `submit_renamed`, `submit_displaced`,
    /// `no_pinned_button`. Reported rather than swallowed, because "Enter was
    /// pressed and the button was not" is a different fact from "the form was
    /// submitted", and a model told the second would stop watching.
    var submitNotPressed: String?

    var nameNow: String?

    private enum CodingKeys: String, CodingKey {
        case ok, reason, doc, hit, submitted
        case urlBefore = "url_before"
        case obscuredBy = "obscured_by"
        case valueAfter = "value_after"
        case submitButtonClicked = "submit_button_clicked"
        case submitNotPressed = "submit_not_pressed"
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
        submitNotPressed = try box.decodeIfPresent(String.self, forKey: .submitNotPressed)
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
