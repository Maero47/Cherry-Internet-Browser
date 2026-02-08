//
//  TabManager.swift
//  Internet Browser
//

import SwiftUI
import Observation

@Observable
final class TabManager {
    private(set) var tabs: [Tab] = []
    var selectedTabID: UUID?
    private(set) var recentlyClosedTabs: [ClosedTab] = []

    private let maxRecentlyClosedTabs = 25

    var selectedTab: Tab? {
        guard let id = selectedTabID else { return nil }
        return tabs.first { $0.id == id }
    }

    var selectedTabIndex: Int? {
        guard let id = selectedTabID else { return nil }
        return tabs.firstIndex { $0.id == id }
    }

    init() {
        // Start with one new tab
        let initialTab = Tab()
        tabs.append(initialTab)
        selectedTabID = initialTab.id
    }

    @discardableResult
    func newTab(url: URL? = nil, switchTo: Bool = true) -> Tab {
        let tab = Tab(url: url)
        tabs.append(tab)
        if switchTo {
            selectedTabID = tab.id
        }
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

        // Remove the tab
        tabs.remove(at: index)

        // Handle selection
        if tabs.isEmpty {
            // Create a new tab if we closed the last one
            let newTab = Tab()
            tabs.append(newTab)
            selectedTabID = newTab.id
        } else if selectedTabID == tab.id {
            // Select adjacent tab
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

    func selectTab(_ tab: Tab) {
        selectedTabID = tab.id
    }

    func selectTab(at index: Int) {
        guard index >= 0 && index < tabs.count else { return }
        selectedTabID = tabs[index].id
    }

    func selectNextTab() {
        guard let currentIndex = selectedTabIndex else { return }
        let nextIndex = (currentIndex + 1) % tabs.count
        selectedTabID = tabs[nextIndex].id
    }

    func selectPreviousTab() {
        guard let currentIndex = selectedTabIndex else { return }
        let previousIndex = currentIndex > 0 ? currentIndex - 1 : tabs.count - 1
        selectedTabID = tabs[previousIndex].id
    }

    func moveTab(from source: IndexSet, to destination: Int) {
        tabs.move(fromOffsets: source, toOffset: destination)
    }

    func duplicateTab(_ tab: Tab) -> Tab {
        let duplicate = Tab(url: tab.url, title: tab.title)
        if let index = tabs.firstIndex(of: tab) {
            tabs.insert(duplicate, at: index + 1)
        } else {
            tabs.append(duplicate)
        }
        selectedTabID = duplicate.id
        return duplicate
    }

    func reopenLastClosedTab() -> Tab? {
        guard let closedTab = recentlyClosedTabs.first else { return nil }
        recentlyClosedTabs.removeFirst()

        let tab = Tab(url: closedTab.url, title: closedTab.title)
        tabs.append(tab)
        selectedTabID = tab.id
        return tab
    }

    func pinTab(_ tab: Tab) {
        tab.isPinned = true
        // Move pinned tabs to the front
        if let index = tabs.firstIndex(of: tab) {
            let pinnedCount = tabs.filter { $0.isPinned && $0.id != tab.id }.count
            tabs.remove(at: index)
            tabs.insert(tab, at: pinnedCount)
        }
    }

    func unpinTab(_ tab: Tab) {
        tab.isPinned = false
        // Move after all pinned tabs
        if let index = tabs.firstIndex(of: tab) {
            let pinnedCount = tabs.filter { $0.isPinned }.count
            tabs.remove(at: index)
            tabs.insert(tab, at: pinnedCount)
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
