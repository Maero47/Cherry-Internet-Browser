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
    /// True while the pointer sits on one of the row's small buttons (close,
    /// unmute). Those buttons own the click; the tab's own click handling steps
    /// aside so a press on the X can never also select the tab. Tracked per
    /// button so moving between them can't leave a stale flag behind.
    @State private var isPointerOnClose = false
    @State private var isPointerOnMute = false
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
            if tab.isMuted && !tab.isPinned && (fixedWidth ?? 999) > 100 {
                Button {
                    tab.isMuted = false
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
                .onHover { isPointerOnMute = $0 }
                .help("Unmute Tab")
            }

            // Close button (always in layout to prevent jumps, opacity-controlled)
            if !tab.isPinned {
                Button(action: onClose) {
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
                // A SwiftUI view at `.opacity(0)` is still hit-testable: while
                // the X was invisible it silently swallowed clicks aimed at the
                // trailing end of an unselected tab, so that tab never got
                // selected. Invisible now means untouchable.
                .allowsHitTesting(isCloseButtonActive)
                .animation(.easeInOut(duration: 0.1), value: isHovering)
                .onHover { isPointerOnClose = $0 }
                .help("Close Tab (Cmd+W)")
            }
        }
        .padding(.horizontal, tab.isPinned ? 8 : 12)
        .padding(.vertical, 6)
        .frame(width: fixedWidth ?? (tab.isPinned ? 40 : AppConstants.UI.maxTabWidth))
        .background(tabBackground)
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
                isPointerOnClose = false
                isPointerOnMute = false
                hidePreview()
            }
        }
        .onTapGesture {
            handleClick()
        }
        // Belt-and-braces click path. `onTapGesture` above is a `TapGesture`,
        // and SwiftUI is free to fail a tap once the tab bar's simultaneous
        // reorder `DragGesture` recognises — which is how a click on a tab
        // could vanish. A `DragGesture` never fails: `onEnded` fires on every
        // mouse-up, so we classify the press ourselves and select the tab if
        // the tap didn't. It is `simultaneousGesture`, so it never competes
        // with the close/unmute buttons for their own clicks (and those are
        // additionally excluded via `isPointerOnControl`).
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    // Pressing the tab dismisses the preview immediately, so
                    // nothing is on screen while the click resolves. Guarded so
                    // a drag doesn't touch state on every mouse-moved event.
                    if previewTask != nil { hidePreview() }
                }
                .onEnded { value in
                    guard TabInteraction.isClick(translation: value.translation) else { return }
                    handleClick()
                }
        )
        .contextMenu {
            tabContextMenu
        }
        .onDisappear {
            hidePreview()
        }
    }

    /// Whether the close button is currently shown — and therefore clickable.
    private var isCloseButtonActive: Bool { isHovering || isSelected }

    /// The pointer is on a control that owns its own click.
    private var isPointerOnControl: Bool { isPointerOnClose || isPointerOnMute }

    /// Selects the tab, at most once per press. Both click paths funnel through
    /// here; whichever resolves first wins and the other becomes a no-op.
    /// `didHandleClick` is cleared on the next press by the tap gesture itself
    /// (SwiftUI delivers `onEnded` for a press before the next press begins).
    private func handleClick() {
        guard !isPointerOnControl, !didHandleClick else { return }
        didHandleClick = true
        hidePreview()
        onSelect()
        // Re-arm for the next click. Deferring by one main-queue hop lets the
        // second of the two paths see the flag and skip.
        DispatchQueue.main.async {
            didHandleClick = false
        }
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
