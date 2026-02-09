//
//  TabBarView.swift
//  Internet Browser
//

import SwiftUI
import AppKit

struct TabBarView: View {
    @Bindable var tabManager: TabManager
    var isFullScreen: Bool = false
    var isPrivateMode: Bool = false
    let onNewTab: () -> Void
    var onDetachTab: ((Tab) -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme

    // Reorder state — only reorder on drop, not during drag
    @State private var draggingTabID: UUID? = nil
    @State private var dragTranslation: CGFloat = 0

    private let pinnedTabWidth: CGFloat = 40
    private let tabSpacing: CGFloat = 2
    private let leadingPadding: CGFloat = 76
    private let leadingPaddingFullScreen: CGFloat = 8
    private let newTabButtonWidth: CGFloat = 44  // 28 + trailing padding

    var body: some View {
        GeometryReader { geometry in
            let visibleTabs = tabManager.tabs.filter { tab in
                if let group = tab.group, group.isCollapsed { return false }
                return true
            }
            let pinnedCount = visibleTabs.filter { $0.isPinned }.count
            let regularCount = visibleTabs.filter { !$0.isPinned }.count
            let leading = isFullScreen ? leadingPaddingFullScreen : leadingPadding
            let pinnedSpace = CGFloat(pinnedCount) * (pinnedTabWidth + tabSpacing)
            let minTabWidth: CGFloat = 52  // favicon + close button minimum
            let availableForRegular = geometry.size.width - leading - pinnedSpace - newTabButtonWidth - CGFloat(max(0, regularCount - 1)) * tabSpacing
            let regularTabWidth = regularCount > 0
                ? min(AppConstants.UI.maxTabWidth, max(minTabWidth, availableForRegular / CGFloat(regularCount)))
                : AppConstants.UI.maxTabWidth

            HStack(spacing: 0) {
                // Leading drag area — AppKit window drag (traffic light area)
                WindowDragAreaView()
                    .frame(width: leading)

                // Tabs — fixed width, fill available space like Chrome
                HStack(spacing: tabSpacing) {
                    ForEach(visibleTabs.filter { $0.isPinned }) { tab in
                        tabItem(for: tab, width: pinnedTabWidth, effectiveTabWidth: pinnedTabWidth)
                    }

                    ForEach(tabManager.tabGroups) { group in
                        if group.isCollapsed {
                            collapsedGroupChip(group)
                        }
                    }

                    ForEach(visibleTabs.filter { !$0.isPinned }) { tab in
                        tabItem(for: tab, width: regularTabWidth, effectiveTabWidth: regularTabWidth)
                    }
                }

                // New tab button
                Button(action: onNewTab) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("New Tab (Cmd+T)")
                .padding(.horizontal, 8)

                // Trailing drag area — AppKit window drag (remaining space)
                WindowDragAreaView()
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: AppConstants.UI.tabBarHeight)
        .background(tabBarBackground)
    }

    // MARK: - Tab Item

    @ViewBuilder
    private func tabItem(for tab: Tab, width: CGFloat, effectiveTabWidth: CGFloat) -> some View {
        let isDragged = draggingTabID == tab.id
        let shiftOffset = neighborShift(for: tab, tabWidth: effectiveTabWidth)

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
            onDragUpdate: { translation in
                draggingTabID = tab.id
                dragTranslation = translation.width
            },
            onDragEnd: { translation in
                handleTabDragEnd(tab: tab, translation: translation, tabWidth: effectiveTabWidth)
            }
        )
        // Dragged tab: no extra shift (TabItemView already applies dragOffset)
        // Neighbor tabs: shift to make a gap
        .offset(x: isDragged ? 0 : shiftOffset)
        .animation(.easeInOut(duration: 0.2), value: shiftOffset)
    }

    // MARK: - Tab Reorder Logic

    /// Calculate how much a non-dragged tab should shift to make room
    private func neighborShift(for tab: Tab, tabWidth: CGFloat) -> CGFloat {
        guard let dragID = draggingTabID,
              dragID != tab.id,
              let dragIndex = tabManager.tabs.firstIndex(where: { $0.id == dragID }),
              let myIndex = tabManager.tabs.firstIndex(where: { $0.id == tab.id }) else {
            return 0
        }

        let effectiveWidth = tabWidth + tabSpacing
        let positionsMoved = Int(round(dragTranslation / effectiveWidth))
        let targetIndex = max(0, min(tabManager.tabs.count - 1, dragIndex + positionsMoved))

        // Tabs between the drag source and target need to shift
        if dragIndex < targetIndex {
            // Dragging right: tabs between dragIndex+1...targetIndex shift left
            if myIndex > dragIndex && myIndex <= targetIndex {
                return -effectiveWidth
            }
        } else if dragIndex > targetIndex {
            // Dragging left: tabs between targetIndex...dragIndex-1 shift right
            if myIndex >= targetIndex && myIndex < dragIndex {
                return effectiveWidth
            }
        }

        return 0
    }

    private func handleTabDragEnd(tab: Tab, translation: CGSize, tabWidth: CGFloat) {
        // Calculate final position
        if let dragIndex = tabManager.tabs.firstIndex(of: tab) {
            let effectiveWidth = tabWidth + tabSpacing
            let positionsMoved = Int(round(translation.width / effectiveWidth))
            let targetIndex = max(0, min(tabManager.tabs.count - 1, dragIndex + positionsMoved))

            if targetIndex != dragIndex {
                let movedTab = tabManager.tabs.remove(at: dragIndex)
                tabManager.tabs.insert(movedTab, at: targetIndex)
            }
        }

        // Reset drag state
        draggingTabID = nil
        dragTranslation = 0

        // Detach to new window if dragged far enough vertically (and more than 1 tab)
        if abs(translation.height) > 60 && tabManager.tabs.count > 1 {
            onDetachTab?(tab)
        }
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
        if isPrivateMode {
            colorScheme == .dark
                ? Color(hex: "2D1B3D")  // Dark purple
                : Color(hex: "E8D5F5")  // Light purple
        } else {
            colorScheme == .dark
                ? AppConstants.Colors.darkBackground
                : AppConstants.Colors.lightBackground
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
