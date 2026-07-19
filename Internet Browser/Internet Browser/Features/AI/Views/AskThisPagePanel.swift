//
//  AskThisPagePanel.swift
//  Cherry Browser
//

import SwiftUI
import WebKit

/// Trailing side panel for on-device page Q&A, (when more than the current
/// page is selected in the tab picker) cited research over the chosen open
/// tabs, and (when the tab selection is empty) a general ungrounded chat
/// with the current engine. Mirrors `ViewSourcePanel`'s shape (fixed-width
/// trailing panel with a header bar + dismiss button) since it's the closest
/// existing precedent for a panel driven by pre-fetched page content — but
/// unlike that panel, the page snapshot here is LIVE: while open, single-page
/// mode follows navigations and tab switches, and research mode re-gathers a
/// selected tab whose content changed (see the follow/refresh tasks in body).
struct AskThisPagePanel: View {
    let tabManager: TabManager
    let onDismiss: () -> Void

    /// LIVE snapshot of the page the single-page chat is grounded on. Seeded
    /// from the extraction done when the panel opened, then re-extracted while
    /// the panel is open so the chat follows the live page: when the active
    /// tab finishes a navigation and when the user switches browser tabs (see
    /// the `pageFollowKey` task). Only refreshed while the selection is
    /// single-page-shaped — research and general chat don't ground on it.
    @State private var pageTitle: String
    @State private var pageText: String
    /// The tab `pageTitle`/`pageText` were extracted from. Compared against
    /// `activeTabID` so the configure task can hold off grounding the chat on
    /// a stale snapshot while a tab switch's re-extraction is still in flight.
    @State private var snapshotTabID: UUID?

    @StateObject private var chatSession = PageChatSession()
    @StateObject private var researchSession = TabsResearchSession()
    @State private var draft: String = ""
    /// Turn IDs whose reasoning ("Thoughts") disclosure is expanded. Kept on
    /// the panel (not inside the row builder) because rows live in a ForEach —
    /// a `@State` in the row would reset on every turns-array mutation.
    @State private var expandedReasoning: Set<UUID> = []
    /// The assistant turn currently hovered, whose copy affordance is shown.
    @State private var hoveredTurnID: UUID?
    /// Briefly holds the turn just copied so its icon flips to a checkmark.
    @State private var copiedTurnID: UUID?
    /// The tabs the conversation answers from. Starts EMPTY — general chat, a
    /// direct, ungrounded conversation with the current engine — so the panel
    /// opens on the general empty state (where the web-search entry lives).
    /// Adding the active tab switches to the single-page chat; adding more
    /// switches to the research session over exactly this set.
    @State private var selectedTabIDs: Set<UUID>
    /// The focused browser tab. Kept in sync with `tabManager.selectedTabID`
    /// while the panel is open (see the `onChange` in `body`), so the header
    /// title, the active chip, and single-page routing follow tab switches.
    @State private var activeTabID: UUID?
    /// Bumped when a selected research tab finishes navigating — its indexed
    /// content is stale; the task keyed on this triggers a re-gather.
    @State private var researchRefreshCount = 0

    // MARK: Chat history state

    /// Whether the header's history popover is open.
    @State private var showHistory = false
    /// Forces the panel into the research path after reopening a saved
    /// research conversation whose transcript would otherwise be invisible
    /// (routing is selection-shaped, and the current selection may be
    /// single-page or empty). Cleared the moment the user edits the tab
    /// selection — from then on the selection's own shape routes again.
    @State private var researchRestoreOverride = false

    /// Set for the single programmatic `selectedTabIDs` change made while
    /// reopening a saved research chat, so the `.onChange` that normally clears
    /// `researchRestoreOverride` on a user edit skips that one restore change.
    @State private var suppressOverrideReset = false

    /// The reopen path's settle-then-index task, retained so a subsequent
    /// reopen (or panel dismissal) can cancel it — otherwise a stale run could
    /// index the previous chat's tabs after the new one is shown.
    @State private var researchReopenTask: Task<Void, Never>?

    // MARK: Web research agent state

    /// The single-shot web research agent's progress through its four steps.
    /// `.idle` means no agent run is active (the panel's normal state).
    private enum WebAgentPhase: Equatable {
        case idle, searching, opening
        case reading(settled: Int, total: Int)
        case indexing
        case answering

        var label: String? {
            switch self {
            case .idle: return nil
            case .searching: return "Searching the web…"
            case .opening: return "Opening results…"
            case .reading(let settled, let total):
                return total > 0 ? "Reading results (\(settled)/\(total))…" : "Reading results…"
            case .indexing: return "Indexing…"
            case .answering: return "Answering…"
            }
        }
    }

    /// When `true`, the next send runs the web research agent on the typed
    /// question instead of sending it to the current chat. One-shot: it
    /// disarms as soon as a run starts.
    @State private var webSearchArmed = false
    @State private var webAgentPhase: WebAgentPhase = .idle

    /// The status bar's label: the phase's own text, except while indexing,
    /// where the research session's live extraction counter is folded in
    /// ("Indexing (2/5)…") so the longest step visibly moves — same idea as
    /// the reading phase's settled counter. Once extraction completes, the
    /// counter reads (n/n) while the (bounded) embed step runs.
    private var webAgentStatusLabel: String? {
        if case .indexing = webAgentPhase,
           let progress = researchSession.prepareProgress, progress.totalTabs > 0 {
            return "Indexing (\(progress.extractedTabs)/\(progress.totalTabs))…"
        }
        return webAgentPhase.label
    }
    /// Friendly failure line ("Couldn't find web results for that."), shown
    /// under the status bar's slot until the next send or agent run.
    @State private var webAgentError: String?
    /// The in-flight agent run, kept so dismissing the panel cancels it.
    @State private var webAgentTask: Task<Void, Never>?
    /// Owned per-panel, like the sessions: a fresh off-screen webview is
    /// created inside each `search` call, so this holds no page state.
    @State private var webSearchService = WebSearchService()

    init(pageTitle: String, pageText: String, tabManager: TabManager, onDismiss: @escaping () -> Void) {
        _pageTitle = State(initialValue: pageTitle)
        _pageText = State(initialValue: pageText)
        self.tabManager = tabManager
        self.onDismiss = onDismiss
        let active = tabManager.selectedTabID
        _activeTabID = State(initialValue: active)
        _snapshotTabID = State(initialValue: active)
        // The panel always opens in GENERAL chat (empty selection), even when
        // the active tab has readable content: the prominent "Search the web"
        // entry lives only in the general empty state, and grounding on the
        // current page stays one tap away — the tab picker's ＋ menu lists the
        // active tab, and adding it switches to single-page mode over the
        // snapshot extracted at open (kept live by the follow task).
        _selectedTabIDs = State(initialValue: [])
    }

    private var availability: PageAIAvailability { PageAIService.availability }

    /// The selection's own shape, before the research-restore override:
    /// exactly the active tab selected → the fast single-page chat path
    /// (identical to the old "This Page" mode).
    private var isActiveTabOnlySelection: Bool {
        selectedTabIDs.count == 1 && selectedTabIDs.first == activeTabID
    }

    /// Exactly the active tab selected → the fast single-page chat path.
    /// Anything else answers via the research session over the selected set —
    /// unless the selection is general-chat-shaped (see `isGeneralChat`).
    /// A reopened research conversation overrides both non-research shapes
    /// (see `researchRestoreOverride`).
    private var isSinglePageSelection: Bool {
        !researchRestoreOverride && isActiveTabOnlySelection
    }

    /// Nothing usable to ground on → general chat: a direct conversation
    /// with the current engine, answering from the model's own knowledge.
    /// Covers an empty selection (the user removed every chip, or the panel
    /// opened on a contentless tab) and the active tab being selected while
    /// its page snapshot has no readable text.
    private var isGeneralChat: Bool {
        !researchRestoreOverride && (selectedTabIDs.isEmpty || (isActiveTabOnlySelection && pageText.isEmpty))
    }

    /// The selection shapes that answer via the research session: two or
    /// more tabs, or a single tab that isn't the active one.
    private var isResearchSelection: Bool {
        !isGeneralChat && !isSinglePageSelection
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            // The unavailable state only replaces the content when there is
            // genuinely nothing usable to show. A conversation already on
            // screen keeps running on the engine it was BUILT with (streams
            // route by concrete engine type), so switching to an unavailable
            // engine mid-conversation must not hide or kill it — the
            // "Applies to your next chat." hint covers that case, and the
            // next New Chat surfaces the unavailable view naturally.
            if !availability.isAvailable && !activePathHasTurns {
                unavailableView
            } else {
                if showsEngineSwitchHint {
                    engineSwitchHint
                    Divider()
                }
                TabSelectorBar(
                    tabManager: tabManager,
                    activeTabID: activeTabID,
                    // A snapshot from a different tab (possible in research
                    // mode, where switches move activeTabID but nothing
                    // re-extracts) must not label the new active tab's chip —
                    // empty falls back to the tab's own live title.
                    activePageTitle: isSnapshotCurrent ? pageTitle : "",
                    selectedTabIDs: $selectedTabIDs
                )
                Divider()
                if let phaseLabel = webAgentStatusLabel {
                    webAgentStatusBar(phaseLabel)
                    Divider()
                } else if let webAgentError {
                    webAgentErrorBar(webAgentError)
                    Divider()
                }
                // General chat and this-page chat are both `chatSession` —
                // they differ only in how the session was configured
                // (see the configure task below) and in the empty-state copy.
                if isGeneralChat || isSinglePageSelection {
                    chatContent
                } else {
                    researchContent
                }
            }
        }
        .frame(width: 380)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 0.5)
        }
        // Keyed on availability AS WELL as the page and the routed mode: if
        // the panel opened while the chosen engine was unavailable, the first
        // run failed its guard and `pageText` never changes for the panel's
        // life — switching to a working engine from the header menu must
        // re-run configure so the chat works without closing/reopening the
        // panel. The mode token makes general↔page transitions re-fire this
        // task; both `configure` and `configureGeneral` no-op when the
        // session is already in that exact state, so a re-fire never resets
        // a live conversation whose grounding didn't actually change (e.g.
        // general → research → general keeps the general chat).
        .task(id: chatConfigureKey) {
            guard availability.isAvailable else { return }
            // A single-page-shaped selection whose snapshot is still being
            // re-extracted (the tab just switched) must not configure on the
            // OLD tab's text — the follow task below is refreshing it, and
            // `snapshotTabID` landing re-fires this key with the right text.
            guard !isSinglePageSelection || isSnapshotCurrent else { return }
            if isGeneralChat {
                // A context switch can reset the conversation (configure
                // starts a new chat when the grounding changed) — persist the
                // one on screen first. Saving is idempotent: unchanged
                // content is skipped by the store, so re-fires cost nothing.
                saveChatConversation()
                chatSession.configureGeneral()
            } else if isSinglePageSelection {
                saveChatConversation()
                chatSession.configure(pageTitle: pageTitle, pageText: pageText, summary: nil)
            }
        }
        // Follow the live page in single-page mode: re-fires when the active
        // tab or its loading state changes — i.e. on browser tab switches and
        // when a navigation finishes (`isLoading` true→false, set by
        // `didFinish`/`didFail`). An in-flight load is waited out (the key
        // re-fires once it settles); an unchanged page extracts to identical
        // text, so the configure task above no-ops and a live conversation
        // (or in-progress stream) is never reset without a real page change.
        // Nil — task idle — in research and general mode, so a curated
        // selection or an ungrounded chat is never touched by navigations.
        .task(id: pageFollowKey) {
            guard let key = pageFollowKey, !key.isLoading else { return }
            await refreshSnapshot(for: key.tabID)
        }
        // Keep `activeTabID` tracking the focused browser tab. When the
        // selection is just the active tab (single-page mode — the default),
        // the selection FOLLOWS the switch, which re-keys the follow task
        // above into re-extracting. A curated research selection or an empty
        // (general-chat) selection is never hijacked — only the notion of
        // which tab is "active" moves with the user.
        .onChange(of: tabManager.selectedTabID) { _, newID in
            let wasFollowing = isSinglePageSelection
            activeTabID = newID
            if wasFollowing {
                if let newID {
                    selectedTabIDs = [newID]
                } else {
                    selectedTabIDs = []
                }
            }
        }
        // Research mode: a SELECTED tab finishing a navigation means its
        // indexed content is stale — trigger a re-gather. `buildIndex` caches
        // by content equality, so selected tabs that didn't actually change
        // re-index for free.
        .onChange(of: selectedTabsLoadingFingerprint) { old, new in
            guard isResearchSelection,
                  new.contains(where: { id, isLoading in !isLoading && old[id] == true })
            else { return }
            researchRefreshCount += 1
        }
        .task(id: researchRefreshCount) {
            guard researchRefreshCount > 0, isResearchSelection, availability.isAvailable else { return }
            await researchSession.prepare(tabManager: tabManager, includeTabIDs: selectedTabIDs)
        }
        // Re-gather whenever a research-shaped selection is active and the
        // selected set changes, so the index always covers exactly the chosen
        // tabs. Re-running with an unchanged content snapshot stays cheap,
        // since buildIndex caches by content equality.
        .task(id: researchGatherKey) {
            guard isResearchSelection, availability.isAvailable else { return }
            await researchSession.prepare(tabManager: tabManager, includeTabIDs: selectedTabIDs)
        }
        // A selected tab can be CLOSED while the panel is open: prune it from
        // the selection (which also retriggers the gather via the key above)
        // instead of silently keeping its stale content in the index. All
        // selected tabs closing leaves the selection empty — general chat —
        // rather than snapping back to the active tab.
        .onChange(of: openTabIDs) { _, openIDs in
            let pruned = selectedTabIDs.intersection(openIDs)
            guard pruned != selectedTabIDs else { return }
            selectedTabIDs = pruned
        }
        // The agent's last step hands off to the research session's normal
        // streaming; "Answering…" clears when that stream finishes (or is
        // stopped), returning the panel to its plain research mode. A reply
        // finishing (or being stopped with partial text) is also a history
        // save point.
        .onChange(of: researchSession.isResponding) { _, responding in
            if !responding && webAgentPhase == .answering {
                webAgentPhase = .idle
            }
            if !responding {
                saveResearchConversation()
            }
        }
        // An assistant turn finished streaming (or was stopped with partial
        // text) — persist the conversation as it now stands.
        .onChange(of: chatSession.isResponding) { _, responding in
            if !responding {
                saveChatConversation()
            }
        }
        // The user edited the tab selection — its shape routes again, and a
        // reopened research conversation stops pinning the panel to research.
        // The one programmatic change made by a research reopen is exempt.
        .onChange(of: selectedTabIDs) { _, _ in
            if suppressOverrideReset {
                suppressOverrideReset = false
                return
            }
            researchRestoreOverride = false
        }
        .onDisappear {
            webAgentTask?.cancel()
            researchReopenTask?.cancel()
            saveChatConversation()
            saveResearchConversation()
        }
    }

    // MARK: - Chat history

    /// Projects the single-page/general conversation into a history snapshot
    /// and upserts it. A no-op until the conversation has one completed
    /// user + assistant exchange (`SavedChatSession.snapshot` returns `nil`),
    /// and when nothing changed since the last save.
    private func saveChatConversation() {
        guard let snapshot = SavedChatSession.snapshot(
            id: chatSession.conversationID,
            kind: chatSession.isGeneral ? .general : .page,
            fallbackTitle: chatSession.isGeneral ? "New chat" : pageTitle,
            turns: chatSession.turns
        ) else { return }
        ChatHistoryStore.shared.upsert(snapshot)
    }

    private func saveResearchConversation() {
        guard let snapshot = SavedChatSession.snapshot(
            id: researchSession.conversationID,
            kind: .research,
            fallbackTitle: "Research chat",
            turns: researchSession.turns
        ) else { return }
        ChatHistoryStore.shared.upsert(snapshot)
    }

    /// Reopens a saved conversation from history as the current one.
    /// The transcript is always shown; continuing builds a FRESH engine for
    /// the CURRENT context, seeded with a replay of the reopened turns (the
    /// original engine state is gone — see the sessions' `restore` docs):
    /// - general: continues cleanly, nothing external needed.
    /// - page: re-grounds on the CURRENT page; with no usable page it
    ///   behaves as a general chat. The original page text is not resurrected.
    /// - research: re-grounds on the CURRENTLY selected tabs; with nothing to
    ///   index it degrades to the existing unavailable states (citation chips
    ///   stay as plain labels — a stale tabID just doesn't focus a tab). The
    ///   original result tabs are never auto-reopened.
    private func reopen(_ saved: SavedChatSession) {
        // Persist whatever is on screen before it's replaced.
        saveChatConversation()
        saveResearchConversation()
        // Cancel a still-running reopen so its late index can't ground the new
        // conversation on the previous chat's tabs.
        researchReopenTask?.cancel()

        let turns = saved.turns.map { $0.asChatTurn() }
        switch saved.kind {
        case .general:
            researchRestoreOverride = false
            selectedTabIDs = []
            chatSession.restore(id: saved.id, turns: turns, asGeneral: true, pageTitle: "", pageText: "")
        case .page:
            researchRestoreOverride = false
            if let active = activeTabID {
                selectedTabIDs = [active]
                // The panel's current snapshot, even if mid-refresh: the
                // configure/follow tasks re-ground on the live page as it
                // settles, keeping the restored transcript either way.
                chatSession.restore(id: saved.id, turns: turns, asGeneral: false, pageTitle: pageTitle, pageText: pageText)
            } else {
                selectedTabIDs = []
                chatSession.restore(id: saved.id, turns: turns, asGeneral: true, pageTitle: "", pageText: "")
            }
        case .research:
            researchSession.restore(id: saved.id, turns: turns)
            let hasSavedSourceURLs = turns.contains { turn in turn.sources.contains { $0.url != nil } }
            if hasSavedSourceURLs {
                // New chats persist their source URLs — re-open the cited pages
                // so the reopened research has live grounding again.
                reopenResearchContext(from: turns)
            } else if !selectedTabIDs.isEmpty {
                // Legacy chat (saved before source URLs were persisted) with a
                // live selection: research over whatever is currently selected.
                if !isResearchSelection { researchRestoreOverride = true }
                Task { await researchSession.prepare(tabManager: tabManager, includeTabIDs: selectedTabIDs) }
            }
            // else: legacy chat, no saved URLs and no live tabs — the transcript
            // reopens read-only; a fresh search re-establishes grounding.
        }
    }

    /// Cap on how many source pages a reopened research chat re-opens, so a
    /// long conversation (many turns × ~5 sources each) can't spawn dozens of
    /// webviews at once. ~2 runs' worth (`WebSearchService.maxResults` is 5).
    private static let reopenSourceCap = 12

    /// Re-establishes live grounding for a reopened research chat whose original
    /// source tabs are gone. Collects the chat's cited source URLs (unique,
    /// newest-turn-first, capped), reuses any that are still open live instead
    /// of duplicating them, opens the rest as background tabs in one fresh
    /// locked "AI" group, then indexes the selection. Indexing waits for the
    /// reopened pages to settle first: extraction on a still-loading page yields
    /// nothing, and these agent tabs are excluded from the staleness
    /// fingerprint, so they would otherwise never re-index on their own.
    @MainActor
    private func reopenResearchContext(from turns: [PageChatTurn]) {
        // Unique source URLs, preferring the most recent turns, capped.
        var seenURLs = Set<URL>()
        var sources: [(url: URL, title: String, tabID: UUID)] = []
        outer: for turn in turns.reversed() {
            for source in turn.sources {
                guard let url = source.url, seenURLs.insert(url).inserted else { continue }
                sources.append((url, source.title, source.tabID))
                if sources.count >= Self.reopenSourceCap { break outer }
            }
        }
        guard !sources.isEmpty else { return }

        // Reuse a source's tab only if it's still live AND still showing that
        // source page — an eligible (non-private, real web page) tab whose URL
        // still matches. This avoids duplicating an already-open source, while
        // never grounding on a private tab (which `performPrepare` filters out
        // anyway) or a tab that has since navigated elsewhere. Everything else
        // gets a fresh tab.
        var selection = Set<UUID>()
        var toOpen: [(url: URL, title: String)] = []
        for source in sources {
            let reusable = tabManager.tabs.first { tab in
                tab.url == source.url
                    && tab.webView != nil   // a sleeping tab indexes to nothing; open fresh instead
                    && !tab.isPrivate
                    && tab.internalPage == nil
                    && !tab.showHomePage
            }
            if let reusable {
                selection.insert(reusable.id)
            } else {
                toOpen.append((source.url, source.title))
            }
        }

        var openedTabs: [Tab] = []
        if !toOpen.isEmpty {
            // Cluster only the newly opened tabs into one fresh locked "AI" group.
            let group = tabManager.createAIResearchGroup()
            for item in toOpen {
                let tab = tabManager.openBackgroundResearchTab(url: item.url, title: item.title)
                tabManager.addTabToGroup(tab, group: group)
                openedTabs.append(tab)
                selection.insert(tab.id)
            }
        }

        guard !selection.isEmpty else { return }
        // Pin research mode past the `.onChange(of: selectedTabIDs)` that would
        // otherwise clear the override on this programmatic selection change —
        // needed for the edge case where the sources collapse to a single tab
        // that reads as single-page (so the restored transcript still shows).
        if selectedTabIDs != selection { suppressOverrideReset = true }
        selectedTabIDs = selection
        if !isResearchSelection { researchRestoreOverride = true }

        let idsToIndex = selection
        let tabsToSettle = openedTabs
        researchReopenTask?.cancel()
        researchReopenTask = Task { @MainActor in
            // reportsPhase: false — this isn't a web-agent run, so it must not
            // touch webAgentPhase (which would strand the search UI in .reading).
            if !tabsToSettle.isEmpty { await waitForResultLoads(of: tabsToSettle, reportsPhase: false) }
            guard !Task.isCancelled else { return }
            await researchSession.prepare(tabManager: tabManager, includeTabIDs: idsToIndex)
        }
    }

    /// Identity for the chat configure task: re-fires when the page snapshot
    /// changes, when availability flips (e.g. the user switches from an
    /// unavailable engine to a working one in the header menu), or when the
    /// routed mode changes (general ↔ page ↔ research), so entering or
    /// leaving general chat reconfigures the session.
    private struct ChatConfigureKey: Equatable {
        enum Mode { case general, page, research }
        let isAvailable: Bool
        let mode: Mode
        /// Both snapshot fields, not just the text: `PageChatSession.configure`
        /// treats a title-only change as a reconfigure trigger too, so the key
        /// must re-fire the task for either changing.
        let pageTitle: String
        let pageText: String
        /// Whether the snapshot belongs to the current active tab. In the key
        /// so a re-extraction landing with `snapshotTabID` finally matching
        /// re-fires the configure task even if the mode token didn't move.
        let isSnapshotCurrent: Bool
    }

    private var chatConfigureKey: ChatConfigureKey {
        ChatConfigureKey(
            isAvailable: availability.isAvailable,
            mode: isGeneralChat ? .general : (isSinglePageSelection ? .page : .research),
            pageTitle: pageTitle,
            pageText: pageText,
            isSnapshotCurrent: isSnapshotCurrent
        )
    }

    /// Whether `pageTitle`/`pageText` were extracted from the tab that is
    /// active right now. False only in the window between a tab switch and
    /// the follow task's re-extraction landing (or indefinitely in research/
    /// general mode, where the snapshot deliberately isn't maintained).
    private var isSnapshotCurrent: Bool {
        snapshotTabID == activeTabID
    }

    /// Identity for the single-page follow task: non-nil only while the
    /// selection is exactly the active tab, carrying that tab's identity and
    /// live loading state so tab switches and navigation-finish events each
    /// re-key the task. Discrete events only — nothing here changes
    /// per-frame, so this can't spin a re-extract loop.
    private struct PageFollowKey: Equatable {
        let tabID: UUID
        let isLoading: Bool
    }

    private var pageFollowKey: PageFollowKey? {
        guard isSinglePageSelection, let id = activeTabID,
              let tab = tabManager.tabs.first(where: { $0.id == id }) else { return nil }
        return PageFollowKey(tabID: id, isLoading: tab.isLoading)
    }

    /// `isLoading` per SELECTED tab — the research-mode staleness signal.
    /// Reading each tab's observable loading state here (during body
    /// evaluation) is what lets the `onChange` above see navigation-finish
    /// flips for tabs in the curated selection.
    private var selectedTabsLoadingFingerprint: [UUID: Bool] {
        tabManager.tabs.reduce(into: [:]) { states, tab in
            // EXCLUDE agent-opened result tabs. Heavy result pages keep
            // toggling `isLoading` (ongoing subresource/XHR loads) forever, so
            // including them made this fingerprint change on nearly every body
            // pass → `onChange` bumped `researchRefreshCount` → the
            // `.task(id:)` re-fired `prepare` (re-extract + re-embed ALL tabs)
            // → more @Published churn → an infinite main-thread task-switch
            // storm (beachball). The web agent indexes its result tabs ONCE via
            // its own explicit prepare after the load-wait; their background
            // load churn must never drive the content-staleness re-gather.
            if selectedTabIDs.contains(tab.id) && !tab.isWebResearchTab {
                states[tab.id] = tab.isLoading
            }
        }
    }

    /// Re-extracts the live snapshot from `tabID`, mirroring the open-time
    /// extraction in `BrowserViewModel.toggleAskThisPage`. A tab with nothing
    /// extractable (home page, internal cherry:// page — whose webView holds
    /// the COVERED site, not what's on screen — sleeping, or extraction
    /// failing) produces an empty snapshot, which routes to general chat
    /// exactly like opening the panel there would.
    private func refreshSnapshot(for tabID: UUID) async {
        guard let tab = tabManager.tabs.first(where: { $0.id == tabID }) else { return }
        var title = tab.displayTitle
        var text = ""
        if tab.internalPage == nil, !tab.showHomePage, let webView = tab.webView,
           let content = await PageAIService.extractPageText(from: webView) {
            if !content.title.isEmpty { title = content.title }
            text = content.text
        }
        // The follow task was re-keyed (another switch or navigation) while
        // this extraction was in flight — the newer run owns the snapshot.
        guard !Task.isCancelled else { return }
        // A TRANSIENT extraction failure (empty result) on the SAME page we're
        // actively chatting about must not erase the grounding: clobbering
        // pageText to "" flips the panel into general chat, which would wipe
        // the live single-page conversation. Keep the last good snapshot and
        // let a later successful re-extract update it. (A genuine navigation to
        // a different/blank page still updates normally — this only guards the
        // same-tab, still-have-a-conversation case.)
        if text.isEmpty, tabID == snapshotTabID, !pageText.isEmpty,
           chatSession.isResponding || !chatSession.turns.isEmpty {
            return
        }
        pageTitle = title
        pageText = text
        snapshotTabID = tabID
    }

    /// Empty for the single-page and general-chat selections (so the gather
    /// task stays idle); otherwise a stable key for the selected tab set —
    /// sorted, so only real membership changes retrigger a re-gather.
    /// Prefixed with an availability token for the same reason as
    /// `ChatConfigureKey`: a gather skipped while the engine was unavailable
    /// must re-run once a working engine is chosen.
    private var researchGatherKey: String {
        guard isResearchSelection else { return "" }
        let ids = selectedTabIDs.map(\.uuidString).sorted().joined(separator: ",")
        return "\(availability.isAvailable)|\(ids)"
    }

    /// Whether the currently routed path already has a conversation on
    /// screen — if so, the unavailable view must never replace it.
    private var activePathHasTurns: Bool {
        (isGeneralChat || isSinglePageSelection) ? !chatSession.turns.isEmpty : !researchSession.turns.isEmpty
    }

    private var openTabIDs: Set<UUID> {
        Set(tabManager.tabs.map(\.id))
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SettingsManager.shared.accentColor)

            VStack(alignment: .leading, spacing: 0) {
                Text("Ask This Page")
                    .font(.system(size: 12, weight: .semibold))
                Text(isGeneralChat ? "General chat" : pageTitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            engineMenu

            Button {
                showHistory = true
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Chat history")
            .popover(isPresented: $showHistory, arrowEdge: .bottom) {
                ChatHistoryList(store: ChatHistoryStore.shared) { saved in
                    showHistory = false
                    // Reopen on the next main-actor turn, not inside the popover's
                    // dismissal transaction: state changed while a popover is
                    // being torn down can be dropped by the presenting view, so
                    // the restored transcript wouldn't render until the next
                    // interaction (e.g. the user typing). Deferring gives reopen
                    // its own clean transaction so it renders immediately.
                    Task { @MainActor in reopen(saved) }
                }
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(height: 50)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Compact engine switcher in the header. Reflects and sets the app-wide
    /// `aiEngine` setting; the switch takes effect on the NEXT new chat (the
    /// open conversation keeps the engine it was built with — see
    /// `showsEngineSwitchHint`). Selecting Qwen while its model isn't
    /// downloaded is allowed: the panel then shows the normal
    /// "not downloaded" availability fallback, pointing at Settings.
    private var engineMenu: some View {
        Menu {
            ForEach(AIEngine.allCases) { engine in
                Button {
                    SettingsManager.shared.aiEngine = engine
                } label: {
                    if engine == SettingsManager.shared.aiEngine {
                        Label(engine.rawValue, systemImage: "checkmark")
                    } else {
                        Text(engine.rawValue)
                    }
                }
            }
            if !LLMModelManager.shared.isDownloaded {
                Divider()
                Text("Qwen model not downloaded — download it in Settings")
            }
        } label: {
            HStack(spacing: 3) {
                Text(SettingsManager.shared.aiEngine.rawValue)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// True when the live engine setting differs from the engine the visible
    /// conversation was built with — i.e. the moment to tell the user the
    /// switch only applies to their next chat.
    private var showsEngineSwitchHint: Bool {
        let current = SettingsManager.shared.aiEngine
        if isGeneralChat || isSinglePageSelection {
            guard let built = chatSession.conversationEngine, !chatSession.turns.isEmpty else { return false }
            return built != current
        }
        guard let built = researchSession.conversationEngine, !researchSession.turns.isEmpty else { return false }
        return built != current
    }

    private var engineSwitchHint: some View {
        Text("Applies to your next chat.")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Fallback states

    private var unavailableMessage: String {
        switch availability {
        case .available: return ""
        case .unsupportedOS: return "Ask This Page requires macOS 26 or later."
        case .unavailable(let reason): return reason
        }
    }

    private var unavailableView: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(unavailableMessage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Ask (chat)

    private var chatContent: some View {
        VStack(spacing: 0) {
            if !chatSession.turns.isEmpty {
                chatToolbar
                Divider()
            }
            if chatSession.turns.isEmpty {
                chatEmptyState
            } else {
                chatScrollView
            }
            Divider()
            chatInputRow
        }
        .frame(maxHeight: .infinity)
    }

    private var chatToolbar: some View {
        HStack {
            Spacer()
            Button {
                saveChatConversation()
                chatSession.startNewChat()
            } label: {
                Label("New Chat", systemImage: "square.and.pencil")
                    .font(.system(size: 10.5, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(!chatSession.canSend)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var chatScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(chatSession.turns) { turn in
                        chatBubble(for: turn)
                            .id(turn.id)
                    }
                }
                .padding(14)
            }
            .onChange(of: chatSession.turns) { _, turns in
                guard let last = turns.last else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onAppear {
                if let last = chatSession.turns.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func chatBubble(for turn: PageChatTurn) -> some View {
        switch turn.role {
        case .user:
            HStack(spacing: 0) {
                Spacer(minLength: 40)
                Text(turn.text)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(SettingsManager.shared.accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                if let reasoning = turn.reasoning, !reasoning.isEmpty {
                    reasoningDisclosure(reasoning: reasoning, for: turn)
                }
                HStack(alignment: .bottom, spacing: 4) {
                    Group {
                        if turn.isStreaming && turn.text.isEmpty {
                            TypingDotsView()
                        } else {
                            Text(Self.assistantMarkdown(turn.text))
                                .font(.system(size: 13))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    if !turn.isStreaming && !turn.text.isEmpty {
                        copyButton(for: turn)
                            .opacity(hoveredTurnID == turn.id || copiedTurnID == turn.id ? 1 : 0)
                    }
                    Spacer(minLength: 36)
                }
                .onHover { hovering in
                    if hovering {
                        hoveredTurnID = turn.id
                    } else if hoveredTurnID == turn.id {
                        hoveredTurnID = nil
                    }
                }
                if !turn.sources.isEmpty {
                    sourcesFooter(turn.sources)
                }
            }

        case .error:
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11))
                Text(turn.text)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
            }
            .foregroundStyle(.red.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Copies the turn's ANSWER (never its reasoning) to the pasteboard,
    /// flipping to a checkmark briefly as feedback. Hidden until the bubble
    /// row is hovered, to stay unobtrusive.
    private func copyButton(for turn: PageChatTurn) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(turn.text, forType: .string)
            let copiedID = turn.id
            copiedTurnID = copiedID
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                if copiedTurnID == copiedID { copiedTurnID = nil }
            }
        } label: {
            Image(systemName: copiedTurnID == turn.id ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy answer")
    }

    /// Collapsible chain-of-thought control shown above a reasoning model's
    /// answer bubble. While the model is still inside its think block (no
    /// answer text yet) it reads "Thinking…" with the animated dots; once the
    /// answer starts (or the stream ends) it becomes a collapsed-by-default
    /// "Thoughts" disclosure. Engines without a think block (`reasoning ==
    /// nil`) never reach this view.
    private func reasoningDisclosure(reasoning: String, for turn: PageChatTurn) -> some View {
        let isThinking = turn.isStreaming && turn.text.isEmpty
        let isExpanded = expandedReasoning.contains(turn.id)
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                if isExpanded {
                    expandedReasoning.remove(turn.id)
                } else {
                    expandedReasoning.insert(turn.id)
                }
            } label: {
                HStack(spacing: 5) {
                    if isThinking {
                        Text("Thinking…")
                        TypingDotsView()
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                        Text("Thoughts")
                    }
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(reasoning)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.25))
                            .frame(width: 2)
                    }
            }
        }
        .padding(.leading, 2)
    }

    /// Renders assistant text as FULL markdown (headings, lists, code blocks,
    /// plus the inline styles) instead of inline-only. SwiftUI's `Text`
    /// ignores block-level `PresentationIntent`, so after parsing, the block
    /// structure is rebuilt as literal characters + inline attributes:
    /// paragraph breaks, `• ` / `N. ` list markers, semibold headings, and a
    /// monospaced font for code blocks. Falls back to plain text if parsing
    /// throws, since the model's output isn't guaranteed valid markdown.
    private static func assistantMarkdown(_ text: String) -> AttributedString {
        guard let parsed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) else {
            return AttributedString(text)
        }

        var result = AttributedString()
        var previousBlockKey: [Int]? = nil
        var previousTopIdentity: Int? = nil
        var previousListItemIdentity: Int? = nil

        // `runs[\.presentationIntent]` coalesces consecutive runs sharing an
        // intent, so each iteration is one block (inline styles inside it are
        // preserved by slicing the parsed string).
        for (intent, range) in parsed.runs[\.presentationIntent] {
            var segment = AttributedString(parsed[range])
            segment.presentationIntent = nil

            let components = intent?.components ?? []
            let blockKey = components.map(\.identity)
            let topIdentity = blockKey.last

            if blockKey != previousBlockKey {
                if !result.characters.isEmpty {
                    // Blocks sharing their outermost container (items of the
                    // same list) sit one line apart; unrelated blocks get a
                    // blank line between them.
                    let sameContainer = topIdentity != nil && topIdentity == previousTopIdentity
                    result += AttributedString(sameContainer ? "\n" : "\n\n")
                }
                // The bullet/number is printed once per list ITEM: an item
                // with several blocks (a second paragraph, a code block)
                // changes blockKey while keeping the same listItem identity —
                // its continuation blocks get matching indentation only.
                let list = listContext(for: components)
                if let itemIdentity = list.itemIdentity {
                    if itemIdentity != previousListItemIdentity {
                        result += AttributedString(list.indent + list.marker)
                    } else {
                        result += AttributedString(list.indent + String(repeating: " ", count: list.marker.count))
                    }
                }
                previousListItemIdentity = list.itemIdentity
            }

            // Components are ordered innermost-first; the LAST style found
            // (outermost) must not override an inner one, so first match wins.
            for component in components {
                switch component.kind {
                case .header(let level):
                    segment.font = .system(size: level <= 1 ? 15 : level == 2 ? 14 : 13.5, weight: .semibold)
                case .codeBlock:
                    segment.font = .system(size: 12, design: .monospaced)
                default:
                    continue
                }
                break
            }

            result += segment
            previousBlockKey = blockKey
            previousTopIdentity = topIdentity
        }
        return result
    }

    /// For a list-item block: the identity of the (innermost) `listItem` the
    /// block belongs to — distinct per item, shared by all of one item's
    /// blocks — plus its `• ` / `N. ` marker and a two-spaces-per-nesting-
    /// level indent. `itemIdentity == nil` for any non-list block. Components
    /// are ordered innermost-first, so the list container FOLLOWING a
    /// `listItem` is the one that owns it and decides bullet vs number.
    private static func listContext(
        for components: [PresentationIntent.IntentType]
    ) -> (itemIdentity: Int?, marker: String, indent: String) {
        var itemIdentity: Int? = nil
        var marker = ""
        var pendingOrdinal: Int? = nil
        var listDepth = 0
        for component in components {
            switch component.kind {
            case .listItem(let ordinal):
                if itemIdentity == nil {
                    itemIdentity = component.identity
                    pendingOrdinal = ordinal
                }
            case .unorderedList:
                listDepth += 1
                if pendingOrdinal != nil, marker.isEmpty {
                    marker = "• "
                    pendingOrdinal = nil
                }
            case .orderedList:
                listDepth += 1
                if let ordinal = pendingOrdinal, marker.isEmpty {
                    marker = "\(ordinal). "
                    pendingOrdinal = nil
                }
            default:
                break
            }
        }
        let indent = String(repeating: "  ", count: max(0, listDepth - 1))
        return (itemIdentity, marker, indent)
    }

    private let examplePrompts = [
        "Summarize the key points",
        "What are the downsides?",
        "Explain simply",
    ]

    private let generalExamplePrompts = [
        "Explain a concept",
        "Draft an email",
        "Brainstorm ideas",
    ]

    private var chatEmptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text(isGeneralChat ? "Ask anything" : "Ask anything about this page")
                .font(.system(size: 13, weight: .semibold))
            Text(isGeneralChat
                ? "Chats on-device with the selected engine. Add a tab to ground answers in a page."
                : "Answers are grounded in this page's content and generated entirely on-device.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            VStack(spacing: 6) {
                ForEach(isGeneralChat ? generalExamplePrompts : examplePrompts, id: \.self) { prompt in
                    Button {
                        chatSession.send(prompt)
                    } label: {
                        Text(prompt)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!chatSession.canSend)
                }
            }
            .padding(.top, 4)

            // The web research agent's prominent entry point: arm web-search
            // mode (or disarm it), then the typed question runs the flow.
            // Only in general chat — with a page or tabs selected, questions
            // already have grounding.
            if isGeneralChat {
                Button {
                    webSearchArmed.toggle()
                } label: {
                    Label(webSearchArmed ? "Web search on — type a question" : "Search the web",
                          systemImage: webSearchArmed ? "checkmark" : "globe")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(webSearchArmed ? .white : SettingsManager.shared.accentColor)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            webSearchArmed
                                ? AnyShapeStyle(SettingsManager.shared.accentColor)
                                : AnyShapeStyle(SettingsManager.shared.accentColor.opacity(0.12)),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .disabled(!availability.isAvailable || webAgentPhase != .idle)
                .help("Search DuckDuckGo, open the top results as tabs, and answer with citations")
                .padding(.top, 8)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
    }

    private var chatInputRow: some View {
        inputRow(
            placeholder: isGeneralChat ? "Ask anything…" : "Ask about this page…",
            canSend: chatSession.canSend,
            isResponding: chatSession.isResponding,
            onSend: sendDraft,
            onStop: { chatSession.stop() }
        )
    }

    /// Shared input row for both paths: same visuals as before, parameterized
    /// by which session is currently active so the single-page and research
    /// paths don't need two near-identical copies of the text field + send
    /// button. While a reply is streaming, the send button becomes a Stop
    /// control that cancels the generation, keeping the partial answer.
    private func inputRow(
        placeholder: String,
        canSend: Bool,
        isResponding: Bool,
        onSend: @escaping () -> Void,
        onStop: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            // Web-search toggle: reachable from every mode, so the agent can
            // be invoked mid-conversation too. While armed, the next send
            // runs the research agent on the question instead of the chat.
            Button {
                webSearchArmed.toggle()
            } label: {
                Image(systemName: "globe")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(
                        webSearchArmed
                            ? AnyShapeStyle(SettingsManager.shared.accentColor)
                            : AnyShapeStyle(.secondary)
                    )
                    .frame(width: 22, height: 22)
                    .background(
                        webSearchArmed
                            ? AnyShapeStyle(SettingsManager.shared.accentColor.opacity(0.15))
                            : AnyShapeStyle(Color.clear),
                        in: Circle()
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!availability.isAvailable || webAgentPhase != .idle)
            .help("Search the web: open the top results as tabs and answer with citations")

            TextField(webSearchArmed ? "Search the web…" : placeholder, text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                .onSubmit(onSend)
                .disabled(!canSend && !webSearchArmed)

            if isResponding {
                Button(action: onStop) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(AnyShapeStyle(SettingsManager.shared.accentColor))
                }
                .buttonStyle(.plain)
                .help("Stop generating")
            } else {
                // An armed web search bypasses the session's own gating — it
                // needs no built index or configured chat, just availability
                // (already required to arm) and no run in flight.
                let sendable = canSend || (webSearchArmed && webAgentPhase == .idle)
                Button(action: onSend) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(
                            draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !sendable
                                ? AnyShapeStyle(.secondary)
                                : AnyShapeStyle(SettingsManager.shared.accentColor)
                        )
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !sendable)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func sendDraft() {
        if webSearchArmed {
            startWebResearchFromDraft()
            return
        }
        let text = draft
        guard chatSession.canSend, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        webAgentError = nil
        chatSession.send(text)
    }

    /// A citation chip list shown under an assistant bubble that cited
    /// sources: `[N] Tab Title`, clickable to switch to that tab.
    private func sourcesFooter(_ sources: [ResearchSource]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sources")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.tertiary)
            ForEach(sources) { source in
                Button {
                    focusTab(id: source.tabID)
                } label: {
                    Text("[\(source.index)] \(source.title)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func focusTab(id: UUID) {
        guard let tab = tabManager.tabs.first(where: { $0.id == id }) else { return }
        tabManager.selectTab(tab)
    }

    // MARK: - Web research agent

    /// The bounded wait policy for the opened result tabs lives in
    /// `WebAgentLoadWait` (pure/tested). Slow stragglers aren't worth stalling
    /// the whole answer for — whatever has rendered by then gets extracted. A
    /// straggler that finishes after the cap still gets indexed: the background
    /// tab mirrors its webview's `isLoading` (`Tab.beginBackgroundLoadObservation`),
    /// so the load finishing flips `selectedTabsLoadingFingerprint` and the
    /// panel's normal staleness re-gather fires.

    private func webAgentStatusBar(_ label: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func webAgentErrorBar(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10))
            Text(message)
                .font(.system(size: 10.5))
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Consumes the typed draft as the research question and starts one
    /// agent run. Guarded to a single run at a time; arming is one-shot.
    private func startWebResearchFromDraft() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, availability.isAvailable, webAgentPhase == .idle else { return }
        draft = ""
        webSearchArmed = false
        webAgentError = nil
        webAgentTask = Task { @MainActor in
            await performWebResearch(question: question)
        }
    }

    /// The single-shot, read-only web research flow: ONE DuckDuckGo search,
    /// open the top results as real background tabs (never stealing focus),
    /// wait for them to load, index them through the existing multi-tab
    /// research pipeline, and stream a cited answer. Fetched page content
    /// only ever feeds the research session's excerpts — it is data to
    /// summarize, never instructions to act on; the agent takes no action
    /// beyond opening the result URLs.
    @MainActor
    private func performWebResearch(question: String) async {
        // Persist any live general/single-page conversation before the flow
        // flips the selection into research mode (whose configure branch saves
        // nothing) — otherwise a crash between here and the next save could
        // drop it.
        saveChatConversation()
        webAgentPhase = .searching
        // Whatever way this run exits, only "Answering…" may outlive it —
        // that phase is cleared by the isResponding onChange when the
        // stream finishes.
        defer {
            if webAgentPhase != .answering { webAgentPhase = .idle }
        }

        // Contextualize a FOLLOW-UP search: in an ongoing research conversation
        // a question like "who are its competitors?" is meaningless to a search
        // engine on its own, so anchor it on the conversation's opening subject
        // (the first user question). The answer synthesis still uses the raw
        // follow-up (the research engine keeps the prior turns), so only the
        // SEARCH query is enriched.
        let priorUserQuestions = researchSession.turns
            .filter { $0.role == .user }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let searchQuery: String = {
            guard let subject = priorUserQuestions.first,
                  !subject.isEmpty, subject != question else { return question }
            return "\(subject) \(question)"
        }()
        let results = await webSearchService.search(searchQuery)
        guard !Task.isCancelled else { return }
        guard !results.isEmpty else {
            webAgentError = "Couldn't find web results for that."
            return
        }

        webAgentPhase = .opening
        // Cluster this run's result tabs into ONE fresh locked group named
        // "AI" with the reserved color — so the run reads as a unit in the
        // tab bar instead of ~5 loose tabs. A new run makes a new group;
        // only agent-opened tabs go in, and the group dissolves through the
        // normal empty-group rule once its tabs are closed.
        let researchGroup = tabManager.createAIResearchGroup()
        let openedTabs = results.map { result in
            let tab = tabManager.openBackgroundResearchTab(url: result.url, title: result.title, snippet: result.snippet)
            tabManager.addTabToGroup(tab, group: researchGroup)
            return tab
        }
        let openedIDs = Set(openedTabs.map(\.id))
        // From here the panel is simply in research mode over these tabs:
        // chips appear, follow-ups hit the same index, and the user closes
        // the tabs (or edits the selection) whenever they like.
        selectedTabIDs = openedIDs

        webAgentPhase = .reading(settled: 0, total: openedTabs.count)
        await waitForResultLoads(of: openedTabs)
        guard !Task.isCancelled else { return }
        // Extraction + hybrid indexing is its own bounded step — a distinct
        // label (with a live extraction counter, see webAgentStatusLabel) so
        // the index build isn't mistaken for a hang on "Reading results…".
        // The build itself is budgeted: extraction is parallel and each
        // agent-opened tab's indexed text is capped (`WebAgentIndexBudget`),
        // so `prepare` normally finishes in seconds — but it's still RACED
        // against a hard timeout so no wedged page/model can pin the panel on
        // "Indexing…" forever. On expiry the build keeps running detached
        // (its result still lands in the session, upgrading the panel's
        // research mode when ready); the agent itself proceeds with whatever
        // is indexed by then, or fails with the normal message.
        webAgentPhase = .indexing
        let session = researchSession
        let manager = tabManager
        // The index build runs DETACHED and we wait for it only up to a hard
        // budget, cancellably. A structured task-group race can't bound this:
        // `withTaskGroup` awaits its children before returning, and a child
        // awaiting a non-throwing `Task`'s `.value` ignores cancellation, so
        // the group would still block on a wedged build past the timeout (and
        // ignore panel-dismiss cancellation too). Instead poll a MainActor
        // completion flag with cancellable sleeps: on timeout we leave the
        // build running (its result still lands in the session, upgrading
        // research mode when ready) and proceed with whatever is indexed; on
        // cancellation we stop and cancel the build.
        let flag = WebAgentPrepareFlag()
        let prepare = Task { @MainActor in
            await session.prepare(tabManager: manager, includeTabIDs: openedIDs)
            flag.done = true
        }
        let indexStart = ContinuousClock.now
        while !flag.done {
            if Task.isCancelled { prepare.cancel(); return }
            if ContinuousClock.now - indexStart >= WebAgentIndexBudget.prepareTimeout { break }
            try? await Task.sleep(for: .milliseconds(150))
        }
        guard !Task.isCancelled else { return }
        guard researchSession.canSend else {
            webAgentError = "Couldn't read the opened results."
            return
        }

        webAgentPhase = .answering
        researchSession.send(question)
    }

    /// Waits for the opened result tabs to settle, per `WebAgentLoadWait`'s
    /// bounded policy — polling, because these background webviews have no
    /// `WebViewWrapper` coordinator wired up (that only happens once a tab is
    /// displayed), so there's no delegate to await. Proceeds the moment all
    /// tabs settle, or once a majority has settled past a grace window, or at
    /// the hard `maxWait` cap regardless — a page that never stops loading
    /// must never hold up the answer. Updates the `.reading` phase with the
    /// live settled count so the status shows real progress, not a frozen
    /// "Reading results…". Pass `reportsPhase: false` when the caller isn't the
    /// web-agent run (e.g. re-opening a saved chat's source tabs) so it doesn't
    /// leave the panel stuck in `.reading` / disable the search buttons.
    @MainActor
    private func waitForResultLoads(of tabs: [Tab], reportsPhase: Bool = true) async {
        let total = tabs.count
        guard total > 0 else { return }
        let start = ContinuousClock.now
        // A load() call needs a beat to flip isLoading on — never sample
        // straight away, or an instant all-false reads as "done".
        while true {
            try? await Task.sleep(for: WebAgentLoadWait.pollInterval)
            guard !Task.isCancelled else { return }
            let settled = tabs.filter { $0.webView?.isLoading != true }.count
            if reportsPhase { webAgentPhase = .reading(settled: settled, total: total) }
            if WebAgentLoadWait.shouldProceed(settled: settled, total: total, elapsed: ContinuousClock.now - start) {
                // Small settle so late JS-rendered content (SPAs) has a
                // chance to land before extraction reads innerText.
                try? await Task.sleep(for: WebAgentLoadWait.settleBeat)
                return
            }
        }
    }

    // MARK: - Research (All Tabs)

    private var researchContent: some View {
        VStack(spacing: 0) {
            // Full-screen "reading tabs" only on the FIRST gather (no conversation
            // yet). A background re-gather triggered by opening/closing a tab must
            // NOT hide an existing conversation/streaming answer — the toolbar shows
            // a subtle "refreshing" hint instead (see researchToolbar).
            if researchSession.turns.isEmpty && (!researchSession.hasPrepared || researchSession.isPreparing) {
                researchPreparingView
            } else if !researchSession.canSend && researchSession.turns.isEmpty && !researchSession.isPreparing {
                researchUnavailableView
            } else {
                if !researchSession.turns.isEmpty {
                    researchToolbar
                    Divider()
                }
                if researchSession.turns.isEmpty {
                    researchEmptyState
                } else {
                    researchScrollView
                }
                Divider()
                inputRow(
                    placeholder: "Ask across these tabs…",
                    canSend: researchSession.canSend,
                    isResponding: researchSession.isResponding,
                    onSend: sendResearchDraft,
                    onStop: { researchSession.stop() }
                )
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var researchStatusLine: String {
        let included = researchSession.includedTabCount
        let skipped = researchSession.skippedTabCount
        let tabsPart = "\(included) tab\(included == 1 ? "" : "s") included"
        guard skipped > 0 else { return tabsPart }
        return "\(tabsPart) · \(skipped) skipped"
    }

    private var researchPreparingView: some View {
        VStack(spacing: 10) {
            Spacer()
            ProgressView()
            Text("Reading open tabs…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var researchUnavailableView: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No open tabs available for research.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            if researchSession.skippedTabCount > 0 {
                Text("\(researchSession.skippedTabCount) tab\(researchSession.skippedTabCount == 1 ? "" : "s") skipped (private, internal, home, or sleeping).")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            Button("Try Again") {
                Task { await researchSession.prepare(tabManager: tabManager, includeTabIDs: selectedTabIDs) }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(SettingsManager.shared.accentColor)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var researchToolbar: some View {
        HStack(spacing: 10) {
            Text(researchStatusLine)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            if researchSession.isPreparing {
                // Background re-gather (a tab opened/closed) while a conversation
                // is on screen — subtle hint instead of hiding the conversation.
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            }
            Spacer()
            Button {
                saveResearchConversation()
                // A fresh chat returns to normal selection-shaped routing —
                // drop the reopen pin so New Chat doesn't stay stuck on the
                // research path over a single-page/empty selection.
                researchRestoreOverride = false
                Task {
                    await researchSession.prepare(tabManager: tabManager, includeTabIDs: selectedTabIDs)
                    researchSession.startNewChat()
                }
            } label: {
                Label("New Chat", systemImage: "square.and.pencil")
                    .font(.system(size: 10.5, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(!researchSession.canSend)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private let researchExamplePrompts = [
        "Compare these tabs",
        "What do they have in common?",
        "Summarize each one",
    ]

    private var researchEmptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text("Ask across the selected tabs")
                .font(.system(size: 13, weight: .semibold))
            Text(researchStatusLine)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Text("Answers cite which tab each fact came from, generated entirely on-device.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            VStack(spacing: 6) {
                ForEach(researchExamplePrompts, id: \.self) { prompt in
                    Button {
                        researchSession.send(prompt)
                    } label: {
                        Text(prompt)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!researchSession.canSend)
                }
            }
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
    }

    private var researchScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(researchSession.turns) { turn in
                        chatBubble(for: turn)
                            .id(turn.id)
                    }
                }
                .padding(14)
            }
            .onChange(of: researchSession.turns) { _, turns in
                guard let last = turns.last else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onAppear {
                if let last = researchSession.turns.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private func sendResearchDraft() {
        if webSearchArmed {
            startWebResearchFromDraft()
            return
        }
        let text = draft
        guard researchSession.canSend, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        webAgentError = nil
        researchSession.send(text)
    }
}

/// The row of selected-tab chips plus a `＋` menu of every eligible open tab,
/// replacing the old This Page / All Tabs segmented picker. The selected set
/// drives which session answers (see `isSinglePageSelection`); the active
/// tab is just a normal, default-selected member of the set.
private struct TabSelectorBar: View {
    let tabManager: TabManager
    let activeTabID: UUID?
    /// Title of the panel's page snapshot, when it belongs to the active tab
    /// — used for that tab's chip so it reads as "the current page" the chat
    /// is grounded on. Empty when the snapshot is from another tab (the chip
    /// then falls back to the tab's own live title).
    let activePageTitle: String
    @Binding var selectedTabIDs: Set<UUID>

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(selectedTabs) { tab in
                        chip(for: tab)
                    }
                }
            }
            addTabMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Selected tabs in tab-strip order, active tab first so the chip that
    /// reads as "this page" stays anchored at the leading edge.
    private var selectedTabs: [Tab] {
        let selected = tabManager.tabs.filter { selectedTabIDs.contains($0.id) }
        return selected.filter { $0.id == activeTabID } + selected.filter { $0.id != activeTabID }
    }

    /// Same eligibility as `TabsResearchSession.performPrepare`: private,
    /// internal, home-page, and sleeping (no webView) tabs can't be indexed.
    private var eligibleTabs: [Tab] {
        tabManager.tabs.filter { tab in
            !tab.isPrivate && tab.internalPage == nil && !tab.showHomePage && tab.webView != nil
        }
    }

    private func chipTitle(for tab: Tab) -> String {
        if tab.id == activeTabID, !activePageTitle.isEmpty {
            return activePageTitle
        }
        return tab.title.isEmpty ? (tab.url?.host() ?? "Untitled") : tab.title
    }

    private func chip(for tab: Tab) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(SettingsManager.shared.accentColor)
                .frame(width: 5, height: 5)
            Text(chipTitle(for: tab))
                .font(.system(size: 10.5))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 110, alignment: .leading)
            Button {
                remove(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }

    private var addTabMenu: some View {
        Menu {
            ForEach(eligibleTabs) { tab in
                Toggle(isOn: membershipBinding(for: tab.id)) {
                    Text(chipTitle(for: tab))
                        .lineLimit(1)
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(Color.primary.opacity(0.06), in: Circle())
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func membershipBinding(for tabID: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedTabIDs.contains(tabID) },
            set: { isSelected in
                if isSelected {
                    selectedTabIDs.insert(tabID)
                } else {
                    remove(tabID)
                }
            }
        )
    }

    /// Removing the last chip leaves the selection EMPTY — that's the valid
    /// general-chat state, not an error. The chips row and ＋ menu stay
    /// visible so the user can add a tab to ground the chat again.
    private func remove(_ tabID: UUID) {
        selectedTabIDs.remove(tabID)
    }
}

/// The header history button's popover: past conversations newest-first,
/// each row showing a kind icon, the title, and a relative timestamp. Tap a
/// row to reopen it; a hover-revealed trash button deletes it.
private struct ChatHistoryList: View {
    let store: ChatHistoryStore
    let onSelect: (SavedChatSession) -> Void

    @State private var hoveredID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Chat History")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            if store.sessions.isEmpty {
                Text("No past chats yet")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(store.sessions) { session in
                            row(for: session)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 300)
    }

    private func row(for session: SavedChatSession) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon(for: session.kind))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(session.updatedAt.formatted(.relative(presentation: .named)))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            if hoveredID == session.id {
                Button {
                    store.delete(id: session.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete this chat")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            hoveredID == session.id ? Color.primary.opacity(0.06) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect(session) }
        .onHover { hovering in
            if hovering {
                hoveredID = session.id
            } else if hoveredID == session.id {
                hoveredID = nil
            }
        }
    }

    private func icon(for kind: SavedChatSession.Kind) -> String {
        switch kind {
        case .page: return "doc.text"
        case .general: return "bubble.left.and.bubble.right"
        case .research: return "globe"
        }
    }
}

/// Three dots that pulse in sequence, shown while an assistant reply hasn't
/// produced any text yet.
private struct TypingDotsView: View {
    @State private var animate = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.secondary.opacity(0.6))
                    .frame(width: 6, height: 6)
                    .scaleEffect(animate ? 1.0 : 0.5)
                    .opacity(animate ? 1.0 : 0.4)
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.15),
                        value: animate
                    )
            }
        }
        .frame(height: 14)
        .onAppear { animate = true }
    }
}

/// A tiny `@MainActor`-isolated completion flag for the web agent's cancellable,
/// budgeted wait on its detached index build (see `performWebResearch`). Being
/// MainActor-isolated makes it `Sendable`, so the detached build task and the
/// polling loop only ever touch `done` on the main actor — no data race, and
/// the wait can honor cancellation (which awaiting a non-throwing `Task.value`
/// cannot).
@MainActor private final class WebAgentPrepareFlag {
    var done = false
}
