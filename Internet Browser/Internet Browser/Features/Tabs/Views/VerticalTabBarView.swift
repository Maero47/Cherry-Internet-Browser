//
//  VerticalTabBarView.swift
//  Internet Browser
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct VerticalTabBarView: View {
    @Bindable var tabManager: TabManager
    @Binding var isCollapsed: Bool
    /// Private windows are never themed by an imported Firefox theme.
    var isPrivateMode: Bool = false
    let onNewTab: () -> Void
    var onDetachTab: ((Tab) -> Void)? = nil
    var onReceiveTab: ((UUID) -> Void)? = nil
    /// Dragging a tab into the content's left/right edge zone opens split
    /// view with the tab on that edge — same hook the horizontal bar uses.
    var onSplitOnEdge: ((Tab, Edge) -> Void)? = nil

    /// ID of the tab currently being reordered via DragGesture
    @State private var draggingTabID: UUID? = nil
    /// Reference Y position (global) used to compute cross-boundary reorders
    @State private var lastReorderY: CGFloat = 0

    /// Tear-off ghost state — when the tab is pulled sideways out of the bar
    /// it floats freely, mirroring TabBarView's mechanism on the other axis.
    @State private var isTearingOff: Bool = false
    @State private var tearOffTabID: UUID? = nil
    /// Floating on-screen-anywhere ghost window shown while tearing a tab off.
    /// Lives outside the SwiftUI view hierarchy so it isn't clipped to the window bounds.
    @State private var ghostWindow: GhostTabWindow? = nil

    /// Inline group rename: the header whose name is currently an edit field.
    @State private var renamingGroupID: UUID? = nil
    @State private var renameDraft: String = ""
    @FocusState private var focusedRenameGroupID: UUID?

    /// One tab row's layout stride (row height 26 + list spacing 2) — the
    /// vertical counterpart of the horizontal bar's tab-width reorder step.
    private let rowStride: CGFloat = 28

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
                // Safety net: if the bar leaves the hierarchy mid-drag (e.g.
                // entering video fullscreen), the gesture's onEnded never
                // fires — this guarantees the ghost window is torn down.
                hideGhostWindow()
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
                        tabItem(for: tab)
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
                            tabItem(for: tab)
                        }
                    }
                }
                .padding(.vertical, 4)
                // Rows slide out of the way live while reordering — the same
                // moving-slots feedback the horizontal bar gives.
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: tabManager.tabs.map(\.id))
            }
            // Accept drops on the scroll area (for drops on empty space)
            .onDrop(of: [.cherryBrowserTab], isTargeted: nil) { providers in
                handleBarDrop()
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

    // MARK: - Tab Item with Gesture Reorder (mirrors TabBarView, vertical axis)

    @ViewBuilder
    private func tabItem(for tab: Tab) -> some View {
        let isDragging = draggingTabID == tab.id
        let isTearingOffThisTab = isTearingOff && tearOffTabID == tab.id

        VerticalTabItemView(
            tab: tab,
            tabManager: tabManager,
            isCompact: isCompact,
            onNewTab: onNewTab,
            onDetachTab: onDetachTab
        )
        // Dim the slot when the tab is floating as a ghost
        .opacity(isTearingOffThisTab ? 0.35 : 1.0)
        // Subtle lift effect while reordering
        .scaleEffect(isDragging ? CGSize(width: 1.03, height: 1.0) : CGSize(width: 1, height: 1))
        .shadow(color: isDragging ? .black.opacity(0.22) : .clear, radius: 8, x: 3)
        .zIndex(isDragging || isTearingOffThisTab ? 2 : 0)
        .animation(.spring(response: 0.15, dampingFraction: 0.85), value: isDragging)
        // Same flow as the horizontal bar: DragGesture fires immediately (2 px
        // threshold) for real-time in-list reorder along Y; pulling the tab
        // SIDEWAYS (either direction) beyond 30 pt switches to free tear-off
        // mode with a floating GhostTabWindow. Click-drags don't scroll a
        // macOS ScrollView, so the simultaneous gesture never fights the list.
        .simultaneousGesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { value in
                    guard !tab.isPinned else { return }

                    // Already in tear-off mode — move the floating ghost window and return
                    if isTearingOff && tearOffTabID == tab.id {
                        ghostWindow?.move(toScreenPoint: NSEvent.mouseLocation)
                        return
                    }

                    // A pure vertical reorder keeps a small width translation,
                    // so 30 pt sideways is unambiguously a pull out of the bar.
                    if abs(value.translation.width) > 30 {
                        isTearingOff = true
                        tearOffTabID = tab.id
                        draggingTabID = nil          // hand off from reorder to ghost
                        TabManager.draggedTabID = tab.id
                        showGhostWindow(for: tab)
                        return
                    }

                    // Vertical reorder within the list
                    reorderOnDrag(tab: tab, y: value.location.y)
                }
                .onEnded { value in
                    // Clean up tear-off ghost state (covers tear-off, re-attach and
                    // cancel — this always runs when the gesture ends).
                    if isTearingOff && tearOffTabID == tab.id {
                        isTearingOff = false
                        tearOffTabID = nil
                        hideGhostWindow()
                    }

                    guard !tab.isPinned else {
                        finishDrag()
                        return
                    }

                    let mouseLocation = NSEvent.mouseLocation
                    let sourceFrame = tabManager.hostWindow?.frame ?? NSApp.keyWindow?.frame ?? .zero
                    let leftSourceWindow = !sourceFrame.contains(mouseLocation)

                    // Released INSIDE this window near the left or right content
                    // edge → open split view with this tab on that edge. The
                    // leading zone spans an edgeZone-wide band starting at the
                    // bar's CURRENT layout width (44 collapsed / 240 expanded),
                    // so a drop on the bar itself never splits, the left
                    // content edge is always reachable, and — capped at the
                    // trailing zone's start — the two zones can't overlap on
                    // narrow windows. Checked before detach so an edge drop
                    // splits instead of tearing off into a new window.
                    if !leftSourceWindow, onSplitOnEdge != nil, sourceFrame.width > 0 {
                        let relX = mouseLocation.x - sourceFrame.minX
                        let edgeZone = sourceFrame.width * 0.30
                        let trailingZoneStart = sourceFrame.width - edgeZone
                        let leadingZoneEnd = min(layoutWidth + edgeZone, trailingZoneStart)
                        if relX > layoutWidth && relX < leadingZoneEnd {
                            onSplitOnEdge?(tab, .leading)
                            finishDrag()
                            return
                        } else if relX > trailingZoneStart {
                            onSplitOnEdge?(tab, .trailing)
                            finishDrag()
                            return
                        }
                    }

                    // Detach on release if the cursor left the source window or
                    // the tab was pulled sideways far enough — matching the
                    // symmetric tear-off ghost trigger above.
                    if leftSourceWindow || abs(value.translation.width) > 44 {
                        triggerDetach(tab: tab)
                    } else {
                        finishDrag()
                    }
                }
        )
        // Kept for cross-window tab receives; same-window reorder is handled above
        .onDrop(of: [.cherryBrowserTab], isTargeted: nil) { _ in
            handleTabDrop(onto: tab)
        }
    }

    // MARK: - Drop Handlers

    private func handleTabDrop(onto targetTab: Tab) -> Bool {
        guard let draggedID = TabManager.draggedTabID else { return false }

        // Cross-window receive: always handle regardless of gesture flag
        if !tabManager.tabs.contains(where: { $0.id == draggedID }) {
            TabManager.draggedTabID = nil
            TabManager.reorderedByGesture = false
            onReceiveTab?(draggedID)
            return true
        }

        // Same-window: DragGesture already reordered — skip to avoid double-move
        if TabManager.reorderedByGesture {
            TabManager.reorderedByGesture = false
            return true
        }

        // Fallback same-window reorder (e.g. when drag came from system drag session)
        TabManager.draggedTabID = nil
        if let fromIndex = tabManager.tabs.firstIndex(where: { $0.id == draggedID }),
           let toIndex = tabManager.tabs.firstIndex(where: { $0.id == targetTab.id }),
           fromIndex != toIndex {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                tabManager.tabs.move(
                    fromOffsets: IndexSet(integer: fromIndex),
                    toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex
                )
            }
        }
        return true
    }

    private func handleBarDrop() -> Bool {
        guard let draggedID = TabManager.draggedTabID else { return false }
        TabManager.draggedTabID = nil
        TabManager.reorderedByGesture = false
        if tabManager.tabs.contains(where: { $0.id == draggedID }) { return true }
        onReceiveTab?(draggedID)
        return true
    }

    // MARK: - Gesture Reorder

    /// Called on every DragGesture.onChanged. Moves the tab one slot when the
    /// cursor crosses half a row-height boundary — the vertical counterpart of
    /// the horizontal bar's Chrome-style reorder.
    private func reorderOnDrag(tab: Tab, y: CGFloat) {
        if draggingTabID == nil {
            draggingTabID = tab.id
            lastReorderY = y
            TabManager.draggedTabID = tab.id
        }
        guard draggingTabID == tab.id else { return }

        let dy = y - lastReorderY
        let threshold = rowStride * 0.5
        guard abs(dy) >= threshold else { return }

        // SwiftUI's global space is top-leading (unlike AppKit's screen
        // coords), so dy > 0 is a downward drag → a higher array index.
        let direction = dy > 0 ? 1 : -1
        guard let fromIndex = tabManager.tabs.firstIndex(where: { $0.id == tab.id }) else { return }

        // Keep regular tabs from sliding into the pinned section
        let firstRegularIndex = tabManager.tabs.firstIndex(where: { !$0.isPinned }) ?? 0
        let toIndex = fromIndex + direction
        guard toIndex >= firstRegularIndex && toIndex < tabManager.tabs.count else { return }

        tabManager.tabs.move(
            fromOffsets: IndexSet(integer: fromIndex),
            toOffset: direction > 0 ? toIndex + 1 : toIndex
        )
        // Shift reference point so next threshold is relative to the new slot
        lastReorderY += CGFloat(direction) * rowStride
    }

    private func finishDrag() {
        draggingTabID = nil
        TabManager.reorderedByGesture = true
        // draggedTabID stays set so a cross-window onDrop can still read it.
        // Clean up after a short window in case no drop event fires.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            TabManager.reorderedByGesture = false
            TabManager.draggedTabID = nil
        }
    }

    /// Fires when the user drags a tab out of the bar — tears it off into a new
    /// window (or re-attaches to the window under the cursor via onDetachTab).
    private func triggerDetach(tab: Tab) {
        draggingTabID = nil
        TabManager.draggedTabID = nil
        TabManager.reorderedByGesture = false
        onDetachTab?(tab)
    }

    // MARK: - Tear-off Ghost Window

    /// Creates the floating ghost window and positions it at the current cursor location.
    private func showGhostWindow(for tab: Tab) {
        hideGhostWindow() // guard against a stray leftover instance
        let window = GhostTabWindow(tab: tab)
        window.move(toScreenPoint: NSEvent.mouseLocation)
        window.orderFrontRegardless()
        ghostWindow = window
    }

    /// Orders out and releases the floating ghost window. Safe to call multiple
    /// times or when no ghost window exists — every drag-end path routes
    /// through this so a ghost can never be left on screen.
    private func hideGhostWindow() {
        ghostWindow?.orderOut(nil)
        ghostWindow = nil
    }

    @ViewBuilder
    private func verticalCollapsedGroupHeader(_ group: TabGroup) -> some View {
        let count = tabManager.tabs.filter { $0.group?.id == group.id }.count
        let isRenaming = renamingGroupID == group.id

        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
            Circle()
                .fill(group.swiftUIColor)
                .frame(width: 8, height: 8)
            if !isCompact {
                if isRenaming {
                    TextField("Group name", text: $renameDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .focused($focusedRenameGroupID, equals: group.id)
                        .onAppear {
                            DispatchQueue.main.async { focusedRenameGroupID = group.id }
                        }
                        .onSubmit { commitRename(of: group) }
                        .onExitCommand { cancelRename() }
                } else {
                    Text("\(group.name) (\(count))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // Double-click edits the name in place; single click keeps its
        // existing collapse/expand meaning (delayed only by double-click
        // disambiguation). Compact mode shows no name, so no edit there.
        .onTapGesture(count: 2) {
            if !isCompact { beginRename(of: group) }
        }
        .onTapGesture {
            if !isRenaming { tabManager.toggleGroupCollapsed(group) }
        }
        .contextMenu {
            Button("Expand Group") {
                tabManager.toggleGroupCollapsed(group)
            }
            if !group.isLocked {
                Button("Rename Group") { beginRename(of: group) }
            }
            Button("Delete Group") {
                tabManager.deleteGroup(group)
            }
        }
        .onChange(of: focusedRenameGroupID) { oldFocus, newFocus in
            // Clicking away (blur) commits, matching Enter. The old-value
            // guard keeps a *different* header's focus change — or an edit
            // already ended by Enter/Esc — from touching this group.
            if oldFocus == group.id, newFocus != group.id, renamingGroupID == group.id {
                commitRename(of: group)
            }
        }
        .onDisappear {
            // The header only exists while the group is collapsed — if it
            // goes away mid-edit (Expand Group, delete, scrolled out of the
            // lazy list), the blur observer above dies with it. Resolve the
            // edit here so the group can never reappear stuck in edit mode
            // with a stale draft.
            if renamingGroupID == group.id {
                commitRename(of: group)
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Inline Group Rename

    /// Double-click (or the context menu) turns the header's name label into
    /// a text field. Locked groups (the AI group) never enter edit mode, and
    /// a group already being edited is left alone — the double-tap gesture
    /// also covers the text field itself, so select-a-word inside it must not
    /// reset the draft and wipe what the user typed.
    private func beginRename(of group: TabGroup) {
        guard !group.isLocked, renamingGroupID != group.id else { return }
        renameDraft = group.name
        renamingGroupID = group.id
    }

    /// Commits on Enter or blur — an empty/whitespace draft is rejected by
    /// `renameGroup`, so the previous name survives.
    private func commitRename(of group: TabGroup) {
        guard renamingGroupID == group.id else { return }
        tabManager.renameGroup(group, to: renameDraft)
        cancelRename()
    }

    private func cancelRename() {
        renamingGroupID = nil
        focusedRenameGroupID = nil
    }

}

// Separate view so @State works correctly for hover tracking
private struct VerticalTabItemView: View {
    @Bindable var tab: Tab
    @Bindable var tabManager: TabManager
    /// Icons-only rendering (collapsed and not hover-expanded).
    let isCompact: Bool
    var onNewTab: (() -> Void)? = nil
    var onDetachTab: ((Tab) -> Void)? = nil

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
        .onHover { hovering in
            isHovering = hovering
        }
        .padding(.horizontal, 4)
        .contextMenu {
            // Same menu the horizontal bar offers (TabItemView), with the
            // vertical-specific "Below" wording for the positional action.
            Button("New Tab") { onNewTab?() }
            Divider()
            Button("Reload") { tab.reload() }
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
            Menu("Tab Group") {
                Button("Add to New Group") {
                    _ = tabManager.addTabToNewGroup(tab)
                }
                if !tabManager.tabGroups.isEmpty {
                    Divider()
                    ForEach(tabManager.tabGroups) { group in
                        Button {
                            tabManager.addTabToGroup(tab, group: group)
                        } label: {
                            HStack {
                                Circle()
                                    .fill(group.swiftUIColor)
                                    .frame(width: 8, height: 8)
                                Text(group.name)
                            }
                        }
                    }
                }
                if tab.group != nil {
                    Divider()
                    Button("Remove from Group") {
                        tabManager.removeTabFromGroup(tab)
                    }
                }
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
            if tab.isMuted {
                Button("Unmute Tab") { tab.isMuted = false }
            } else {
                Button("Mute Tab") { tab.isMuted = true }
            }
            Divider()
            Button("Close Tab") { tabManager.closeTab(tab) }
            Button("Close Other Tabs") { tabManager.closeOtherTabs(tab) }
            Button("Close Tabs Below") { tabManager.closeTabsToRight(of: tab) }
        }
    }
}

