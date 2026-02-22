//
//  TabBarView.swift
//  Internet Browser
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct TabBarView: View {
    @Bindable var tabManager: TabManager
    var isFullScreen: Bool = false
    var isPrivateMode: Bool = false
    let onNewTab: () -> Void
    var onDetachTab: ((Tab) -> Void)? = nil
    var onReceiveTab: ((UUID) -> Void)? = nil

    /// ID of the tab that a drag is currently hovering over (for drop indicator)
    @State private var dropTargetTabID: UUID? = nil

    private let pinnedTabWidth: CGFloat = 40
    private let tabSpacing: CGFloat = 2
    private let leadingPadding: CGFloat = 76
    private let leadingPaddingFullScreen: CGFloat = 8
    private let newTabButtonWidth: CGFloat = 44

    private var pinnedTabs: [Tab] {
        tabManager.tabs.filter { tab in
            tab.isPinned && (tab.group == nil || !tab.group!.isCollapsed)
        }
    }

    private var regularTabs: [Tab] {
        tabManager.tabs.filter { tab in
            !tab.isPinned && (tab.group == nil || !tab.group!.isCollapsed)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let pinned = pinnedTabs
            let regular = regularTabs
            let leading = isFullScreen ? leadingPaddingFullScreen : leadingPadding
            let pinnedSpace = CGFloat(pinned.count) * (pinnedTabWidth + tabSpacing)
            let minTabWidth: CGFloat = 52
            let availableForRegular = geometry.size.width - leading - pinnedSpace - newTabButtonWidth - CGFloat(max(0, regular.count - 1)) * tabSpacing
            let regularTabWidth = regular.count > 0
                ? min(AppConstants.UI.maxTabWidth, max(minTabWidth, availableForRegular / CGFloat(regular.count)))
                : AppConstants.UI.maxTabWidth

            HStack(spacing: 0) {
                WindowDragAreaView()
                    .frame(width: leading)

                HStack(spacing: tabSpacing) {
                    ForEach(pinned) { tab in
                        tabItem(for: tab, width: pinnedTabWidth)
                    }

                    ForEach(tabManager.tabGroups) { group in
                        if group.isCollapsed {
                            collapsedGroupChip(group)
                        }
                    }

                    ForEach(regular) { tab in
                        tabItem(for: tab, width: regularTabWidth)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: tabManager.tabs.map(\.id))

                Button(action: onNewTab) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("New Tab (Cmd+T)")
                .padding(.horizontal, 8)

                WindowDragAreaView()
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: AppConstants.UI.tabBarHeight)
        .background(tabBarBackground)
        // Fallback drop target for empty space on the tab bar
        .onDrop(of: [.cherryBrowserTab], isTargeted: nil) { providers in
            handleBarDrop()
        }
    }

    // MARK: - Tab Item with Drop Target

    @ViewBuilder
    private func tabItem(for tab: Tab, width: CGFloat) -> some View {
        let isDropTarget = dropTargetTabID == tab.id

        TabItemView(
            tab: tab,
            isSelected: tabManager.selectedTabID == tab.id,
            fixedWidth: width,
            onSelect: { tabManager.selectTab(tab) },
            onClose: { tabManager.closeTab(tab) },
            onNewTab: onNewTab,
            onDuplicate: {
                let dup = tabManager.duplicateTab(tab)
                if let url = tab.url {
                    dup.loadURL(url)
                }
            },
            onPin: {
                if tab.isPinned {
                    tabManager.unpinTab(tab)
                } else {
                    tabManager.pinTab(tab)
                }
            },
            onCloseOthers: { tabManager.closeOtherTabs(tab) },
            onCloseRight: { tabManager.closeTabsToRight(of: tab) },
            onAddToNewGroup: {
                _ = tabManager.addTabToNewGroup(tab)
            },
            onRemoveFromGroup: {
                tabManager.removeTabFromGroup(tab)
            },
            availableGroups: tabManager.tabGroups,
            onAddToGroup: { group in
                tabManager.addTabToGroup(tab, group: group)
            },
            onDetachTab: {
                onDetachTab?(tab)
            }
        )
        .overlay(alignment: .leading) {
            // Drop insertion indicator
            if isDropTarget {
                RoundedRectangle(cornerRadius: 1)
                    .fill(SettingsManager.shared.accentColor)
                    .frame(width: 2)
                    .padding(.vertical, 4)
                    .transition(.opacity)
            }
        }
        // Each tab is a drop target for reorder / cross-window
        .onDrop(of: [.cherryBrowserTab], isTargeted: Binding(
            get: { dropTargetTabID == tab.id },
            set: { isTargeted in
                withAnimation(.easeInOut(duration: 0.15)) {
                    dropTargetTabID = isTargeted ? tab.id : nil
                }
            }
        )) { providers in
            handleTabDrop(onto: tab)
        }
    }

    // MARK: - Drop Handlers

    private func handleTabDrop(onto targetTab: Tab) -> Bool {
        dropTargetTabID = nil
        guard let draggedID = TabManager.draggedTabID else { return false }
        TabManager.draggedTabID = nil

        // Same window reorder
        if let fromIndex = tabManager.tabs.firstIndex(where: { $0.id == draggedID }),
           let toIndex = tabManager.tabs.firstIndex(where: { $0.id == targetTab.id }),
           fromIndex != toIndex {
            withAnimation(.easeInOut(duration: 0.25)) {
                tabManager.tabs.move(
                    fromOffsets: IndexSet(integer: fromIndex),
                    toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex
                )
            }
            return true
        }

        // Cross-window transfer (tab not in our manager)
        if !tabManager.tabs.contains(where: { $0.id == draggedID }) {
            onReceiveTab?(draggedID)
            return true
        }

        return true
    }

    private func handleBarDrop() -> Bool {
        dropTargetTabID = nil
        guard let draggedID = TabManager.draggedTabID else { return false }
        TabManager.draggedTabID = nil

        if tabManager.tabs.contains(where: { $0.id == draggedID }) {
            return true
        }
        onReceiveTab?(draggedID)
        return true
    }

    // MARK: - Collapsed Groups

    @ViewBuilder
    private func collapsedGroupChip(_ group: TabGroup) -> some View {
        let count = tabManager.tabs.filter { $0.group?.id == group.id }.count
        Button {
            tabManager.toggleGroupCollapsed(group)
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(group.swiftUIColor)
                    .frame(width: 8, height: 8)
                Text("\(group.name) (\(count))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.gray.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Expand Group") {
                tabManager.toggleGroupCollapsed(group)
            }
            Button("Delete Group") {
                tabManager.deleteGroup(group)
            }
        }
    }

    @ViewBuilder
    private var tabBarBackground: some View {
        ZStack(alignment: .top) {
            Rectangle().fill(.bar)
            if isPrivateMode { Color.purple.opacity(0.12) }
            // Specular highlight — light catching the top edge of the glass
            Color.white.opacity(0.12)
                .frame(height: 1)
        }
    }
}

#Preview {
    TabBarView(
        tabManager: TabManager(),
        onNewTab: {}
    )
    .frame(width: 800)
}
