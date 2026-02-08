//
//  TabItemView.swift
//  Internet Browser
//

import SwiftUI

struct TabItemView: View {
    @Bindable var tab: Tab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            // Favicon
            faviconView
                .frame(width: 16, height: 16)

            // Title (hidden for pinned tabs)
            if !tab.isPinned {
                Text(tab.displayTitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Close button (hidden for pinned tabs, visible on hover)
            if !tab.isPinned && (isHovering || isSelected) {
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
                .help("Close Tab (Cmd+W)")
            }
        }
        .padding(.horizontal, tab.isPinned ? 8 : 12)
        .padding(.vertical, 6)
        .frame(width: tab.isPinned ? 40 : nil)
        .frame(minWidth: tab.isPinned ? nil : AppConstants.UI.minTabWidth)
        .frame(maxWidth: tab.isPinned ? nil : AppConstants.UI.maxTabWidth)
        .background(tabBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppConstants.UI.tabCornerRadius))
        .onHover { hovering in
            isHovering = hovering
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
    private var tabContextMenu: some View {
        Button("New Tab") {
            // Will be handled by parent
        }
        Divider()
        Button("Reload") {
            tab.reload()
        }
        Button("Duplicate Tab") {
            // Will be handled by parent
        }
        if tab.isPinned {
            Button("Unpin Tab") {
                // Will be handled by parent
            }
        } else {
            Button("Pin Tab") {
                // Will be handled by parent
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
            // Will be handled by parent
        }
        Button("Close Tabs to the Right") {
            // Will be handled by parent
        }
    }
}
