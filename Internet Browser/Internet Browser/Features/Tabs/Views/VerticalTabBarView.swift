//
//  VerticalTabBarView.swift
//  Internet Browser
//

import SwiftUI

struct VerticalTabBarView: View {
    @Bindable var tabManager: TabManager
    @Binding var isCollapsed: Bool
    let onNewTab: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private let expandedWidth: CGFloat = 240
    private let collapsedWidth: CGFloat = 44

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                if !isCollapsed {
                    Text("Tabs")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isCollapsed.toggle()
                    }
                } label: {
                    Image(systemName: isCollapsed ? "sidebar.right" : "sidebar.left")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help(isCollapsed ? "Expand sidebar" : "Collapse sidebar")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider()

            // Tab list
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 2) {
                    // Pinned tabs
                    ForEach(tabManager.tabs.filter { $0.isPinned }) { tab in
                        VerticalTabItemView(
                            tab: tab,
                            tabManager: tabManager,
                            isCollapsed: isCollapsed
                        )
                    }

                    if tabManager.tabs.contains(where: { $0.isPinned }) {
                        Divider()
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                    }

                    // Group headers for collapsed groups
                    ForEach(tabManager.tabGroups) { group in
                        if group.isCollapsed {
                            verticalCollapsedGroupHeader(group)
                        }
                    }

                    // Regular tabs
                    ForEach(tabManager.tabs.filter { !$0.isPinned }) { tab in
                        if let group = tab.group, group.isCollapsed {
                            EmptyView()
                        } else {
                            VerticalTabItemView(
                                tab: tab,
                                tabManager: tabManager,
                                isCollapsed: isCollapsed
                            )
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Divider()

            // New tab button
            Button(action: onNewTab) {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                    if !isCollapsed {
                        Text("New Tab")
                            .font(.system(size: 12))
                    }
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: isCollapsed ? .center : .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .help("New Tab (Cmd+T)")
        }
        .frame(width: isCollapsed ? collapsedWidth : expandedWidth)
        .background(sidebarBackground)
    }

    @ViewBuilder
    private func verticalCollapsedGroupHeader(_ group: TabGroup) -> some View {
        let count = tabManager.tabs.filter { $0.group?.id == group.id }.count

        Button {
            tabManager.toggleGroupCollapsed(group)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                Circle()
                    .fill(group.swiftUIColor)
                    .frame(width: 8, height: 8)
                if !isCollapsed {
                    Text("\(group.name) (\(count))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var sidebarBackground: some View {
        colorScheme == .dark
            ? AppConstants.Colors.darkBackground
            : Color(nsColor: .controlBackgroundColor)
    }
}

// Separate view so @State works correctly for hover tracking
private struct VerticalTabItemView: View {
    @Bindable var tab: Tab
    @Bindable var tabManager: TabManager
    let isCollapsed: Bool

    @State private var isHovering = false

    private var isSelected: Bool {
        tabManager.selectedTabID == tab.id
    }

    var body: some View {
        Button {
            tabManager.selectTab(tab)
        } label: {
            HStack(spacing: 8) {
                // Group color dot
                if let group = tab.group {
                    Circle()
                        .fill(group.swiftUIColor)
                        .frame(width: 6, height: 6)
                }

                // Favicon
                Group {
                    if tab.isLoading {
                        ProgressView()
                            .scaleEffect(0.4)
                    } else if tab.isSleeping {
                        Image(systemName: "moon.zzz.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    } else if let favicon = tab.favicon {
                        Image(nsImage: favicon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "globe")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 16, height: 16)

                if !isCollapsed {
                    Text(tab.displayTitle)
                        .font(.system(size: 12))
                        .foregroundStyle(tab.isSleeping ? .tertiary : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // Close button on hover
                    if isHovering || isSelected {
                        Button {
                            tabManager.closeTab(tab)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .frame(width: 14, height: 14)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected
                          ? AppConstants.Colors.accent.opacity(0.15)
                          : (isHovering ? Color.gray.opacity(0.1) : Color.clear))
            )
            .opacity(tab.isSleeping ? 0.6 : 1.0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
        .padding(.horizontal, 4)
        .contextMenu {
            Button("Close Tab") { tabManager.closeTab(tab) }
            Button("Duplicate Tab") {
                let dup = tabManager.duplicateTab(tab)
                if let url = tab.url { dup.loadURL(url) }
            }
            if tab.isPinned {
                Button("Unpin Tab") { tabManager.unpinTab(tab) }
            } else {
                Button("Pin Tab") { tabManager.pinTab(tab) }
            }
            Divider()
            Button("Close Other Tabs") { tabManager.closeOtherTabs(tab) }
            Button("Close Tabs Below") { tabManager.closeTabsToRight(of: tab) }
        }
    }
}
