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
    /// Dragging a tab into this window's left/right content edge opens split
    /// view with the tab on that edge, instead of tearing it into a new window.
    var onSplitOnEdge: ((Tab, Edge) -> Void)? = nil

    /// ID of the tab currently being reordered via DragGesture
    @State private var draggingTabID: UUID? = nil
    /// Reference X position (global) used to compute cross-boundary reorders
    @State private var lastReorderX: CGFloat = 0
    /// Token of the drag session this bar opened on `TabManager`, so the
    /// deferred cleanup can only ever clear its OWN session (see `finishDrag`).
    @State private var dragToken: Int = 0

    /// Tear-off ghost state — when the tab is dragged out of the bar it floats freely
    @State private var isTearingOff: Bool = false
    @State private var tearOffTabID: UUID? = nil
    @State private var tearOffStartTranslation: CGSize = .zero
    /// Floating on-screen-anywhere ghost window shown while tearing a tab off.
    /// Lives outside the SwiftUI view hierarchy so it isn't clipped to the window bounds.
    @State private var ghostWindow: GhostTabWindow? = nil

    /// Inline group rename: the chip whose name is currently an edit field.
    @State private var renamingGroupID: UUID? = nil
    @State private var renameDraft: String = ""
    @FocusState private var focusedRenameGroupID: UUID?

    private let pinnedTabWidth: CGFloat = 40
    private let tabSpacing: CGFloat = 2
    private let leadingPadding: CGFloat = 76
    private let leadingPaddingFullScreen: CGFloat = 8
    private let newTabButtonWidth: CGFloat = 44
    /// Rough width reserved per group header pill when dividing the remaining
    /// space among regular tabs — the pill hugs its text, so this is only an
    /// estimate that keeps tabs shrinking instead of pushing "+" off-screen.
    private let groupPillEstimatedWidth: CGFloat = 84

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
            let stripItems = TabStripLayout.regularItems(for: tabManager.tabs)
            let pillCount = stripItems.filter {
                if case .groupHeader = $0 { return true } else { return false }
            }.count
            let leading = isFullScreen ? leadingPaddingFullScreen : leadingPadding
            let pinnedSpace = CGFloat(pinned.count) * (pinnedTabWidth + tabSpacing)
            let pillSpace = CGFloat(pillCount) * (groupPillEstimatedWidth + tabSpacing)
            let minTabWidth: CGFloat = 52
            let availableForRegular = geometry.size.width - leading - pinnedSpace - pillSpace - newTabButtonWidth - CGFloat(max(0, regular.count - 1)) * tabSpacing
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

                    // Regular strip: every group's persistent header pill sits
                    // immediately before that group's run of tabs; collapsed
                    // groups contribute just the pill.
                    ForEach(stripItems) { item in
                        switch item {
                        case .groupHeader(let group):
                            groupHeaderPill(group)
                        case .tab(let tab):
                            tabItem(for: tab, width: regularTabWidth)
                        }
                    }
                }
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: tabManager.tabs.map(\.id))
                // Collapsing/expanding a group changes the items without
                // touching tab identity — key the same spring to it so the
                // group's tabs hide/show with the familiar motion.
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: tabManager.tabGroups.map(\.isCollapsed))

                Button(action: onNewTab) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        // Without an explicit content shape the plain button's
                        // hit region is only the glyph itself, so clicks in the
                        // empty part of the 28×28 slot did nothing.
                        .contentShape(Rectangle())
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
        // Safety net: if the whole tab bar is removed from the hierarchy mid-drag
        // (e.g. it's conditionally hidden when entering video fullscreen), `onEnded`
        // never fires — this guarantees the floating ghost window still gets torn down.
        .onDisappear {
            hideGhostWindow()
        }
    }

    // MARK: - Tab Item with Gesture Reorder

    @ViewBuilder
    private func tabItem(for tab: Tab, width: CGFloat) -> some View {
        let isDragging = draggingTabID == tab.id
        let isTearingOffThisTab = isTearingOff && tearOffTabID == tab.id

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
            },
            isSplitActive: tabManager.isSplitActive,
            onOpenInSplitView: { tabManager.openSplit(with: tab.id) },
            onCloseSplitView: { tabManager.closeSplit() },
            isPaired: tabManager.isSplitActive &&
                (tabManager.selectedTabID == tab.id || tabManager.secondarySelectedTabID == tab.id)
        )
        // Dim the slot when the tab is floating as a ghost
        .opacity(isTearingOffThisTab ? 0.35 : 1.0)
        // Subtle lift effect while reordering
        .scaleEffect(isDragging ? CGSize(width: 1.0, height: 1.05) : .init(width: 1, height: 1))
        .shadow(color: isDragging ? .black.opacity(0.22) : .clear, radius: 8, y: 3)
        .zIndex(isDragging || isTearingOffThisTab ? 2 : 0)
        .animation(.spring(response: 0.15, dampingFraction: 0.85), value: isDragging)
        // The tear-off ghost is a real NSWindow (see `ghostWindow` below) so it can
        // render outside this window's bounds — a SwiftUI overlay would be clipped to it.
        // The gesture starts once the pointer has travelled `dragActivationDistance`
        // (Chrome-like) and then reorders in real time. It used to start after 2 px:
        // a physical mouse slides that far during an ordinary click, so the drag
        // recognised mid-click and could cancel the tab's tap — the click was simply
        // lost. Above the threshold the press is unambiguously a drag, and the tab
        // item's click handling stands down for exactly the same distance.
        // Vertical drag > 30 pt switches to free "tear-off" mode with a ghost that floats.
        .simultaneousGesture(
            DragGesture(minimumDistance: TabInteraction.dragActivationDistance, coordinateSpace: .global)
                .onChanged { value in
                    guard !tab.isPinned else { return }

                    // Already in tear-off mode — move the floating ghost window and return
                    if isTearingOff && tearOffTabID == tab.id {
                        ghostWindow?.move(toScreenPoint: NSEvent.mouseLocation)
                        return
                    }

                    // Switch to tear-off once the tab is pulled vertically away from the
                    // strip in EITHER direction (up or down). Before, this checked
                    // `translation.height > 30`, so the ghost appeared only when dragging
                    // downward; `abs(...)` makes upward drags tear off too. A pure
                    // horizontal drag keeps a small height, so in-bar reorder is unaffected
                    // (and jitter-based false triggers are avoided — 30pt is well beyond it).
                    if abs(value.translation.height) > 30 {
                        isTearingOff = true
                        tearOffTabID = tab.id
                        tearOffStartTranslation = value.translation
                        draggingTabID = nil          // hand off from reorder to ghost
                        dragToken = TabManager.beginDragSession(for: tab.id)
                        showGhostWindow(for: tab)
                        return
                    }

                    // Horizontal reorder within the tab bar
                    reorderOnDrag(tab: tab, x: value.location.x, tabWidth: width)
                }
                .onEnded { value in
                    // Clean up tear-off ghost state (covers tear-off, re-attach and cancel —
                    // this always runs when the gesture ends, regardless of outcome).
                    if isTearingOff && tearOffTabID == tab.id {
                        isTearingOff = false
                        tearOffTabID = nil
                        tearOffStartTranslation = .zero
                        hideGhostWindow()
                    }

                    guard !tab.isPinned else {
                        finishDrag()
                        return
                    }

                    let mouseLocation = NSEvent.mouseLocation
                    let sourceFrame = tabManager.hostWindow?.frame ?? NSApp.keyWindow?.frame ?? .zero
                    let leftSourceWindow = !sourceFrame.contains(mouseLocation)

                    // Released INSIDE this window, below the tab bar, near the left
                    // or right edge → open split view with this tab on that side
                    // (checked before detach so an edge drop splits instead of
                    // tearing off into a new window).
                    if !leftSourceWindow, onSplitOnEdge != nil, sourceFrame.width > 0 {
                        let relX = mouseLocation.x - sourceFrame.minX
                        let fromTop = sourceFrame.maxY - mouseLocation.y
                        let edgeZone = sourceFrame.width * 0.30
                        if fromTop > AppConstants.UI.tabBarHeight {
                            if relX < edgeZone {
                                onSplitOnEdge?(tab, .leading)
                                finishDrag()
                                return
                            } else if relX > sourceFrame.width - edgeZone {
                                onSplitOnEdge?(tab, .trailing)
                                finishDrag()
                                return
                            }
                        }
                    }

                    // Detach on release if the cursor left the source window (any
                    // direction) or the tab was pulled vertically far enough — up OR
                    // down, matching the symmetric tear-off ghost trigger above so an
                    // upward tear-off actually detaches instead of snapping back.
                    if leftSourceWindow || abs(value.translation.height) > 44 {
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
    /// cursor crosses half a tab-width boundary — exactly how Chrome does it.
    private func reorderOnDrag(tab: Tab, x: CGFloat, tabWidth: CGFloat) {
        if draggingTabID == nil {
            draggingTabID = tab.id
            lastReorderX = x
            dragToken = TabManager.beginDragSession(for: tab.id)
        }
        guard draggingTabID == tab.id else { return }

        let dx = x - lastReorderX
        let threshold = tabWidth * 0.5
        guard abs(dx) >= threshold else { return }

        let direction = dx > 0 ? 1 : -1
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
        lastReorderX += CGFloat(direction) * tabWidth
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

    /// Fires when the user drags a tab out of the tab bar — tears it off into a new window.
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

    /// Orders out and releases the floating ghost window. Safe to call multiple times
    /// or when no ghost window exists — every drag-end path (tear-off, re-attach,
    /// cancel) routes through this so a ghost can never be left on screen.
    private func hideGhostWindow() {
        ghostWindow?.orderOut(nil)
        ghostWindow = nil
    }

    // MARK: - Group Header Pill

    /// The group's persistent header: a small tinted pill that leads the
    /// group's run of tabs whether the group is expanded or collapsed.
    /// Clicking it toggles collapse (hide/show of the group's tabs);
    /// double-click renames inline.
    @ViewBuilder
    private func groupHeaderPill(_ group: TabGroup) -> some View {
        let count = tabManager.tabs.filter { $0.group?.id == group.id }.count
        let isRenaming = renamingGroupID == group.id
        HStack(spacing: 4) {
            Circle()
                .fill(group.swiftUIColor)
                .frame(width: 8, height: 8)
            if isRenaming {
                TextField("Group name", text: $renameDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .frame(width: 100)
                    .focused($focusedRenameGroupID, equals: group.id)
                    .onAppear {
                        DispatchQueue.main.async { focusedRenameGroupID = group.id }
                    }
                    .onSubmit { commitRename(of: group) }
                    .onExitCommand { cancelRename() }
            } else {
                Text("\(group.name) (\(count))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // Cap the name width so a long group name can't grow the
                    // pill past its width reservation and push the "+" button
                    // off-screen; it truncates instead.
                    .frame(maxWidth: 120)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(group.swiftUIColor.opacity(group.isCollapsed ? 0.22 : 0.14))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .help(group.isCollapsed ? "Show tabs in \(group.name)" : "Hide tabs in \(group.name)")
        // Double-click edits the name in place; single click keeps its
        // existing collapse/expand meaning (delayed only by double-click
        // disambiguation).
        .onTapGesture(count: 2) { beginRename(of: group) }
        .onTapGesture {
            if !isRenaming { tabManager.toggleGroupCollapsed(group) }
        }
        .contextMenu {
            Button(group.isCollapsed ? "Expand Group" : "Collapse Group") {
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
            // guard keeps a *different* pill's focus change — or an edit
            // already ended by Enter/Esc — from touching this group.
            if oldFocus == group.id, newFocus != group.id, renamingGroupID == group.id {
                commitRename(of: group)
            }
        }
        .onDisappear {
            // The pill exists while the group has members — if it goes away
            // mid-edit (delete, last member removed), the blur observer above
            // dies with it. Resolve the edit here so the group can never
            // reappear stuck in edit mode with a stale draft.
            if renamingGroupID == group.id {
                commitRename(of: group)
            }
        }
    }

    // MARK: - Inline Group Rename

    /// Double-click (or the context menu) turns the chip's name label into a
    /// text field. Locked groups (the AI group) never enter edit mode, and a
    /// group already being edited is left alone — the double-tap gesture also
    /// covers the text field itself, so select-a-word inside it must not
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

    @ViewBuilder
    private var tabBarBackground: some View {
        ZStack(alignment: .top) {
            // An imported Firefox theme replaces the material with the
            // header backdrop — opaque frame color plus the theme's header
            // images, which the tab strip shows directly like Firefox does
            // (never in private windows, which keep their purple-tinted bar).
            if !isPrivateMode, FirefoxThemeManager.shared.hasHeaderBackdrop {
                ThemeHeaderBackdropView()
            } else if !isPrivateMode, let themedStrip = FirefoxThemeManager.shared.tabStripBackground {
                Rectangle().fill(themedStrip)
            } else {
                Rectangle().fill(.bar)
                if isPrivateMode { Color.purple.opacity(0.12) }
            }
            // Specular highlight — light catching the top edge of the glass.
            // There is no glass under a theme: the backdrop above is the
            // theme's own header art, and a hardcoded white line composited
            // onto it is the same overdraw as the seam hairline 0.5pt below.
            // Same rule as there — the stock look and private windows (never
            // themed) keep the highlight.
            if isPrivateMode || !FirefoxThemeManager.shared.hasHeaderBackdrop {
                Color.white.opacity(0.12)
                    .frame(height: 1)
            }
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
