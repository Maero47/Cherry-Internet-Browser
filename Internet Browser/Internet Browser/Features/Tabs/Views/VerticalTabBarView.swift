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
    /// Token of the drag session this bar opened on `TabManager`, so the
    /// deferred cleanup can only ever clear its OWN session (see `finishDrag`).
    @State private var dragToken: Int = 0

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

                    // Kept even on a themed backdrop: `VerticalTabItemView`
                    // renders a pinned tab identically to any other row, so
                    // this inset rule is the ONLY thing showing where the
                    // pinned run ends. It carries information the artwork
                    // cannot, and being inset it reads as list structure
                    // rather than a line ruled across the chrome.
                    if tabManager.tabs.contains(where: { $0.isPinned }) {
                        Divider()
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                    }

                    // Regular strip: every group's persistent header pill sits
                    // immediately above that group's run of tabs; collapsed
                    // groups contribute just the pill.
                    ForEach(TabStripLayout.regularItems(for: tabManager.tabs)) { item in
                        switch item {
                        case .groupHeader(let group):
                            verticalGroupHeaderPill(group)
                        case .tab(let tab):
                            tabItem(for: tab)
                        }
                    }
                }
                .padding(.vertical, 4)
                // Rows slide out of the way live while reordering — the same
                // moving-slots feedback the horizontal bar gives.
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: tabManager.tabs.map(\.id))
                // Collapsing/expanding a group changes the rows without
                // touching tab identity — key the same spring to it so the
                // group's tabs hide/show with the familiar motion.
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: tabManager.tabGroups.map(\.isCollapsed))
            }
            // Accept drops on the scroll area (for drops on empty space)
            .onDrop(of: [.cherryBrowserTab], isTargeted: nil) { providers in
                handleBarDrop()
            }

            // Unlike the pinned separator above, this one runs edge to edge
            // across the sidebar — on a themed backdrop it is a full-bleed
            // line ruled over the header art, the sidebar's version of the
            // tab-strip/toolbar seam. It also carries less: the row below is
            // a glyph-and-label button at the bottom of the bar, outside the
            // scroll area, and reads as a control without a rule above it.
            // Stock look and private windows (never themed) keep it.
            if isPrivateMode || !FirefoxThemeManager.shared.hasHeaderBackdrop {
                Divider()
            }

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
                // Without an explicit content shape the plain button's hit
                // region is only the glyph and label, so clicks anywhere else
                // in the row — most of it — did nothing.
                .contentShape(Rectangle())
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
        // Same flow as the horizontal bar: the gesture starts once the pointer
        // has travelled `dragActivationDistance` (it used to be 2 px, which an
        // ordinary click routinely exceeds — that drag could then cancel the
        // row's tap and swallow the click) and then reorders in real time along
        // Y; pulling the tab SIDEWAYS (either direction) beyond 30 pt switches
        // to free tear-off mode with a floating GhostTabWindow. Click-drags
        // don't scroll a macOS ScrollView, so the simultaneous gesture never
        // fights the list.
        .simultaneousGesture(
            DragGesture(minimumDistance: TabInteraction.dragActivationDistance, coordinateSpace: .global)
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
                        dragToken = TabManager.beginDragSession(for: tab.id)
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
            dragToken = TabManager.beginDragSession(for: tab.id)
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
        let token = dragToken
        dragToken = 0
        // Marks the gesture over while leaving `draggedTabID` readable, because
        // a cross-window `onDrop` arrives after the gesture ends. The deferred
        // clear is the fallback for when no drop ever fires — and it is scoped
        // to this token, so a drag that starts inside the 0.4 s window can no
        // longer have its state wiped out from under it by the previous drag's
        // timer (`TabManager.clearDragSession` ignores stale tokens).
        TabManager.endDragSession(token)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            TabManager.clearDragSession(token)
        }
    }

    /// Fires when the user drags a tab out of the bar — tears it off into a new
    /// window (or re-attaches to the window under the cursor via onDetachTab).
    private func triggerDetach(tab: Tab) {
        draggingTabID = nil
        // The tab is leaving this window: nothing else can consume the drag,
        // so the shared state is cleared right away instead of on a timer.
        TabManager.clearDragSession(dragToken)
        dragToken = 0
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

    /// The group's persistent header row: a small tinted pill that sits above
    /// the group's run of tabs whether the group is expanded or collapsed.
    /// Clicking it toggles collapse (hide/show of the group's tabs);
    /// double-click renames inline.
    @ViewBuilder
    private func verticalGroupHeaderPill(_ group: TabGroup) -> some View {
        let count = tabManager.tabs.filter { $0.group?.id == group.id }.count
        let isRenaming = renamingGroupID == group.id

        HStack(spacing: 6) {
            // Disclosure state: points right when collapsed, down when open.
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(group.isCollapsed ? 0 : 90))
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
                        .lineLimit(1)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(group.swiftUIColor.opacity(group.isCollapsed ? 0.22 : 0.14))
        )
        .contentShape(Rectangle())
        .help(group.isCollapsed ? "Show tabs in \(group.name)" : "Hide tabs in \(group.name)")
        // Double-click edits the name in place; single click keeps its
        // existing collapse/expand meaning (delayed only by double-click
        // disambiguation). Compact mode shows no name, so no edit there.
        .onTapGesture(count: 2) {
            if !isCompact { beginRename(of: group) }
        }
        .onTapGesture {
            if !isRenaming { tabManager.toggleGroupCollapsed(group) }
        }
        .cherryContextMenu {
            CherryMenuItem.action(group.isCollapsed ? "Expand Group" : "Collapse Group") {
                tabManager.toggleGroupCollapsed(group)
            }
            if !group.isLocked {
                CherryMenuItem.action("Rename Group") { beginRename(of: group) }
            }
            CherryMenuItem.action("Delete Group") {
                tabManager.deleteGroup(group)
            }
        }
        .onChange(of: focusedRenameGroupID) { oldFocus, newFocus in
            // Clicking away (blur) commits, matching Enter. The old-value
            // guard keeps a *different* pill's focus change — or an edit
            // already ended by Enter/Esc — from touching this group.
            if oldFocus == group.id, newFocus != group.id, renamingGroupID == group.id {
                commitRename(of: group)
            }
        }
        .onDisappear {
            // The pill exists while the group has members — if it goes away
            // mid-edit (delete, last member removed, scrolled out of the
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
    /// Hit rectangles of the row's small buttons, in global space, kept current
    /// by `.onGeometryChange`. A press is claimed by a button only when it is
    /// pressed AND released inside the SAME rectangle — that is exactly when
    /// the button fires. See `TabInteraction.pressIsConsumedByControl` for why
    /// arbitration is by location rather than by remembered hover.
    @State private var closeControlFrame: CGRect = .zero
    @State private var muteControlFrame: CGRect = .zero
    /// Set by whichever of the two click paths resolves the current press
    /// first, so a single click selects exactly once.
    @State private var didHandleClick = false

    private var isSelected: Bool {
        tabManager.selectedTabID == tab.id
    }

    /// Whether the close button is currently drawn — and so whether a press on
    /// it can have been aimed at it.
    private var isCloseButtonActive: Bool { isHovering || isSelected }

    /// Hit rects of the controls that are currently on screen. Both live inside
    /// the `!isCompact` branch, so a collapsed sidebar has none.
    private var activeControlFrames: [CGRect] {
        guard !isCompact else { return [] }
        var frames = [closeControlFrame]
        if tab.isMuted { frames.append(muteControlFrame) }
        return frames
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
                        handleMutePress()
                    } label: {
                        Image(systemName: "speaker.slash.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .frame(width: 12, height: 12)
                            // Hit target grows to 20×20; the glyph and the row
                            // layout are unchanged.
                            .contentShape(
                                Rectangle().inset(by: TabInteraction.hitTargetInset(forVisualSize: 12))
                            )
                    }
                    .buttonStyle(.plain)
                    .onGeometryChange(for: CGRect.self) { proxy in
                        TabInteraction.hitRect(for: proxy.frame(in: .global), visualSize: 12)
                    } action: { muteControlFrame = $0 }
                    .help("Unmute Tab")
                }

                // Close button (always in layout, opacity-controlled)
                Button {
                    handleClosePress()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        // Clickable across a full 20×20 — well beyond the glyph
                        // — so a slightly-off click still closes the tab
                        // instead of falling through to the row and merely
                        // selecting it. The row's layout is unchanged.
                        .contentShape(
                            Rectangle().inset(by: TabInteraction.hitTargetInset(forVisualSize: 14))
                        )
                }
                .buttonStyle(.plain)
                .opacity(isCloseButtonActive ? 1 : 0)
                // Deliberately still hit-testable while invisible — that keeps
                // closing row after row working when the row under a stationary
                // pointer changes before its hover state catches up. What made
                // the invisible X a click EATER was its action, and that is what
                // changed: see `handleClosePress`.
                .animation(.easeInOut(duration: 0.1), value: isHovering)
                .onGeometryChange(for: CGRect.self) { proxy in
                    TabInteraction.hitRect(for: proxy.frame(in: .global), visualSize: 14)
                } action: { closeControlFrame = $0 }
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
        .onTapGesture(coordinateSpace: .global) { location in
            // A tap has one location, so both endpoints are that point.
            handleClick(from: location, to: location)
        }
        // Belt-and-braces click path — see the fuller comment in `TabItemView`:
        // a `TapGesture` can be failed by the sidebar's simultaneous reorder
        // `DragGesture`, a `DragGesture` never is, so this guarantees the click
        // resolves. `.global` matches both the reorder gesture's threshold and
        // the control frames above; in `.local` space a finished reorder (the
        // row jumps a full `rowStride` per step) could read as a click.
        .simultaneousGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { _ in
                    // A new press begins: re-arm the latch deterministically.
                    if didHandleClick { didHandleClick = false }
                }
                .onEnded { value in
                    guard TabInteraction.isClick(translation: value.translation) else { return }
                    handleClick(from: value.startLocation, to: value.location)
                }
        )
        .onHover { hovering in
            isHovering = hovering
        }
        .padding(.horizontal, 4)
        .cherryContextMenu {
            // Same menu the horizontal bar offers (TabItemView), with the
            // vertical-specific "Below" wording for the positional action.
            CherryMenuItem.action("New Tab") { onNewTab?() }
            CherryMenuItem.separator
            CherryMenuItem.action("Reload") { tab.reload() }
            CherryMenuItem.action("Duplicate Tab") {
                let dup = tabManager.duplicateTab(tab)
                if let url = tab.url { dup.loadURL(url) }
            }
            CherryMenuItem.action(tab.isPinned ? "Unpin Tab" : "Pin Tab") {
                if tab.isPinned { tabManager.unpinTab(tab) } else { tabManager.pinTab(tab) }
            }
            CherryMenuItem.separator
            CherryMenuItem.submenu("Tab Group") {
                CherryMenuItem.action("Add to New Group") {
                    _ = tabManager.addTabToNewGroup(tab)
                }
                if !tabManager.tabGroups.isEmpty {
                    CherryMenuItem.separator
                    for group in tabManager.tabGroups {
                        CherryMenuItem.action(group.name, swatch: group.swiftUIColor) {
                            tabManager.addTabToGroup(tab, group: group)
                        }
                    }
                }
                if tab.group != nil {
                    CherryMenuItem.separator
                    CherryMenuItem.action("Remove from Group") {
                        tabManager.removeTabFromGroup(tab)
                    }
                }
            }
            CherryMenuItem.separator
            CherryMenuItem.action("Open in New Window", enabled: tabManager.tabs.count > 1) {
                onDetachTab?(tab)
            }
            if tabManager.isSplitActive {
                CherryMenuItem.action("Close Split View") { tabManager.closeSplit() }
            } else {
                CherryMenuItem.action("Open in Split View") { tabManager.openSplit(with: tab.id) }
            }
            CherryMenuItem.separator
            if tab.isMuted {
                CherryMenuItem.action("Unmute Tab") { tab.isMuted = false }
            } else {
                CherryMenuItem.action("Mute Tab") { tab.isMuted = true }
            }
            CherryMenuItem.separator
            CherryMenuItem.action("Close Tab") { tabManager.closeTab(tab) }
            CherryMenuItem.action("Close Other Tabs") { tabManager.closeOtherTabs(tab) }
            CherryMenuItem.action("Close Tabs Below") { tabManager.closeTabsToRight(of: tab) }
        }
    }

    /// Selects the tab, at most once per press. Both click paths funnel through
    /// here; whichever resolves first wins and the other becomes a no-op. A
    /// press that one of the row's controls will consume — pressed AND released
    /// on the same control — belongs to that control and is ignored here, so
    /// one press can never both close and select. A press that merely starts or
    /// ends on a control still selects, because the control's `Button` needs
    /// both endpoints and therefore will not have fired.
    private func handleClick(from start: CGPoint, to end: CGPoint) {
        guard !TabInteraction.pressIsConsumedByControl(
            start: start, end: end, controlFrames: activeControlFrames
        ) else { return }
        guard claimPress() else { return }
        tabManager.selectTab(tab)
    }

    /// The close button is clickable even while invisible, so that closing row
    /// after row keeps working when the row under a stationary pointer changes
    /// and its hover state hasn't caught up. While it is invisible the press
    /// cannot have been aimed at it, so it means what a press on the row means:
    /// select.
    private func handleClosePress() {
        guard claimPress() else { return }
        if isCloseButtonActive {
            tabManager.closeTab(tab)
        } else {
            tabManager.selectTab(tab)
        }
    }

    private func handleMutePress() {
        guard claimPress() else { return }
        tab.isMuted = false
    }

    /// Takes ownership of the current press, or returns false if some other
    /// path already handled it. Re-arms asynchronously so the latch can never
    /// stick, on top of the deterministic reset at the start of the next press.
    private func claimPress() -> Bool {
        guard !didHandleClick else { return false }
        didHandleClick = true
        DispatchQueue.main.async {
            didHandleClick = false
        }
        return true
    }
}

