//
//  BrowserViewModel.swift
//  Cherry Browser
//

import SwiftUI
import Observation

enum SidebarContent {
    case none
    case history
    case bookmarks
}

@Observable
final class BrowserViewModel {
    var tabManager = TabManager()
    var searchEngine: SearchEngine { SettingsManager.shared.searchEngine }
    var showBookmarkBar: Bool {
        get { SettingsManager.shared.showBookmarkBar }
        set { SettingsManager.shared.showBookmarkBar = newValue }
    }
    var sidebarContent: SidebarContent = .none
    var showAddBookmark: Bool = false
    var isFullScreen: Bool = false
    var showTabSearch: Bool = false
    var isPrivateMode: Bool = false
    var showPrivateModeAlert: Bool = false
    var useVerticalTabs: Bool {
        get { SettingsManager.shared.useVerticalTabs }
        set { SettingsManager.shared.useVerticalTabs = newValue }
    }
    var verticalTabBarCollapsed: Bool {
        get { SettingsManager.shared.verticalTabBarCollapsed }
        set { SettingsManager.shared.verticalTabBarCollapsed = newValue }
    }

    let bookmarkRepository = BookmarkRepository.shared
    let historyRepository = HistoryRepository.shared
    let shortcutRepository = ShortcutRepository.shared

    // Keep strong references to detached windows and their delegates
    static var detachedWindows: [NSWindow] = []
    static var detachedWindowDelegates: [DetachedWindowDelegate] = []

    // Registry of all active view models for cross-window tab transfer
    private let instanceID = UUID()
    static var windowViewModels: [UUID: BrowserViewModel] = [:]

    init(withDefaultTab: Bool = true) {
        if !withDefaultTab {
            tabManager = TabManager(createDefaultTab: false)
        }
        BrowserViewModel.windowViewModels[instanceID] = self
    }

    deinit {
        BrowserViewModel.windowViewModels.removeValue(forKey: instanceID)
    }

    var currentTab: Tab? {
        tabManager.selectedTab
    }

    var isSidebarVisible: Bool {
        sidebarContent != .none
    }

    // MARK: - Navigation

    func navigate(to input: String) {
        guard let tab = currentTab else { return }

        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try to parse as URL first
        if let url = URL.fromUserInput(trimmedInput) {
            tab.loadURL(url)
        } else if trimmedInput.isLikelyURL {
            // It looks like a URL, try with https
            if let url = URL(string: "https://\(trimmedInput)") {
                tab.loadURL(url)
            } else {
                // Fall back to search
                performSearch(trimmedInput)
            }
        } else {
            // Treat as search query
            performSearch(trimmedInput)
        }
    }

    func performSearch(_ query: String) {
        guard let tab = currentTab,
              let searchURL = URL.searchURL(for: query, engine: searchEngine) else { return }
        tab.loadURL(searchURL)
    }

    func goBack() {
        currentTab?.goBack()
    }

    func goForward() {
        currentTab?.goForward()
    }

    func reload() {
        currentTab?.reload()
    }

    func stopLoading() {
        currentTab?.stopLoading()
    }

    func goHome() {
        guard let tab = currentTab else { return }
        tab.showHomePage = true
        tab.showSettingsPage = false
        tab.title = "New Tab"
    }

    func showSettings() {
        guard let tab = currentTab else { return }
        tab.showSettingsPage = true
        tab.showHomePage = false
        tab.title = "Settings"
    }

    func toggleAdBlockForCurrentSite() {
        guard let tab = currentTab else { return }
        SettingsManager.shared.toggleAdBlockPause(for: tab.url)
        // Reload the page so the change takes effect
        tab.reload()
    }

    // MARK: - Tab Management

    func newTab(url: URL? = nil) {
        let tab = tabManager.newTab(url: url)
        tab.isPrivate = isPrivateMode
        if let url = url {
            tab.loadURL(url)
        }
    }

    func closeCurrentTab() {
        if let tab = currentTab {
            tabManager.closeTab(tab)
        }
    }

    func reopenClosedTab() {
        if let tab = tabManager.reopenLastClosedTab(), let url = tab.url {
            tab.loadURL(url)
        }
    }

    func duplicateCurrentTab() {
        if let tab = currentTab {
            let duplicate = tabManager.duplicateTab(tab)
            if let url = tab.url {
                duplicate.loadURL(url)
            }
        }
    }

    func selectNextTab() {
        tabManager.selectNextTab()
    }

    func selectPreviousTab() {
        tabManager.selectPreviousTab()
    }

    func selectTab(at index: Int) {
        // Handle 1-9 keys for tab selection (1 = first tab, 9 = last tab)
        if index == 9 {
            tabManager.selectTab(at: tabManager.tabs.count - 1)
        } else {
            tabManager.selectTab(at: index - 1)
        }
    }

    // MARK: - Tab Transfer

    /// Transfer a tab from any window to a target viewModel
    static func transferTab(tabID: UUID, to targetViewModel: BrowserViewModel) -> Bool {
        // Find the source viewModel that owns this tab
        for (_, vm) in windowViewModels {
            if vm === targetViewModel { continue }
            if let tab = vm.tabManager.tabs.first(where: { $0.id == tabID }) {
                // Remove from source (preserving webview)
                _ = vm.tabManager.removeTab(tab)
                // Add to target
                targetViewModel.tabManager.addExistingTab(tab)
                return true
            }
        }
        return false
    }

    /// Handle a tab dropped on the content area — detach to new window
    func handleContentAreaDrop() -> Bool {
        guard let draggedID = TabManager.draggedTabID else { return false }
        TabManager.draggedTabID = nil

        // Find the tab across all windows
        for (_, vm) in BrowserViewModel.windowViewModels {
            if let tab = vm.tabManager.tabs.first(where: { $0.id == draggedID }) {
                guard vm.tabManager.tabs.count > 1 else { return false }
                vm.detachTab(tab)
                return true
            }
        }
        return false
    }

    // MARK: - Tab Search

    func toggleTabSearch() {
        showTabSearch.toggle()
    }

    // MARK: - Tab Detach

    func detachTab(_ tab: Tab) {
        let title = tab.title

        // Don't detach if it's the only tab
        guard tabManager.tabs.count > 1 else { return }

        // Remove tab from source window (preserves webView state)
        _ = tabManager.removeTab(tab)

        // Create a new window with the existing tab (no reload)
        let newBrowserView = BrowserView(existingTab: tab)
        let hostingView = NSHostingView(rootView: newBrowserView)

        let windowWidth: CGFloat = 1000
        let windowHeight: CGFloat = 700

        let window = DetachedWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.isMovable = false
        window.backgroundColor = .windowBackgroundColor
        window.titlebarSeparatorStyle = .none
        window.title = title

        // Position centered on screen, clamped to screen bounds
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let mouseLocation = NSEvent.mouseLocation
            var originX = mouseLocation.x - windowWidth / 2
            var originY = mouseLocation.y - windowHeight / 2
            originX = max(screenFrame.minX, min(originX, screenFrame.maxX - windowWidth))
            originY = max(screenFrame.minY, min(originY, screenFrame.maxY - windowHeight))
            window.setFrameOrigin(NSPoint(x: originX, y: originY))
        } else {
            window.center()
        }

        let delegate = DetachedWindowDelegate()
        window.delegate = delegate

        BrowserViewModel.detachedWindows.append(window)
        BrowserViewModel.detachedWindowDelegates.append(delegate)

        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Private Browsing

    func requestTogglePrivateMode() {
        showPrivateModeAlert = true
    }

    func confirmTogglePrivateMode() {
        isPrivateMode.toggle()
        // Update all existing tabs
        for tab in tabManager.tabs {
            tab.isPrivate = isPrivateMode
        }
        // Reload current tab so it uses the correct data store
        if let tab = currentTab, tab.url != nil {
            tab.webView = nil // Force new webView with correct data store
            tab.reload()
        }
    }

    func openPrivateWindow() {
        let newBrowserView = BrowserView(isPrivate: true)
        let hostingView = NSHostingView(rootView: newBrowserView)

        let window = DetachedWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.isMovable = false
        window.backgroundColor = .windowBackgroundColor
        window.titlebarSeparatorStyle = .none
        window.title = "Private Browsing"

        BrowserViewModel.detachedWindows.append(window)

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { notification in
            guard let closedWindow = notification.object as? NSWindow else { return }
            BrowserViewModel.detachedWindows.removeAll { $0 === closedWindow }
        }

        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Vertical Tabs

    func toggleVerticalTabs() {
        useVerticalTabs.toggle()
    }

    func toggleVerticalTabBarCollapsed() {
        verticalTabBarCollapsed.toggle()
    }

    // MARK: - Bookmarks

    func toggleBookmarkBar() {
        showBookmarkBar.toggle()
    }

    func addBookmark(title: String, folder: String?, isInBookmarkBar: Bool) {
        guard let tab = currentTab, let url = tab.url else { return }
        bookmarkRepository.addBookmark(
            url: url,
            title: title,
            favicon: tab.favicon,
            folder: folder,
            isInBookmarkBar: isInBookmarkBar
        )
    }

    func isCurrentPageBookmarked() -> Bool {
        guard let url = currentTab?.url else { return false }
        return bookmarkRepository.isBookmarked(url: url)
    }

    func openBookmark(_ bookmark: Bookmark) {
        if let tab = currentTab {
            tab.loadURL(bookmark.url)
        } else {
            newTab(url: bookmark.url)
        }
        bookmarkRepository.incrementVisitCount(for: bookmark)
    }

    // MARK: - Sidebar

    func toggleHistory() {
        if sidebarContent == .history {
            sidebarContent = .none
        } else {
            sidebarContent = .history
        }
    }

    func toggleBookmarks() {
        if sidebarContent == .bookmarks {
            sidebarContent = .none
        } else {
            sidebarContent = .bookmarks
        }
    }

    func closeSidebar() {
        sidebarContent = .none
    }

    func openHistoryItem(_ item: HistoryItem) {
        if let tab = currentTab {
            tab.loadURL(item.url)
        } else {
            newTab(url: item.url)
        }
    }
}

// MARK: - Detached Window

/// Custom NSWindow subclass for detached tabs
class DetachedWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        self.isReleasedWhenClosed = false
    }
}

/// Delegate that cleans up detached window references when the window closes
class DetachedWindowDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let closedWindow = notification.object as? NSWindow else { return }
        // Defer cleanup to avoid mutating state during notification
        DispatchQueue.main.async {
            BrowserViewModel.detachedWindows.removeAll { $0 === closedWindow }
            BrowserViewModel.detachedWindowDelegates.removeAll { $0 === closedWindow.delegate as? DetachedWindowDelegate }
        }
    }
}
