//
//  TabItemView.swift
//  Internet Browser
//

import SwiftUI
import AppKit

struct TabItemView: View {
    @Bindable var tab: Tab
    let isSelected: Bool
    var fixedWidth: CGFloat? = nil
    let onSelect: () -> Void
    let onClose: () -> Void
    var onNewTab: (() -> Void)? = nil
    var onDuplicate: (() -> Void)? = nil
    var onPin: (() -> Void)? = nil
    var onCloseOthers: (() -> Void)? = nil
    var onCloseRight: (() -> Void)? = nil
    var onAddToNewGroup: (() -> Void)? = nil
    var onRemoveFromGroup: (() -> Void)? = nil
    var availableGroups: [TabGroup] = []
    var onAddToGroup: ((TabGroup) -> Void)? = nil
    var onDetachTab: (() -> Void)? = nil
    var isSplitActive: Bool = false
    var onOpenInSplitView: (() -> Void)? = nil
    var onCloseSplitView: (() -> Void)? = nil
    /// True when this tab is one of the two tabs currently shown in split view
    /// (primary or secondary pane) — drives the small "paired" badge below.
    var isPaired: Bool = false

    @State private var isHovering = false
    @State private var previewTask: Task<Void, Never>?
    /// Hit rectangles of the row's small buttons, in global space, kept current
    /// by `.onGeometryChange`. A press is claimed by a button only when it is
    /// pressed AND released inside the SAME rectangle — that is exactly when
    /// the button fires — and the tab's own click handling stands down for
    /// those and only those. See `TabInteraction.pressIsConsumedByControl` for
    /// why this is a location and not a remembered hover.
    @State private var closeControlFrame: CGRect = .zero
    @State private var muteControlFrame: CGRect = .zero
    /// Set by whichever of the two click paths (`onTapGesture` or the
    /// press-release fallback) resolves the current press first, so a single
    /// click selects exactly once.
    @State private var didHandleClick = false

    /// Imported Firefox theme overrides — nil for private tabs (never themed)
    /// or when no theme is active, keeping the stock material/hierarchy look.
    private var themedSelectedBackground: Color? {
        tab.isPrivate ? nil : FirefoxThemeManager.shared.selectedTabBackground
    }
    private var themedTitleColor: Color? {
        guard !tab.isPrivate else { return nil }
        let manager = FirefoxThemeManager.shared
        return isSelected ? manager.tabText : manager.tabStripText
    }

    /// The tab strip is the SAME theme header backdrop the toolbar sits on —
    /// one continuous canvas — so a title has exactly the toolbar's problem.
    /// An UNSELECTED tab is the bad case: it paints nothing of its own, so its
    /// title is a flat colour straight on the illustration.
    ///
    /// Deliberately the STRIP's tone and no overlays, the same for every tab
    /// including the selected one. The tabs are a cluster whose members happen
    /// to be separate views, and a tab that solved its own patch of artwork —
    /// its own tone, its own fill, its own opacity — would end up looking
    /// unlike the tab beside it for no reason the user can see. Paired with
    /// `decidedAcrossCluster`, every tab in the row reaches the same answer.
    ///
    /// Nil for private tabs and when no theme is active, which leaves the stock
    /// strip untouched.
    private var titleLegibility: ThemeLegibility? {
        let manager = FirefoxThemeManager.shared
        guard !tab.isPrivate, manager.activeTheme != nil, manager.hasHeaderBackdrop else { return nil }
        return ThemeLegibility(foreground: manager.tabStripText ?? Color.primary)
    }

    var body: some View {
        HStack(spacing: 8) {
            // Favicon
            faviconView
                .frame(width: 16, height: 16)
                .overlay(alignment: .bottomTrailing) {
                    if isPaired {
                        pairedBadge
                    }
                }

            // Title (hidden for pinned tabs or very narrow tabs)
            if !tab.isPinned && (fixedWidth ?? 999) > 100 {
                Text(tab.displayTitle)
                    .font(.system(size: 12))
                    .foregroundStyle(tab.isSleeping
                                     ? AnyShapeStyle(.tertiary)
                                     : AnyShapeStyle(themedTitleColor ?? Color.primary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Mute indicator — click to unmute
            if showsMuteButton {
                Button {
                    handleMutePress()
                } label: {
                    Image(systemName: "speaker.slash.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        // Hit target grows to 20×20; the glyph and the layout
                        // are unchanged.
                        .contentShape(
                            Rectangle().inset(by: TabInteraction.hitTargetInset(forVisualSize: 14))
                        )
                }
                .buttonStyle(.plain)
                .onGeometryChange(for: CGRect.self) { proxy in
                    TabInteraction.hitRect(for: proxy.frame(in: .global), visualSize: 14)
                } action: { muteControlFrame = $0 }
                .help("Unmute Tab")
            }

            // Close button (always in layout to prevent jumps, opacity-controlled)
            if !tab.isPinned {
                Button(action: handleClosePress) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .background(
                            Circle()
                                .fill(Color.gray.opacity(0.2))
                                .opacity(isHovering ? 1 : 0)
                        )
                        // The clickable area (20×20) is bigger than the 16 pt
                        // disc it draws, so a click that lands just off the
                        // glyph still closes the tab instead of falling through
                        // to the tab body (which would select it and look like
                        // the close button "didn't take"). The frame — and so
                        // the tab's layout — is unchanged.
                        .contentShape(
                            Rectangle().inset(by: TabInteraction.hitTargetInset(forVisualSize: 16))
                        )
                }
                .buttonStyle(.plain)
                .opacity(isCloseButtonActive ? 1 : 0)
                // Deliberately still hit-testable while invisible — that is what
                // keeps spam-closing tabs working, because the tab that slides
                // under a stationary pointer starts out un-hovered. What used to
                // make the invisible X a click EATER was its action: it closed
                // nothing and selected nothing. Now an invisible X can't have
                // been aimed at, so a press there means what a press on the tab
                // body means (see `handleClosePress`).
                .animation(.easeInOut(duration: 0.1), value: isHovering)
                .onGeometryChange(for: CGRect.self) { proxy in
                    TabInteraction.hitRect(for: proxy.frame(in: .global), visualSize: 16)
                } action: { closeControlFrame = $0 }
                .help("Close Tab (Cmd+W)")
            }
        }
        .padding(.horizontal, tab.isPinned ? 8 : 12)
        .padding(.vertical, 6)
        .frame(width: fixedWidth ?? (tab.isPinned ? 40 : AppConstants.UI.maxTabWidth))
        .background {
            // The tab's own fill, over the strip's ONE measured surface. The
            // surface is decided from the whole strip and is therefore the same
            // colour and opacity on every tab; a tab is a surface in browser
            // idiom, so a row of identical ones reads as tabs rather than as
            // patches. The selected tab still looks different, because its own
            // fill says it is selected — that is state, not backdrop.
            tabBackground
                .themeLegibilityPlate(
                    titleLegibility,
                    floor: ThemeContrast.textFloor,
                    cornerRadius: AppConstants.UI.tabCornerRadius,
                    measureInset: 4,
                    windowPoints: 60,
                    spread: 0,
                    decidedAcrossCluster: true
                )
        }
        .overlay(alignment: .bottom) {
            // Tab group color indicator
            if let group = tab.group {
                RoundedRectangle(cornerRadius: 1)
                    .fill(group.swiftUIColor)
                    .frame(height: 2)
                    .padding(.horizontal, 4)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: AppConstants.UI.tabCornerRadius))
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .animation(.easeInOut(duration: 0.12), value: isSelected)
        .opacity(tab.isSleeping ? 0.6 : 1.0)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
            previewTask?.cancel()
            if hovering {
                previewTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: TabInteraction.previewDelayNanoseconds)
                    guard !Task.isCancelled, isHovering else { return }
                    TabPreviewPresenter.shared.show(for: tab, at: NSEvent.mouseLocation)
                }
            } else {
                hidePreview()
            }
        }
        .onTapGesture(coordinateSpace: .global) { location in
            // A tap has one location, so both endpoints are that point.
            handleClick(from: location, to: location)
        }
        // Belt-and-braces click path. `onTapGesture` above is a `TapGesture`,
        // and SwiftUI is free to fail a tap once the tab bar's simultaneous
        // reorder `DragGesture` recognises — which is how a click on a tab
        // could vanish. A `DragGesture` never fails: `onEnded` fires on every
        // mouse-up, so we classify the press ourselves and select the tab if
        // the tap didn't. It is `simultaneousGesture`, so it never competes
        // with the close/unmute buttons for their own clicks (those presses are
        // excluded by location, below).
        //
        // `.global` is required, not incidental: it is the space the bar's
        // reorder gesture measures its 8 pt threshold in, and the space the
        // control frames above are captured in. In the default `.local` space
        // the translation would be pointer travel MINUS the tab's own travel —
        // and the tab jumps a whole slot per reorder step — so a finished
        // reorder could read as a click and select the tab it just moved.
        .simultaneousGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { _ in
                    // A new press begins: re-arm the latch deterministically
                    // rather than relying on the async reset in `handleClick`.
                    if didHandleClick { didHandleClick = false }
                    // Pressing the tab dismisses the preview immediately, so
                    // nothing is on screen while the click resolves. Guarded so
                    // a drag doesn't touch state on every mouse-moved event.
                    if previewTask != nil { hidePreview() }
                }
                .onEnded { value in
                    guard TabInteraction.isClick(translation: value.translation) else { return }
                    handleClick(from: value.startLocation, to: value.location)
                }
        )
        .contextMenu {
            tabContextMenu
        }
        .onDisappear {
            hidePreview()
        }
    }

    /// Whether the close button is currently drawn — and so whether a press on
    /// it can have been aimed at it.
    private var isCloseButtonActive: Bool { isHovering || isSelected }

    /// Mirrors the condition that renders the unmute button, so its frame is
    /// only ever consulted while it is actually on screen.
    private var showsMuteButton: Bool {
        tab.isMuted && !tab.isPinned && (fixedWidth ?? 999) > 100
    }

    /// Hit rects of the controls that are currently on screen.
    private var activeControlFrames: [CGRect] {
        var frames: [CGRect] = []
        if !tab.isPinned { frames.append(closeControlFrame) }
        if showsMuteButton { frames.append(muteControlFrame) }
        return frames
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
        hidePreview()
        onSelect()
    }

    /// The close button is clickable even while invisible, so that closing tab
    /// after tab keeps working when the tab under a stationary pointer changes
    /// and its hover state hasn't caught up. While it is invisible the press
    /// cannot have been aimed at it, so it means what a press on the tab body
    /// means: select.
    private func handleClosePress() {
        guard claimPress() else { return }
        hidePreview()
        if isCloseButtonActive {
            onClose()
        } else {
            onSelect()
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

    private func hidePreview() {
        previewTask?.cancel()
        previewTask = nil
        TabPreviewPresenter.shared.hide(for: tab.id)
    }

    @ViewBuilder
    private var faviconView: some View {
        if tab.isLoading {
            ProgressView()
                .scaleEffect(0.5)
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

    /// Small marker shown on tabs currently paired in split view, so the user
    /// can tell at a glance which two tabs are on screen together.
    private var pairedBadge: some View {
        Image(systemName: "rectangle.split.2x1.fill")
            .font(.system(size: 6, weight: .bold))
            .foregroundStyle(SettingsManager.shared.accentColor)
            .padding(2)
            .background(Circle().fill(.regularMaterial))
            .offset(x: 4, y: 4)
    }

    @ViewBuilder
    private var tabBackground: some View {
        if isSelected, let themedSelectedBackground {
            RoundedRectangle(cornerRadius: AppConstants.UI.tabCornerRadius)
                .fill(themedSelectedBackground)
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        } else if isSelected {
            // This branch is also what a theme with header images but no
            // `tab_selected`/`toolbar` color falls into, so the stroke can end
            // up over header art. It stays anyway: it is a rim on the selected
            // tab's OWN material chip — it draws that chip's edge rather than
            // ruling a line across the artwork — and against a busy header
            // image a translucent material with no defined edge is exactly
            // what stops reading as the selected tab. Removing it would cost
            // legibility to fix nothing.
            RoundedRectangle(cornerRadius: AppConstants.UI.tabCornerRadius)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                .overlay {
                    RoundedRectangle(cornerRadius: AppConstants.UI.tabCornerRadius)
                        .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
                }
        } else if isHovering {
            RoundedRectangle(cornerRadius: AppConstants.UI.tabCornerRadius)
                .fill(Color.primary.opacity(0.06))
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private var tabContextMenu: some View {
        Button("New Tab") {
            onNewTab?()
        }
        Divider()
        Button("Reload") {
            tab.reload()
        }
        Button("Duplicate Tab") {
            onDuplicate?()
        }
        if tab.isPinned {
            Button("Unpin Tab") {
                onPin?()
            }
        } else {
            Button("Pin Tab") {
                onPin?()
            }
        }
        Divider()

        // Tab group menu
        Menu("Tab Group") {
            Button("Add to New Group") {
                onAddToNewGroup?()
            }
            if !availableGroups.isEmpty {
                Divider()
                ForEach(availableGroups) { group in
                    Button {
                        onAddToGroup?(group)
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
                    onRemoveFromGroup?()
                }
            }
        }

        Divider()
        Button("Open in New Window") {
            onDetachTab?()
        }
        if isSplitActive {
            Button("Close Split View") {
                onCloseSplitView?()
            }
        } else {
            Button("Open in Split View") {
                onOpenInSplitView?()
            }
        }
        Divider()
        if tab.isMuted {
            Button("Unmute Tab") {
                tab.isMuted = false
            }
        } else {
            Button("Mute Tab") {
                tab.isMuted = true
            }
        }
        Divider()
        Button("Close Tab") {
            onClose()
        }
        Button("Close Other Tabs") {
            onCloseOthers?()
        }
        Button("Close Tabs to the Right") {
            onCloseRight?()
        }
    }
}
