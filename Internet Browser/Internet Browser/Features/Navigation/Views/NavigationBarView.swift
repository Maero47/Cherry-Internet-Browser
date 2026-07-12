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
    var onAutoFill: (() -> Void)? = nil
    var loginFormDetected: Bool = false
    var isPrivateMode: Bool = false
    var onTogglePrivateMode: (() -> Void)? = nil
    var showWindowDragArea: Bool = false
    var onPrint: (() -> Void)? = nil
    var onToggleReaderMode: (() -> Void)? = nil
    var showReaderMode: Bool = false
    var onPictureInPicture: (() -> Void)? = nil
    var onScreenshot: (() -> Void)? = nil
    var onQRCode: (() -> Void)? = nil
    var isViewingPDF: Bool = false
    var onSavePDF: (() -> Void)? = nil
    var onToggleFocusMode: (() -> Void)? = nil
    /// Whether to show the per-extension toolbar buttons in this nav bar.
    /// `false` for the unfocused pane in split view, so an extension's
    /// buttons/popup only ever appear once, reflecting the FOCUSED pane's tab.
    var showExtensionButtons: Bool = true

    /// Computed from the current tab's URL so it always reflects the correct per-domain state
    private var isAdBlockPaused: Bool {
        SettingsManager.shared.isAdBlockPaused(for: tab.url)
    }

    @State private var addressText: String = ""
    @State private var isEditing: Bool = false
    @State private var suggestService = SearchSuggestService()
    @State private var selectedSuggestionIndex: Int? = nil

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
                    // If a suggestion is selected via keyboard, use that instead
                    if let idx = selectedSuggestionIndex,
                       idx < suggestService.suggestions.count {
                        let item = suggestService.suggestions[idx]
                        navigateToSuggestion(item)
                    } else {
                        isEditing = false
                        selectedSuggestionIndex = nil
                        suggestService.clear()
                        onNavigate(input)
                    }
                },
                onFocus: {
                    isEditing = true
                    selectedSuggestionIndex = nil
                    // Update address text to full URL when focused
                    addressText = tab.url?.absoluteString ?? ""
                },
                onTextChange: { newText in
                    selectedSuggestionIndex = nil
                    suggestService.fetch(query: newText)
                },
                onBlur: {
                    // Delay so click on a suggestion can register before dismissing
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        isEditing = false
                        selectedSuggestionIndex = nil
                        suggestService.clear()
                    }
                },
                onArrowDown: {
                    let count = min(suggestService.suggestions.count, 8)
                    guard count > 0 else { return }
                    if let current = selectedSuggestionIndex {
                        selectedSuggestionIndex = (current + 1) % count
                    } else {
                        selectedSuggestionIndex = 0
                    }
                },
                onArrowUp: {
                    let count = min(suggestService.suggestions.count, 8)
                    guard count > 0 else { return }
                    if let current = selectedSuggestionIndex {
                        selectedSuggestionIndex = (current - 1 + count) % count
                    } else {
                        selectedSuggestionIndex = count - 1
                    }
                },
                onEscape: {
                    selectedSuggestionIndex = nil
                    suggestService.clear()
                }
            )
            .frame(maxWidth: .infinity)
            .overlay(alignment: .top) {
                if isEditing && !suggestService.suggestions.isEmpty {
                    OmniboxSuggestionsView(
                        suggestions: suggestService.suggestions,
                        selectedIndex: selectedSuggestionIndex,
                        onSelect: { item in
                            navigateToSuggestion(item)
                        }
                    )
                    .offset(y: 36) // position below the omnibox
                }
            }
            .zIndex(1)

            // Extension toolbar buttons — one per loaded extension, reflecting this tab
            if showExtensionButtons {
                extensionButtons
            }

            // Action buttons
            actionButtons
        }
        .padding(.leading, verticalTabsCollapsedPadding)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .padding(.top, showWindowDragArea ? 6 : 0)
        .background {
            ZStack {
                Rectangle().fill(.bar)
                if isPrivateMode { Color.purple.opacity(0.12) }
            }
        }
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

    private func navigateToSuggestion(_ item: SuggestionItem) {
        isEditing = false
        selectedSuggestionIndex = nil
        suggestService.clear()
        switch item {
        case .history(_, let url):
            addressText = url.absoluteString
            onNavigate(url.absoluteString)
        case .search(let text):
            addressText = text
            onNavigate(text)
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
    private var extensionButtons: some View {
        let extensions = ExtensionManager.shared.loadedExtensions
        if !extensions.isEmpty {
            HStack(spacing: 2) {
                ForEach(extensions) { loaded in
                    ExtensionToolbarButton(loaded: loaded, tab: tab)
                }
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

            // Save PDF button — appears when viewing a PDF
            if isViewingPDF, let onSavePDF = onSavePDF {
                Button(action: onSavePDF) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: AppConstants.UI.toolbarIconSize, weight: .medium))
                        .foregroundStyle(SettingsManager.shared.accentColor)
                }
                .buttonStyle(ToolbarButtonStyle())
                .help("Save PDF")
            }

            // Password auto-fill key icon
            if loginFormDetected, let onAutoFill = onAutoFill {
                Button(action: onAutoFill) {
                    Image(systemName: "key.fill")
                        .font(.system(size: AppConstants.UI.toolbarIconSize, weight: .medium))
                        .foregroundStyle(SettingsManager.shared.accentColor)
                }
                .buttonStyle(ToolbarButtonStyle())
                .help("Auto-fill Password (Cmd+\\)")
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

            // Focus mode button
            if let onToggleFocusMode = onToggleFocusMode {
                let isFocusOn = FocusModeManager.shared.focusModeEnabled
                Button(action: onToggleFocusMode) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: AppConstants.UI.toolbarIconSize, weight: .medium))
                        .foregroundStyle(isFocusOn ? SettingsManager.shared.accentColor : .primary)
                        .symbolVariant(isFocusOn ? .fill : .none)
                }
                .buttonStyle(ToolbarButtonStyle())
                .help(isFocusOn ? "Focus Mode On — click to disable (Cmd+Shift+F)" : "Enable Focus Mode (Cmd+Shift+F)")
            }

            // Reader mode button
            if let onToggleReaderMode = onToggleReaderMode {
                Button(action: onToggleReaderMode) {
                    Image(systemName: showReaderMode ? "book.fill" : "book")
                        .font(.system(size: AppConstants.UI.toolbarIconSize, weight: .medium))
                        .foregroundStyle(showReaderMode ? SettingsManager.shared.accentColor : .primary)
                }
                .buttonStyle(ToolbarButtonStyle())
                .help("Reader Mode (Cmd+Shift+R)")
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
                    onPrint?()
                } label: {
                    Label("Print Page", systemImage: "printer")
                }

                Button {
                    onPictureInPicture?()
                } label: {
                    Label("Picture in Picture", systemImage: "pip.fill")
                }

                Button {
                    onScreenshot?()
                } label: {
                    Label("Take Screenshot", systemImage: "camera")
                }

                Button {
                    onQRCode?()
                } label: {
                    Label("QR Code", systemImage: "qrcode")
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
