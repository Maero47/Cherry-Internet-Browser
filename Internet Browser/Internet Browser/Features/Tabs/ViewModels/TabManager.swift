//
//  TabManager.swift
//  Internet Browser
//

import SwiftUI
import WebKit
import Observation

@Observable
final class TabManager {
    var tabs: [Tab] = []
    var selectedTabID: UUID?
    private(set) var recentlyClosedTabs: [ClosedTab] = []
    private(set) var tabGroups: [TabGroup] = []

    /// Split view state (Milestone 1: two panes, no persistence across sessions)
    var secondarySelectedTabID: UUID? = nil
    var focusedPaneIsSecondary: Bool = false

    /// Shared drag state for native drag-and-drop across windows
    static var draggedTabID: UUID?
    /// Set by DragGesture reorder so the onDrop fallback doesn't double-reorder
    static var reorderedByGesture: Bool = false

    // MARK: - Drag Sessions

    /// Monotonic id of the newest tab-drag gesture; 0 means "no drag has ever
    /// run", and is never a live session.
    ///
    /// `draggedTabID` deliberately outlives the gesture that set it, because a
    /// cross-window `onDrop` only arrives after the gesture ends — so the bars
    /// clear it on a 0.4 s timer as a fallback. That timer used to be
    /// unconditional: a drag started inside another drag's 0.4 s window had its
    /// shared state wiped out from under it. Tokens make ownership explicit —
    /// a deferred cleanup only fires while its own session is still the newest.
    private(set) static var dragSessionToken: Int = 0

    /// Opens a drag session for `tabID` and returns its token.
    @discardableResult
    static func beginDragSession(for tabID: UUID) -> Int {
        dragSessionToken &+= 1
        if dragSessionToken == 0 { dragSessionToken = 1 } // 0 is reserved
        draggedTabID = tabID
        reorderedByGesture = false
        return dragSessionToken
    }

    /// The gesture ended. Keeps `draggedTabID` readable for a late drop, and
    /// records that the gesture already did the reordering so the drop fallback
    /// doesn't move the tab a second time.
    static func endDragSession(_ token: Int) {
        guard token != 0, token == dragSessionToken else { return }
        reorderedByGesture = true
    }

    /// Clears the shared drag state, but only if `token` is still the live
    /// session — a stale token (its drag was superseded) is ignored.
    static func clearDragSession(_ token: Int) {
        guard token != 0, token == dragSessionToken else { return }
        draggedTabID = nil
        reorderedByGesture = false
    }

    /// The NSWindow this manager's tabs live in. Set by BrowserView's window
    /// registrar. When the last tab leaves (close OR cross-window transfer) we
    /// must close THIS window — not `NSApp.keyWindow`, which during a drag-drop
    /// is often the destination window, causing the wrong window to close.
    @ObservationIgnored weak var hostWindow: NSWindow?

    private let maxRecentlyClosedTabs = 25
    private var sleepTimer: Timer?

    var selectedTab: Tab? {
        guard let id = selectedTabID else { return nil }
        return tabs.first { $0.id == id }
    }

    // MARK: - App Termination

    /// The facts about an `NSWindow` that decide whether it should keep the app
    /// running. Split out from `NSWindow` so the policy below is pure and
    /// testable.
    struct WindowLiveness: Equatable {
        /// `NSWindow.isVisible` — on screen, even if obscured. FALSE for a
        /// window the user minimised to the Dock, and false once closed.
        let isVisible: Bool
        /// `NSWindow.isMiniaturized` — sitting in the Dock, tabs and all.
        let isMiniaturized: Bool
        /// Has a title bar. Together with `isPanel` this is how a real
        /// user-facing window is told apart from the app's helper windows —
        /// the tear-off ghost, the hover preview and the off-screen research
        /// host are all `.borderless`, so none of them are titled.
        ///
        /// Deliberately NOT `canBecomeMain`: AppKit's default implementation
        /// returns true only while the window is VISIBLE, and a minimised
        /// window is not visible — that is the entire premise of the bug — so
        /// any window that doesn't override it (notably the app's first window,
        /// which comes from the SwiftUI `WindowGroup`) would report false and
        /// be treated as gone.
        let isTitled: Bool
        /// Panels (save/print/alert/system popovers) are never the user's
        /// browsing windows and must not hold the app open on their own.
        let isPanel: Bool

        init(isVisible: Bool, isMiniaturized: Bool, isTitled: Bool, isPanel: Bool) {
            self.isVisible = isVisible
            self.isMiniaturized = isMiniaturized
            self.isTitled = isTitled
            self.isPanel = isPanel
        }

        init(_ window: NSWindow) {
            self.init(
                isVisible: window.isVisible,
                isMiniaturized: window.isMiniaturized,
                isTitled: window.styleMask.contains(.titled),
                isPanel: window is NSPanel
            )
        }

        /// A real user-facing window that still holds the user's tabs, whether
        /// it is on screen, minimised in the Dock, or off screen only because
        /// the whole app is hidden.
        ///
        /// `isVisible` has TWO traps, and both are the same data-loss bug:
        /// it is false for a minimised window, and it is false for *every*
        /// window while the application is hidden (⌘H). A tab closed from a
        /// non-UI path while the app is hidden would otherwise look like the
        /// last window closing and take every hidden window's tabs with it.
        /// While hidden the app therefore never quits itself; it quits on the
        /// next close once the user brings it back.
        func keepsAppAlive(appIsHidden: Bool) -> Bool {
            isTitled && !isPanel && (isVisible || isMiniaturized || appIsHidden)
        }
    }

    /// Whether closing a window should also quit the app.
    ///
    /// The old check was `NSApp.windows.filter(\.isVisible).isEmpty`, and
    /// `isVisible` is FALSE for a minimised window — so closing the last tab of
    /// window A terminated the app while window B sat in the Dock with open
    /// tabs, losing them. Minimised windows now count, and only real windows
    /// (titled, not a panel) are counted at all, so closing the truly last
    /// window still quits.
    nonisolated static func shouldTerminateApp(
        windows: [WindowLiveness], appIsHidden: Bool = false
    ) -> Bool {
        !windows.contains { $0.keepsAppAlive(appIsHidden: appIsHidden) }
    }

    /// Terminates the app if no window is left that should keep it alive.
    /// Called after the manager closes its own (now tabless) window.
    private static func terminateIfNoWindowsRemain() {
        let shouldTerminate = shouldTerminateApp(
            windows: NSApp.windows.map(WindowLiveness.init),
            appIsHidden: NSApp.isHidden
        )
        if shouldTerminate {
            NSApp.terminate(nil)
        }
    }

    /// `TabManager` isn't formally `@MainActor`-isolated but is only ever used
    /// from the main thread (SwiftUI/AppKit UI code) — this asserts that fact
    /// so it can call into the `@MainActor`-isolated `ExtensionManager`. Skips
    /// the notification entirely for private tabs: extensions have no access
    /// to private browsing in v1a, so they must never learn a private tab
    /// even exists via open/close/activate events.
    private func notifyExtensionManager(for tab: Tab, _ body: @MainActor () -> Void) {
        guard !tab.isPrivate else { return }
        MainActor.assumeIsolated(body)
    }

    var selectedTabIndex: Int? {
        guard let id = selectedTabID else { return nil }
        return tabs.firstIndex { $0.id == id }
    }

    var secondarySelectedTab: Tab? {
        guard let id = secondarySelectedTabID else { return nil }
        return tabs.first { $0.id == id }
    }

    var isSplitActive: Bool { secondarySelectedTabID != nil }

    var focusedTab: Tab? {
        focusedPaneIsSecondary ? secondarySelectedTab : selectedTab
    }

    // MARK: - Split View

    /// Opens split view with `secondaryTabID` as the secondary (right) pane.
    /// No-op if that tab doesn't exist. The secondary pane is never allowed to
    /// show the same tab as the primary (selected) pane — that would mount
    /// one Tab's single `webView` into two view hierarchies at once and break
    /// rendering. If the requested secondary IS the current primary tab,
    /// falls back to an adjacent tab instead (or no-ops if it's the only tab).
    func openSplit(with secondaryTabID: UUID) {
        guard tabs.contains(where: { $0.id == secondaryTabID }) else { return }
        if secondaryTabID == selectedTabID {
            if tabs.count > 1, let index = selectedTabIndex {
                let nextIndex = (index + 1) % tabs.count
                secondarySelectedTabID = tabs[nextIndex].id
            } else {
                // Only one tab open — create a fresh home-page tab for the
                // secondary pane so "Open in Split View" on the lone tab still
                // opens a working two-pane split instead of silently no-op'ing.
                let newSecondary = newTab(switchTo: false)
                newSecondary.isPrivate = tabs.first?.isPrivate ?? false
                secondarySelectedTabID = newSecondary.id
            }
        } else {
            secondarySelectedTabID = secondaryTabID
        }
        focusedPaneIsSecondary = false
    }

    func closeSplit() {
        secondarySelectedTabID = nil
        focusedPaneIsSecondary = false
    }

    init(createDefaultTab: Bool = true) {
        if createDefaultTab {
            let initialTab = Tab()
            tabs.append(initialTab)
            selectedTabID = initialTab.id
        }
        startSleepTimer()
    }

    deinit {
        // The run loop retains scheduled timers; without invalidation the
        // timer of every closed window's TabManager keeps firing forever.
        sleepTimer?.invalidate()
    }

    // MARK: - Tab Transfer (cross-window)

    /// Remove a tab without closing it — preserves webview state for transfer
    func removeTab(_ tab: Tab) -> Tab? {
        guard let index = tabs.firstIndex(of: tab) else { return nil }

        // Split fix-up: removing the secondary pane's tab exits split cleanly.
        if secondarySelectedTabID == tab.id {
            secondarySelectedTabID = nil
            focusedPaneIsSecondary = false
        }
        // Split fix-up: removing the primary tab while split is active promotes
        // the secondary tab to primary instead of leaving a dangling secondary.
        let promotedTabID: UUID? = (isSplitActive && selectedTabID == tab.id) ? secondarySelectedTabID : nil

        // The tab is moving to another TabManager — if its webview is parked
        // in THIS manager's off-screen research host, release it so the host
        // (whose lifetime tracks this manager) never outlives its claim on a
        // transferred webview. The webview stays alive via tab.webView and
        // reparents into the destination's hierarchy when displayed.
        detachFromResearchHost(tab.webView)

        // The tab is moving to another window, not disappearing — windowIsClosing
        // is false even when this empties the source window; that window's own
        // close is announced separately via ExtensionManager.windowClosed.
        notifyExtensionManager(for: tab) { ExtensionManager.shared.tabClosed(tab, windowIsClosing: false) }

        tabs.remove(at: index)

        if tabs.isEmpty {
            // Close THIS manager's window (the emptied source), not keyWindow —
            // during a cross-window drag keyWindow is often the drop target.
            if let window = hostWindow ?? NSApp.keyWindow {
                window.close()
            }
            Self.terminateIfNoWindowsRemain()
            return tab
        } else if let promotedTabID {
            selectedTabID = promotedTabID
            secondarySelectedTabID = nil
            focusedPaneIsSecondary = false
        } else if selectedTabID == tab.id {
            let newIndex = min(index, tabs.count - 1)
            selectedTabID = tabs[newIndex].id
        }
        return tab
    }

    /// Add an existing tab (transferred from another window)
    func addExistingTab(_ tab: Tab, switchTo: Bool = true) {
        let previous = selectedTab
        tabs.append(tab)
        notifyExtensionManager(for: tab) { ExtensionManager.shared.tabOpened(tab) }
        if switchTo {
            selectedTabID = tab.id
            notifyExtensionManager(for: tab) { ExtensionManager.shared.tabActivated(tab, previous: previous) }
        }
    }

    // MARK: - Tab CRUD

    @discardableResult
    func newTab(url: URL? = nil, switchTo: Bool = true) -> Tab {
        let previous = selectedTab
        let tab = Tab(url: url)
        tabs.append(tab)
        notifyExtensionManager(for: tab) { ExtensionManager.shared.tabOpened(tab) }
        if switchTo {
            selectedTabID = tab.id
            notifyExtensionManager(for: tab) { ExtensionManager.shared.tabActivated(tab, previous: previous) }
        }
        return tab
    }

    /// Opens `url` as a real background tab that starts loading IMMEDIATELY.
    /// A plain `newTab(url:switchTo:false)` stays inert until selected —
    /// only the displayed tab gets a `WebViewWrapper`, which is what normally
    /// creates the web view — so the research agent creates the web view
    /// here and kicks off the load itself. The user's focused tab is never
    /// changed; the tab just appears in the tab bar, and selecting it later
    /// makes `WebViewWrapper` adopt this web view as-is (the same path an
    /// opened popup takes). The configuration mirrors the wrapper's
    /// load-relevant pieces (Safari UA, JS setting, HTTPS upgrade, ad-block
    /// rules); the interactive extras (autofill, devtools bridges) only
    /// matter once the user is looking at the tab and are skipped, exactly
    /// like adopted popups skip them.
    @discardableResult
    func openBackgroundResearchTab(url: URL, title: String, snippet: String = "") -> Tab {
        let tab = newTab(url: url, switchTo: false)
        // Mark it as agent-opened so the research indexer applies the web
        // agent's per-tab index budget to it (see `WebAgentIndexBudget`).
        tab.isWebResearchTab = true
        // Keep the search snippet as a fallback source if the page itself
        // can't be extracted (bot-gated/heavy result pages).
        tab.webResearchSnippet = snippet.isEmpty ? nil : snippet
        // Seed the tab-bar title from the search result; the page's real
        // title takes over via KVO once the tab is selected and adopted.
        if !title.isEmpty {
            tab.title = title
        }

        let settings = SettingsManager.shared
        let configuration = WKWebViewConfiguration()
        configuration.applicationNameForUserAgent = "Version/18.3 Safari/605.1.15"
        configuration.defaultWebpagePreferences.allowsContentJavaScript = settings.enableJavaScript
        if settings.httpsOnlyMode {
            configuration.upgradeKnownHostsToHTTPS = true
        }
        if settings.adBlockEnabled && !settings.isAdBlockPaused(for: url) {
            let adBlocker = AdBlockManager.shared
            if adBlocker.rulesReady {
                adBlocker.applyRules(to: configuration)
            }
            adBlocker.applyCosmeticRules(to: configuration)
        }

        // A real (off-screen) viewport, never `.zero`: WebKit lays the page
        // out against the view's size, and at 0×0 every element collapses to
        // an empty box — `innerText` (what `PageAIExtractor` reads) comes
        // back "" for the whole page and the tab counts as an extraction
        // failure. Same frame as `WebSearchService`'s never-displayed webview,
        // which extracts fine for exactly this reason.
        let webView = CherryWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768), configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.tabID = tab.id
        tab.adoptWebView(webView)
        // Park it in the shared off-screen host so it also has a window-backed
        // view hierarchy — a view in no window at all is where WebKit throttles
        // rendering work hardest, and result pages should render like pages.
        attachToResearchHost(webView)
        // With no wrapper coordinator until the tab is displayed, the tab
        // mirrors url/title/isLoading itself: the tab bar gets a live
        // spinner/title, redirects land in `tab.url` (so adoption won't
        // reload the stale seed URL), and the research panel can see the
        // load finish. Torn down when `WebViewWrapper` adopts the webview.
        tab.beginBackgroundLoadObservation()
        webView.load(URLRequest(url: url))
        return tab
    }

    // MARK: - Background research webview host

    /// Never-shown window that parks agent-opened research webviews while
    /// they load (`openBackgroundResearchTab`), so WebKit treats them as
    /// real, window-attached views and keeps scheduling layout/rendering —
    /// a non-zero frame alone can still be render-throttled for a view in
    /// no window. Borderless, transparent, and never ordered on screen:
    /// nothing flashes, `isVisible` stays false (so the "no visible windows
    /// → quit" checks in close paths never count it), and it holds no key
    /// or main status. One shared host per TabManager, created lazily and
    /// released with the manager. Webviews leave it automatically when
    /// `WebViewWrapper` adopts them (AppKit reparents on addSubview) and
    /// explicitly via `detachFromResearchHost` on close/transfer/sleep, so
    /// the host never keeps a dead webview alive.
    @ObservationIgnored private var researchWebViewHost: NSWindow?

    private func attachToResearchHost(_ webView: NSView) {
        let host: NSWindow
        if let existing = researchWebViewHost {
            host = existing
        } else {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.isExcludedFromWindowsMenu = true
            window.ignoresMouseEvents = true
            // Defense-in-depth: even if something ever ordered it in, an
            // alpha-0 window paints nothing and stays !isVisible.
            window.alphaValue = 0
            researchWebViewHost = window
            host = window
        }
        host.contentView?.addSubview(webView)
    }

    /// Removes `webView` from the research host if it is parked there.
    /// Safe on any webview — displayed ones live in a browser window's
    /// hierarchy, not the host, and are left alone.
    private func detachFromResearchHost(_ webView: NSView?) {
        guard let webView, webView.window === researchWebViewHost else { return }
        webView.removeFromSuperview()
    }

    func closeTab(_ tab: Tab) {
        guard let index = tabs.firstIndex(of: tab) else { return }

        // Save to recently closed
        let closedTab = ClosedTab(url: tab.url, title: tab.title)
        recentlyClosedTabs.insert(closedTab, at: 0)
        if recentlyClosedTabs.count > maxRecentlyClosedTabs {
            recentlyClosedTabs.removeLast()
        }

        // Stop media and release the webView before removing the tab. End any
        // background-load mirroring first so the blanking below can't write
        // about:blank state back onto the closing tab. If it's a parked
        // research webview, pull it out of the off-screen host too — the
        // host's view hierarchy must not keep the closed webview alive.
        tab.endBackgroundLoadObservation()
        detachFromResearchHost(tab.webView)
        tab.webView?.stopLoading()
        tab.webView?.loadHTMLString("", baseURL: nil)
        tab.webView = nil

        // Split fix-up: closing the secondary pane's tab exits split cleanly.
        if secondarySelectedTabID == tab.id {
            secondarySelectedTabID = nil
            focusedPaneIsSecondary = false
        }
        // Split fix-up: closing the primary tab while split is active promotes
        // the secondary tab to primary instead of leaving a dangling secondary.
        let promotedTabID: UUID? = (isSplitActive && selectedTabID == tab.id) ? secondarySelectedTabID : nil

        notifyExtensionManager(for: tab) { ExtensionManager.shared.tabClosed(tab, windowIsClosing: tabs.count == 1) }

        // Remove the tab
        tabs.remove(at: index)

        // Closing a group's last tab dissolves the group, matching the
        // empty-group rule `removeTabFromGroup` applies.
        if let group = tab.group {
            tab.group = nil
            removeGroupIfEmpty(group)
        }

        // Handle selection
        if tabs.isEmpty {
            // Close this manager's own window when its last tab is closed —
            // hostWindow, not keyWindow (which may be a different focused window).
            if let window = hostWindow ?? NSApp.keyWindow {
                window.close()
            }
            // If no window is left that should keep the app alive, quit
            Self.terminateIfNoWindowsRemain()
            return
        } else if let promotedTabID {
            selectedTabID = promotedTabID
            secondarySelectedTabID = nil
            focusedPaneIsSecondary = false
        } else if selectedTabID == tab.id {
            let newIndex = min(index, tabs.count - 1)
            selectedTabID = tabs[newIndex].id
        }
    }

    func closeTab(at index: Int) {
        guard index >= 0 && index < tabs.count else { return }
        closeTab(tabs[index])
    }

    func closeOtherTabs(_ tab: Tab) {
        let tabsToClose = tabs.filter { $0.id != tab.id }
        for t in tabsToClose {
            closeTab(t)
        }
    }

    func closeTabsToRight(of tab: Tab) {
        guard let index = tabs.firstIndex(of: tab) else { return }
        let tabsToClose = Array(tabs.suffix(from: index + 1))
        for t in tabsToClose {
            closeTab(t)
        }
    }

    // MARK: - Selection

    func selectTab(_ tab: Tab) {
        // Wake sleeping tabs when selected
        if tab.isSleeping {
            tab.wake()
        }
        tab.lastActiveDate = Date()

        let previous = selectedTab

        // Selecting the tab currently shown in the secondary pane would make
        // selectedTabID == secondarySelectedTabID — the same Tab mounted in
        // both HSplitView panes at once. Swap the panes instead: the clicked
        // tab becomes primary, the old primary takes the secondary pane.
        if isSplitActive, secondarySelectedTabID == tab.id {
            let oldPrimaryID = selectedTabID
            selectedTabID = tab.id
            secondarySelectedTabID = oldPrimaryID
            notifyExtensionManager(for: tab) { ExtensionManager.shared.tabActivated(tab, previous: previous) }
            return
        }

        selectedTabID = tab.id
        notifyExtensionManager(for: tab) { ExtensionManager.shared.tabActivated(tab, previous: previous) }
    }

    func selectTab(at index: Int) {
        guard index >= 0 && index < tabs.count else { return }
        selectTab(tabs[index])
    }

    func selectNextTab() {
        guard let currentIndex = selectedTabIndex else { return }
        let nextIndex = (currentIndex + 1) % tabs.count
        selectTab(tabs[nextIndex])
    }

    func selectPreviousTab() {
        guard let currentIndex = selectedTabIndex else { return }
        let previousIndex = currentIndex > 0 ? currentIndex - 1 : tabs.count - 1
        selectTab(tabs[previousIndex])
    }

    // MARK: - Reorder

    func moveTab(from source: IndexSet, to destination: Int) {
        tabs.move(fromOffsets: source, toOffset: destination)
    }

    func moveTab(withID draggedID: UUID, toPositionOf targetID: UUID) {
        guard let sourceIndex = tabs.firstIndex(where: { $0.id == draggedID }),
              let destIndex = tabs.firstIndex(where: { $0.id == targetID }),
              sourceIndex != destIndex else { return }
        let tab = tabs.remove(at: sourceIndex)
        // The dragged tab must land AT the target's pre-move position — the
        // same result the tab bars' `tabs.move(fromOffsets:toOffset:)` reorder
        // paths produce. That is `destIndex` in BOTH directions: dragging
        // right, removing the source shifts the target down to destIndex - 1,
        // so inserting at destIndex fills exactly the slot the target vacated;
        // dragging left, nothing before destIndex moved. (A `destIndex - 1`
        // "post-removal" adjustment would land the tab one slot short of the
        // target on rightward drags.)
        tabs.insert(tab, at: min(destIndex, tabs.count))
    }

    // MARK: - Duplicate / Reopen

    func duplicateTab(_ tab: Tab) -> Tab {
        let previous = selectedTab
        let duplicate = Tab(url: tab.url, title: tab.title)
        if let index = tabs.firstIndex(of: tab) {
            tabs.insert(duplicate, at: index + 1)
        } else {
            tabs.append(duplicate)
        }
        notifyExtensionManager(for: duplicate) { ExtensionManager.shared.tabOpened(duplicate) }
        selectedTabID = duplicate.id
        notifyExtensionManager(for: duplicate) { ExtensionManager.shared.tabActivated(duplicate, previous: previous) }
        return duplicate
    }

    func reopenLastClosedTab() -> Tab? {
        guard let closedTab = recentlyClosedTabs.first else { return nil }
        recentlyClosedTabs.removeFirst()

        let previous = selectedTab
        let tab = Tab(url: closedTab.url, title: closedTab.title)
        tabs.append(tab)
        notifyExtensionManager(for: tab) { ExtensionManager.shared.tabOpened(tab) }
        selectedTabID = tab.id
        notifyExtensionManager(for: tab) { ExtensionManager.shared.tabActivated(tab, previous: previous) }
        return tab
    }

    // MARK: - Pin

    func pinTab(_ tab: Tab) {
        tab.isPinned = true
        if let index = tabs.firstIndex(of: tab) {
            let pinnedCount = tabs.filter { $0.isPinned && $0.id != tab.id }.count
            tabs.remove(at: index)
            tabs.insert(tab, at: pinnedCount)
        }
    }

    func unpinTab(_ tab: Tab) {
        tab.isPinned = false
        if let index = tabs.firstIndex(of: tab) {
            let pinnedCount = tabs.filter { $0.isPinned }.count
            tabs.remove(at: index)
            tabs.insert(tab, at: pinnedCount)
        }
    }

    // MARK: - Tab Groups

    @discardableResult
    func createGroup(name: String = "New Group", color: TabGroupColor = .blue, isLocked: Bool = false) -> TabGroup {
        let group = TabGroup(name: name, color: color, isLocked: isLocked)
        tabGroups.append(group)
        return group
    }

    /// The group an AI research run's tabs are clustered into: always named
    /// "AI" (never the query), reserved color, and locked so it can't be
    /// renamed.
    @discardableResult
    func createAIResearchGroup() -> TabGroup {
        createGroup(name: "AI", color: .aiIndigo, isLocked: true)
    }

    /// The single AI research group every AI path routes through: reuses the
    /// existing `.aiIndigo` group when one is present, else creates it. If
    /// several exist (possible only in sessions saved before creation was
    /// unified here), their members fold into the first and the extras are
    /// dropped, so the one-AI-group invariant self-heals.
    @discardableResult
    func ensureAIResearchGroup() -> TabGroup {
        let aiGroups = tabGroups.filter { $0.color == .aiIndigo }
        guard let primary = aiGroups.first else { return createAIResearchGroup() }
        for extra in aiGroups.dropFirst() {
            for tab in tabs where tab.group?.id == extra.id {
                tab.group = primary
            }
            tabGroups.removeAll { $0.id == extra.id }
        }
        return primary
    }

    /// Pure membership diff for syncing the AI group with the research chat's
    /// tab selection: which tabs must enter the group and which must leave for
    /// its members to become exactly `selection`. Both sets empty when the two
    /// already match — the callers' compare-before-write guard, which is what
    /// lets the mirrored reconciliations (selection→group and group→selection)
    /// converge instead of ping-ponging.
    nonisolated static func reconcileAIGroupMembership(
        selection: Set<UUID>, currentMembers: Set<UUID>
    ) -> (toAdd: Set<UUID>, toRemove: Set<UUID>) {
        (toAdd: selection.subtracting(currentMembers),
         toRemove: currentMembers.subtracting(selection))
    }

    /// Commits an inline rename. Whitespace is trimmed; an empty result or a
    /// locked group (the AI group must always read "AI") leaves the current
    /// name untouched.
    func renameGroup(_ group: TabGroup, to newName: String) {
        guard !group.isLocked else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        group.name = trimmed
    }

    func addTabToGroup(_ tab: Tab, group: TabGroup) {
        let previous = tab.group
        tab.group = group
        // Moving a tab between groups vacates its old one — drop that group
        // if the move emptied it, same as `removeTabFromGroup` would, so no
        // ghost group lingers in the tab bar / "Add to Group" menus.
        if let previous, previous.id != group.id {
            removeGroupIfEmpty(previous)
        }
    }

    func addTabToNewGroup(_ tab: Tab) -> TabGroup {
        let colors = TabGroupColor.userSelectable
        let usedColors = Set(tabGroups.map { $0.color })
        let availableColor = colors.first { !usedColors.contains($0) } ?? .blue
        let group = createGroup(name: "Group \(tabGroups.count + 1)", color: availableColor)
        tab.group = group
        return group
    }

    func removeTabFromGroup(_ tab: Tab) {
        guard let group = tab.group else { return }
        tab.group = nil
        removeGroupIfEmpty(group)
    }

    /// Drops `group` once no remaining tab belongs to it — leaving it would
    /// mean a ghost chip in the tab bar when collapsed and a stale entry in
    /// "Add to Group" menus and saved sessions.
    private func removeGroupIfEmpty(_ group: TabGroup) {
        let hasMembers = tabs.contains { $0.group?.id == group.id }
        if !hasMembers {
            tabGroups.removeAll { $0.id == group.id }
        }
    }

    func toggleGroupCollapsed(_ group: TabGroup) {
        group.isCollapsed.toggle()
    }

    func deleteGroup(_ group: TabGroup) {
        for tab in tabs where tab.group?.id == group.id {
            tab.group = nil
        }
        tabGroups.removeAll { $0.id == group.id }
    }

    /// Recreates a group with a caller-specified id, preserving identity so
    /// restored tabs can be matched back to it. Used by session restore.
    @discardableResult
    func restoreGroup(id: UUID, name: String, color: TabGroupColor, isCollapsed: Bool, isLocked: Bool = false) -> TabGroup {
        let group = TabGroup(id: id, name: name, color: color, isCollapsed: isCollapsed, isLocked: isLocked)
        tabGroups.append(group)
        return group
    }

    // MARK: - Tab Sleeping

    private func startSleepTimer() {
        sleepTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.checkSleepingTabs()
        }
    }

    private func checkSleepingTabs() {
        // Respect the user's settings — previously a hardcoded 30 min was used
        // and the "Auto-sleep Inactive Tabs" toggle / timeout picker did nothing.
        let settings = SettingsManager.shared
        guard settings.tabSleepEnabled else { return }
        let sleepTimeout = TimeInterval(settings.tabSleepTimeout * 60)

        let now = Date()
        for tab in tabs {
            guard !tab.isSleeping,
                  !tab.isPinned,
                  tab.id != selectedTabID,
                  tab.id != secondarySelectedTabID,
                  !tab.showHomePage,
                  now.timeIntervalSince(tab.lastActiveDate) > sleepTimeout else { continue }
            // sleep() drops tab.webView without unparenting it — a research
            // webview parked in the off-screen host must leave the hierarchy
            // first or the host would keep the "released" webview alive.
            detachFromResearchHost(tab.webView)
            tab.sleep()
        }
    }
}

struct ClosedTab: Identifiable {
    let id = UUID()
    let url: URL?
    let title: String
    let closedAt: Date

    init(url: URL?, title: String) {
        self.url = url
        self.title = title
        self.closedAt = Date()
    }
}
