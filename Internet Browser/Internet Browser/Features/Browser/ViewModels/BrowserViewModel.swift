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
    var searchEngine: SearchEngine = .google
    var showBookmarkBar: Bool = true
    var sidebarContent: SidebarContent = .none
    var showAddBookmark: Bool = false

    let bookmarkRepository = BookmarkRepository.shared
    let historyRepository = HistoryRepository.shared

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
        guard let tab = currentTab,
              let homeURL = URL(string: AppConstants.defaultHomePage) else { return }
        tab.loadURL(homeURL)
    }

    // MARK: - Tab Management

    func newTab(url: URL? = nil) {
        let tab = tabManager.newTab(url: url)
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
