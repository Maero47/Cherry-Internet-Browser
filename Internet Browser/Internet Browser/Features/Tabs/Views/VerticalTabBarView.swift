//
//  VerticalTabBarView.swift
//  Internet Browser
//

import SwiftUI
import UniformTypeIdentifiers

struct VerticalTabBarView: View {
    @Bindable var tabManager: TabManager
    @Binding var isCollapsed: Bool
    /// Private windows are never themed by an imported Firefox theme.
    var isPrivateMode: Bool = false
    let onNewTab: () -> Void
    var onDetachTab: ((Tab) -> Void)? = nil
    var onReceiveTab: ((UUID) -> Void)? = nil

    /// Single source of truth for the sidebar width — BrowserView no longer
    /// applies its own (previously duplicated) 44/240 frame, so the outer
    /// layout and the inner content can never animate out of step.
    private let expandedWidth: CGFloat = 240
    private let collapsedWidth: CGFloat = 44

    /// Transient hover expansion while collapsed (Arc/Firefox-style flyout).
    /// Purely visual: never written to `isCollapsed`, so the user's persisted
    /// collapse preference survives any amount of hovering.
    @State private var isHoverExpanded = false
    /// Debounce for both hover edges so brushing past the bar doesn't flicker.
    @State private var hoverTask: Task<Void, Never>? = nil
    /// Set when the user clicks "collapse" with the pointer still on the bar,
    /// so the flyout doesn't immediately reopen; cleared on the next hover exit.
    @State private var suppressHoverExpand = false

    /// True while the full 240pt content should be visible (pinned open OR
    /// transiently hover-expanded).
    private var showsExpandedContent: Bool { !isCollapsed || isHoverExpanded }
    /// Compact rendering (icons only) — what the old per-view `isCollapsed`
    /// display checks keyed off.
    private var isCompact: Bool { !showsExpandedContent }
    /// Width the sidebar occupies in the window layout. Hover expansion does
    /// NOT change this — the flyout floats over the content (zIndex above the
    /// web view) so the page never reflows on hover.
    private var layoutWidth: CGFloat { isCollapsed ? collapsedWidth : expandedWidth }
    /// Width of the rendered bar itself (flyout included).
    private var contentWidth: CGFloat { showsExpandedContent ? expandedWidth : collapsedWidth }

    var body: some View {
        barContent
            .frame(width: contentWidth)
            .background { barBackground }
            .clipped()
            // Reads as a floating panel only while transiently hover-expanded.
            .shadow(
                color: .black.opacity(isCollapsed && isHoverExpanded ? 0.28 : 0),
                radius: 12, x: 5
            )
            .onHover { handleHover($0) }
            // The layout slot: fixed by isCollapsed alone; the (possibly wider)
            // bar overflows it to the trailing side while hover-expanded.
            .frame(width: layoutWidth, alignment: .leading)
            // Width and content collapse in ONE animated transaction, keyed to
            // the state itself so every entry point (button, menu, shortcut,
            // hover) animates identically.
            .animation(.easeInOut(duration: 0.22), value: isCollapsed)
            .animation(.easeInOut(duration: 0.22), value: isHoverExpanded)
            .onChange(of: isCollapsed) {
                // Pin/unpin resets any transient hover state so a stale
                // flyout can't hold the bar visually open after collapsing.
                hoverTask?.cancel()
                isHoverExpanded = false
            }
            .onDisappear {
                hoverTask?.cancel()
            }
    }

    /// Debounced hover: expand shortly after the pointer settles on the
    /// collapsed bar, collapse shortly after it leaves — the delays absorb
    /// accidental brushes in both directions.
    private func handleHover(_ hovering: Bool) {
        hoverTask?.cancel()
        guard isCollapsed else { return }
        if hovering {
            guard !suppressHoverExpand, !isHoverExpanded else { return }
            hoverTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled, isCollapsed else { return }
                isHoverExpanded = true
            }
        } else {
            suppressHoverExpand = false
            guard isHoverExpanded else { return }
            hoverTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                isHoverExpanded = false
            }
        }
    }

    @ViewBuilder
    private var barContent: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                if !isCompact {
                    Text("Tabs")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                Button {
                    hoverTask?.cancel()
                    if !isCollapsed {
                        // Collapsing with the pointer still on the bar: hold
                        // the flyout closed until the pointer leaves once.
                        suppressHoverExpand = true
                    }
                    // Same curve/duration as the sidebar's own width animation
                    // so views outside it (nav-bar padding) move in lockstep.
                    withAnimation(.easeInOut(duration: 0.22)) {
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
            .padding(.top, 32)
            .padding(.bottom, 6)

            // Tab list
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 2) {
                    // Pinned tabs
                    ForEach(tabManager.tabs.filter { $0.isPinned }) { tab in
                        VerticalTabItemView(
                            tab: tab,
                            tabManager: tabManager,
                            isCompact: isCompact,
                            onDetachTab: onDetachTab,
                            onReceiveTab: onReceiveTab
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
                                isCompact: isCompact,
                                onDetachTab: onDetachTab,
                                onReceiveTab: onReceiveTab
                            )
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            // Accept drops on the scroll area (for drops on empty space)
            .onDrop(of: [.cherryBrowserTab], isTargeted: nil) { providers in
                guard let draggedID = TabManager.draggedTabID else { return false }
                TabManager.draggedTabID = nil
                if tabManager.tabs.contains(where: { $0.id == draggedID }) {
                    return true
                }
                onReceiveTab?(draggedID)
                return true
            }

            Divider()

            // New tab button
            Button(action: onNewTab) {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                    if !isCompact {
                        Text("New Tab")
                            .font(.system(size: 12))
                    }
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: isCompact ? .center : .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .help("New Tab (Cmd+T)")
        }
    }

    @ViewBuilder
    private var barBackground: some View {
        // Imported Firefox theme: the tab strip takes the header
        // backdrop — frame color plus header images (the sidebar spans
        // the window's left edge, so left/top-anchored art lands here).
        if !isPrivateMode, FirefoxThemeManager.shared.hasHeaderBackdrop {
            ThemeHeaderBackdropView()
        } else if !isPrivateMode, let themedStrip = FirefoxThemeManager.shared.tabStripBackground {
            themedStrip
        } else {
            Rectangle().fill(.bar)
        }
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
                if !isCompact {
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

}

// Separate view so @State works correctly for hover tracking
private struct VerticalTabItemView: View {
    @Bindable var tab: Tab
    @Bindable var tabManager: TabManager
    /// Icons-only rendering (collapsed and not hover-expanded).
    let isCompact: Bool
    var onDetachTab: ((Tab) -> Void)? = nil
    var onReceiveTab: ((UUID) -> Void)? = nil

    @State private var isHovering = false

    private var isSelected: Bool {
        tabManager.selectedTabID == tab.id
    }

    /// True when this tab is one of the two tabs currently shown in split
    /// view — mirrors the same check in `TabBarView`'s horizontal tab item.
    private var isPaired: Bool {
        tabManager.isSplitActive &&
            (tabManager.selectedTabID == tab.id || tabManager.secondarySelectedTabID == tab.id)
    }

    /// Imported Firefox theme overrides — nil for private tabs (never themed)
    /// or when no theme is active, keeping the stock accent/hierarchy look.
    private var themedSelectedBackground: Color? {
        tab.isPrivate ? nil : FirefoxThemeManager.shared.selectedTabBackground
    }
    private var themedTitleColor: Color? {
        guard !tab.isPrivate else { return nil }
        let manager = FirefoxThemeManager.shared
        return isSelected ? manager.tabText : manager.tabStripText
    }

    var body: some View {
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
            .overlay(alignment: .bottomTrailing) {
                if isPaired {
                    Image(systemName: "rectangle.split.2x1.fill")
                        .font(.system(size: 6, weight: .bold))
                        .foregroundStyle(SettingsManager.shared.accentColor)
                        .padding(2)
                        .background(Circle().fill(.regularMaterial))
                        .offset(x: 4, y: 4)
                }
            }

            if !isCompact {
                Text(tab.displayTitle)
                    .font(.system(size: 12))
                    .foregroundStyle(tab.isSleeping
                                     ? AnyShapeStyle(.tertiary)
                                     : AnyShapeStyle(themedTitleColor ?? Color.primary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Mute indicator — click to unmute
                if tab.isMuted {
                    Button {
                        tab.isMuted = false
                    } label: {
                        Image(systemName: "speaker.slash.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 12, height: 12)
                    .help("Unmute Tab")
                }

                // Close button (always in layout, opacity-controlled)
                Button {
                    tabManager.closeTab(tab)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 14, height: 14)
                .opacity(isHovering || isSelected ? 1 : 0)
                .animation(.easeInOut(duration: 0.1), value: isHovering)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected
                      ? (themedSelectedBackground ?? SettingsManager.shared.accentColor.opacity(0.15))
                      : (isHovering ? Color.gray.opacity(0.1) : Color.clear))
        )
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .animation(.easeInOut(duration: 0.12), value: isSelected)
        .opacity(tab.isSleeping ? 0.6 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture {
            tabManager.selectTab(tab)
        }
        .onDrag {
            TabManager.draggedTabID = tab.id
            return tab.itemProvider()
        } preview: {
            HStack(spacing: 6) {
                if let favicon = tab.favicon {
                    Image(nsImage: favicon)
                        .resizable()
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "globe")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Text(tab.displayTitle)
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        // Drop target for reorder / cross-window
        .onDrop(of: [.cherryBrowserTab], isTargeted: nil) { providers in
            guard let draggedID = TabManager.draggedTabID else { return false }
            TabManager.draggedTabID = nil

            // Same window reorder
            if let fromIndex = tabManager.tabs.firstIndex(where: { $0.id == draggedID }),
               let toIndex = tabManager.tabs.firstIndex(where: { $0.id == tab.id }),
               fromIndex != toIndex {
                withAnimation(.easeInOut(duration: 0.2)) {
                    tabManager.tabs.move(
                        fromOffsets: IndexSet(integer: fromIndex),
                        toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex
                    )
                }
                return true
            }

            // Cross-window transfer
            if !tabManager.tabs.contains(where: { $0.id == draggedID }) {
                onReceiveTab?(draggedID)
                return true
            }
            return true
        }
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
            Button("Open in New Window") {
                onDetachTab?(tab)
            }
            .disabled(tabManager.tabs.count <= 1)
            if tabManager.isSplitActive {
                Button("Close Split View") {
                    tabManager.closeSplit()
                }
            } else {
                Button("Open in Split View") {
                    tabManager.openSplit(with: tab.id)
                }
            }
            Divider()
            Button("Close Other Tabs") { tabManager.closeOtherTabs(tab) }
            Button("Close Tabs Below") { tabManager.closeTabsToRight(of: tab) }
        }
    }
}

