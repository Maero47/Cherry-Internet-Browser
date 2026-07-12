//
//  TabItemView.swift
//  Internet Browser
//

import SwiftUI

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
    @State private var showPreview = false
    @State private var previewTask: Task<Void, Never>?

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
                }
                .buttonStyle(.plain)
                .frame(width: 14, height: 14)
                .help("Unmute Tab")
            }

            // Close button (always in layout to prevent jumps, opacity-controlled)
            if !tab.isPinned {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 16, height: 16)
                .background(
                    Circle()
                        .fill(Color.gray.opacity(0.2))
                        .opacity(isHovering ? 1 : 0)
                )
                .opacity(isHovering || isSelected ? 1 : 0)
                .animation(.easeInOut(duration: 0.1), value: isHovering)
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
            if hovering {
                previewTask?.cancel()
                previewTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    guard !Task.isCancelled, isHovering else { return }
                    showPreview = true
                }
            } else {
                previewTask?.cancel()
                showPreview = false
            }
        }
        .popover(isPresented: $showPreview, arrowEdge: .bottom) {
            tabPreviewPopover
        }
        .onTapGesture {
            onSelect()
        }
        .contextMenu {
            tabContextMenu
        }
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
    private var tabPreviewPopover: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tab.displayTitle)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
            if let url = tab.url {
                Text(url.absoluteString)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if tab.isSleeping {
                Text("Tab is sleeping")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
        }
        .padding(8)
        .frame(maxWidth: 300)
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
