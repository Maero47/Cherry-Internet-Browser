//
//  NavigationBarView.swift
//  Internet Browser
//

import SwiftUI

struct NavigationBarView: View {
    @Bindable var tab: Tab
    var isBookmarked: Bool = false
    let onNavigate: (String) -> Void
    let onBack: () -> Void
    let onForward: () -> Void
    let onReload: () -> Void
    let onStop: () -> Void
    let onHome: () -> Void
    var onBookmark: (() -> Void)? = nil
    var onToggleHistory: (() -> Void)? = nil
    var onToggleBookmarks: (() -> Void)? = nil

    @State private var addressText: String = ""
    @State private var isEditing: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            // Navigation buttons
            navigationButtons

            // Omnibox
            OmniboxView(
                text: $addressText,
                isLoading: tab.isLoading,
                isSecure: tab.url?.scheme == "https",
                onSubmit: { input in
                    isEditing = false
                    onNavigate(input)
                },
                onFocus: {
                    isEditing = true
                    // Update address text to full URL when focused
                    addressText = tab.url?.absoluteString ?? ""
                }
            )
            .frame(maxWidth: .infinity)

            // Action buttons
            actionButtons
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: tab.url) { _, newURL in
            // Update display text when URL changes (show host when not editing)
            if !isEditing {
                addressText = newURL?.host ?? newURL?.absoluteString ?? ""
            }
        }
        .onChange(of: tab.id) { _, _ in
            // Reset when tab changes
            isEditing = false
            addressText = tab.url?.host ?? tab.url?.absoluteString ?? ""
        }
        .onAppear {
            addressText = tab.url?.host ?? tab.url?.absoluteString ?? ""
        }
    }

    @ViewBuilder
    private var navigationButtons: some View {
        HStack(spacing: 2) {
            // Back button
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: AppConstants.UI.toolbarIconSize, weight: .medium))
            }
            .buttonStyle(ToolbarButtonStyle())
            .disabled(!tab.canGoBack)
            .help("Go Back (Cmd+[)")

            // Forward button
            Button(action: onForward) {
                Image(systemName: "chevron.right")
                    .font(.system(size: AppConstants.UI.toolbarIconSize, weight: .medium))
            }
            .buttonStyle(ToolbarButtonStyle())
            .disabled(!tab.canGoForward)
            .help("Go Forward (Cmd+])")

            // Reload/Stop button
            if tab.isLoading {
                Button(action: onStop) {
                    Image(systemName: "xmark")
                        .font(.system(size: AppConstants.UI.toolbarIconSize, weight: .medium))
                }
                .buttonStyle(ToolbarButtonStyle())
                .help("Stop Loading (Esc)")
            } else {
                Button(action: onReload) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: AppConstants.UI.toolbarIconSize, weight: .medium))
                }
                .buttonStyle(ToolbarButtonStyle())
                .help("Reload Page (Cmd+R)")
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 2) {
            // Home button
            Button(action: onHome) {
                Image(systemName: "house")
                    .font(.system(size: AppConstants.UI.toolbarIconSize, weight: .medium))
            }
            .buttonStyle(ToolbarButtonStyle())
            .help("Go Home")

            // Bookmark button
            if let onBookmark = onBookmark {
                Button(action: onBookmark) {
                    Image(systemName: isBookmarked ? "star.fill" : "star")
                        .font(.system(size: AppConstants.UI.toolbarIconSize, weight: .medium))
                        .foregroundStyle(isBookmarked ? Color.yellow : .primary)
                }
                .buttonStyle(ToolbarButtonStyle())
                .help("Add Bookmark (Cmd+D)")
            }

            // History button
            if let onToggleHistory = onToggleHistory {
                Button(action: onToggleHistory) {
                    Image(systemName: "clock")
                        .font(.system(size: AppConstants.UI.toolbarIconSize, weight: .medium))
                }
                .buttonStyle(ToolbarButtonStyle())
                .help("History (Cmd+Y)")
            }

            // Bookmarks button
            if let onToggleBookmarks = onToggleBookmarks {
                Button(action: onToggleBookmarks) {
                    Image(systemName: "book")
                        .font(.system(size: AppConstants.UI.toolbarIconSize, weight: .medium))
                }
                .buttonStyle(ToolbarButtonStyle())
                .help("Bookmarks (Cmd+Shift+B)")
            }

            // Downloads button (placeholder)
            Button(action: {}) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: AppConstants.UI.toolbarIconSize, weight: .medium))
            }
            .buttonStyle(ToolbarButtonStyle())
            .help("Downloads")
        }
    }
}

struct ToolbarButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(configuration.isPressed ? Color.gray.opacity(0.2) : Color.clear)
            )
            .foregroundStyle(isEnabled ? .primary : .tertiary)
            .contentShape(Rectangle())
    }
}
