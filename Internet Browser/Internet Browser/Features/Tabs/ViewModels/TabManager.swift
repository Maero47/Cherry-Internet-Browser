//
//  TabManager.swift
//  Internet Browser
//

import SwiftUI
import Observation

@Observable
final class TabManager {
    var tabs: [Tab] = []
    var selectedTabID: UUID?
    private(set) var recentlyClosedTabs: [ClosedTab] = []
    private(set) var tabGroups: [TabGroup] = []

    /// Shared drag state for native drag-and-drop across windows
    static var draggedTabID: UUID?

    private let maxRecentlyClosedTabs = 25
    private let sleepTimeout: TimeInterval = 30 * 60 // 30 minutes
    private var sleepTimer: Timer?

    var selectedTab: Tab? {
        guard let id = selectedTabID else { return nil }
        return tabs.first { $0.id == id }
    }

    var selectedTabIndex: Int? {
        guard let id = selectedTabID else { return nil }
        return tabs.firstIndex { $0.id == id }
    }

    init(createDefaultTab: Bool = true) {
        if createDefaultTab {
            let initialTab = Tab()
            tabs.append(initialTab)
            selectedTabID = initialTab.id
        }
        startSleepTimer()
    }

    // MARK: - Tab Transfer (cross-window)

    /// Remove a tab without closing it — preserves webview state for transfer
    func removeTab(_ tab: Tab) -> Tab? {
        guard let index = tabs.firstIndex(of: tab) else { return nil }
        tabs.remove(at: index)

        if tabs.isEmpty {
            if let window = NSApp.keyWindow {
                window.close()
            }
            if NSApp.windows.filter({ $0.isVisible }).isEmpty {
                NSApp.terminate(nil)
            }
            return tab
        } else if selectedTabID == tab.id {
            let newIndex = min(index, tabs.count - 1)
            selectedTabID = tabs[newIndex].id
        }
        return tab
    }

    /// Add an existing tab (transferred from another window)
    func addExistingTab(_ tab: Tab, switchTo: Bool = true) {
        tabs.append(tab)
        if switchTo {
            selectedTabID = tab.id
        }
    }

    // MARK: - Tab CRUD

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
            // Close the window when the last tab is closed
            if let window = NSApp.keyWindow {
                window.close()
            }
            // If no windows remain, quit the app
            if NSApp.windows.filter({ $0.isVisible }).isEmpty {
                NSApp.terminate(nil)
            }
            return
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
        selectedTabID = tab.id
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

    // MARK: - Tab Sleeping

    private func startSleepTimer() {
        sleepTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.checkSleepingTabs()
        }
    }

    private func checkSleepingTabs() {
        let now = Date()
        for tab in tabs {
            guard !tab.isSleeping,
                  !tab.isPinned,
                  tab.id != selectedTabID,
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
