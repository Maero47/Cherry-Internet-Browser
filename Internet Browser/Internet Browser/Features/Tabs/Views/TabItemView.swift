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

    @State private var isHovering = false
    @State private var showPreview = false
    @State private var previewTask: Task<Void, Never>?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            // Favicon
            faviconView
                .frame(width: 16, height: 16)

            // Title (hidden for pinned tabs or very narrow tabs)
            if !tab.isPinned && (fixedWidth ?? 999) > 100 {
                Text(tab.displayTitle)
                    .font(.system(size: 12))
                    .foregroundStyle(tab.isSleeping ? .tertiary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
        .onDrag {
            showPreview = false
            TabManager.draggedTabID = tab.id
            return tab.itemProvider()
        } preview: {
            // Compact drag preview
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

    @ViewBuilder
    private var tabBackground: some View {
        if isSelected {
            colorScheme == .dark
                ? AppConstants.Colors.selectedTabBackgroundDark
                : AppConstants.Colors.selectedTabBackground
        } else if isHovering {
            Color.gray.opacity(0.15)
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
