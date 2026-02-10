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
    var onDownloads: (() -> Void)? = nil
    var onSettings: (() -> Void)? = nil
    var onToggleAdBlock: (() -> Void)? = nil
    var isAdBlockPaused: Bool = false
    var isPrivateMode: Bool = false
    var onTogglePrivateMode: (() -> Void)? = nil
    var showWindowDragArea: Bool = false

    @State private var addressText: String = ""
    @State private var isEditing: Bool = false

    /// Extra leading padding when vertical tabs are collapsed so nav buttons don't overlap traffic lights
    private var verticalTabsCollapsedPadding: CGFloat {
        let settings = SettingsManager.shared
        if settings.useVerticalTabs && settings.verticalTabBarCollapsed {
            return 36  // traffic lights extend ~70pt, collapsed sidebar is 44pt, need ~26pt extra + normal 12
        }
        return 12
    }

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
        .padding(.leading, verticalTabsCollapsedPadding)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .padding(.top, showWindowDragArea ? 6 : 0)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) {
            if showWindowDragArea {
                WindowDragAreaView()
                    .frame(height: 14)
                    .frame(maxWidth: .infinity)
            }
        }
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

            // Ad blocker shield button
            if SettingsManager.shared.adBlockEnabled, let onToggleAdBlock = onToggleAdBlock {
                Button(action: onToggleAdBlock) {
                    Image(systemName: isAdBlockPaused ? "shield.slash" : "shield.checkered")
                        .font(.system(size: AppConstants.UI.toolbarIconSize, weight: .medium))
                        .foregroundStyle(isAdBlockPaused ? .secondary : SettingsManager.shared.accentColor)
                }
                .buttonStyle(ToolbarButtonStyle())
                .help(isAdBlockPaused ? "Ad blocker paused for this site" : "Ad blocker active — click to pause for this site")
            }

            // Incognito mode button
            if let onTogglePrivateMode = onTogglePrivateMode {
                Button(action: onTogglePrivateMode) {
                    Image(systemName: isPrivateMode ? "eye.slash.fill" : "eye.slash")
                        .font(.system(size: AppConstants.UI.toolbarIconSize, weight: .medium))
                        .foregroundStyle(isPrivateMode ? Color.purple : .primary)
                }
                .buttonStyle(ToolbarButtonStyle())
                .help(isPrivateMode ? "Exit Incognito Mode" : "Enter Incognito Mode")
            }

            // 3-dot menu
            Menu {
                Button {
                    onToggleBookmarks?()
                } label: {
                    Label("Bookmarks", systemImage: "book")
                }

                Button {
                    onToggleHistory?()
                } label: {
                    Label("History", systemImage: "clock")
                }

                Button {
                    onDownloads?()
                } label: {
                    Label("Downloads", systemImage: "arrow.down.circle")
                }

                Divider()

                Button {
                    onSettings?()
                } label: {
                    Label("Settings", systemImage: "gear")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: AppConstants.UI.toolbarIconSize, weight: .medium))
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.clear)
                    )
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 28, height: 28)
            .help("Menu")
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
                    .fill(configuration.isPressed ? Color.gray.opacity(0.25) : Color.clear)
            )
            .foregroundStyle(isEnabled ? .primary : .tertiary)
            .scaleEffect(configuration.isPressed ? 0.90 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}
