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

    // MARK: - Tab Search

    func toggleTabSearch() {
        showTabSearch.toggle()
    }

    // MARK: - Tab Detach

    func detachTab(_ tab: Tab) {
        let url = tab.url
        let title = tab.title

        // Don't detach if it's the only tab
        guard tabManager.tabs.count > 1 else { return }

        tabManager.closeTab(tab)

        // Create a new window with the tab's URL
        let newBrowserView = BrowserView(initialURL: url)
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
        window.isMovable = false  // We handle window movement ourselves
        window.backgroundColor = .windowBackgroundColor
        window.titlebarSeparatorStyle = .none
        window.title = title

        // Position near mouse cursor
        let mouseLocation = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(
            x: mouseLocation.x - 500,
            y: mouseLocation.y - 400
        ))

        // Use a delegate to clean up when the window closes
        let delegate = DetachedWindowDelegate()
        window.delegate = delegate

        // Retain the window and its delegate so they don't deallocate
        BrowserViewModel.detachedWindows.append(window)
        BrowserViewModel.detachedWindowDelegates.append(delegate)

        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Private Browsing

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
