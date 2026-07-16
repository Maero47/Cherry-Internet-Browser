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
            if NSApp.windows.filter({ $0.isVisible }).isEmpty {
                NSApp.terminate(nil)
            }
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
    func openBackgroundResearchTab(url: URL, title: String) -> Tab {
        let tab = newTab(url: url, switchTo: false)
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

        let webView = CherryWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.tabID = tab.id
        tab.adoptWebView(webView)
        // With no wrapper coordinator until the tab is displayed, the tab
        // mirrors url/title/isLoading itself: the tab bar gets a live
        // spinner/title, redirects land in `tab.url` (so adoption won't
        // reload the stale seed URL), and the research panel can see the
        // load finish. Torn down when `WebViewWrapper` adopts the webview.
        tab.beginBackgroundLoadObservation()
        webView.load(URLRequest(url: url))
        return tab
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
        // about:blank state back onto the closing tab.
        tab.endBackgroundLoadObservation()
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

        // Handle selection
        if tabs.isEmpty {
            // Close this manager's own window when its last tab is closed —
            // hostWindow, not keyWindow (which may be a different focused window).
            if let window = hostWindow ?? NSApp.keyWindow {
                window.close()
            }
            // If no windows remain, quit the app
            if NSApp.windows.filter({ $0.isVisible }).isEmpty {
                NSApp.terminate(nil)
            }
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
        let insertIndex = destIndex > sourceIndex ? destIndex : destIndex
        tabs.insert(tab, at: min(insertIndex, tabs.count))
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
    func createGroup(name: String = "New Group", color: TabGroupColor = .blue) -> TabGroup {
        let group = TabGroup(name: name, color: color)
        tabGroups.append(group)
        return group
    }

    func addTabToGroup(_ tab: Tab, group: TabGroup) {
        tab.group = group
    }

    func addTabToNewGroup(_ tab: Tab) -> TabGroup {
        let colors = TabGroupColor.allCases
        let usedColors = Set(tabGroups.map { $0.color })
        let availableColor = colors.first { !usedColors.contains($0) } ?? .blue
        let group = createGroup(name: "Group \(tabGroups.count + 1)", color: availableColor)
        tab.group = group
        return group
    }

    func removeTabFromGroup(_ tab: Tab) {
        guard let group = tab.group else { return }
        tab.group = nil
        // Remove group if empty
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
    func restoreGroup(id: UUID, name: String, color: TabGroupColor, isCollapsed: Bool) -> TabGroup {
        let group = TabGroup(id: id, name: name, color: color, isCollapsed: isCollapsed)
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
