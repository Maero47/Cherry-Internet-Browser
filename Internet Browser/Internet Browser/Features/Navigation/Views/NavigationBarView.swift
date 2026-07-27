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
    var onAskThisPage: (() -> Void)? = nil
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

    /// Imported Firefox theme overrides. Both nil when no theme is active or
    /// this is a private window (private windows keep their stock look).
    private var themedToolbarBackground: Color? {
        isPrivateMode ? nil : FirefoxThemeManager.shared.toolbarBackground
    }
    private var themedToolbarText: Color? {
        isPrivateMode ? nil : FirefoxThemeManager.shared.toolbarText
    }

    @State private var addressText: String = ""
    @State private var isEditing: Bool = false
    @State private var suggestService = SearchSuggestService()
    @State private var selectedSuggestionIndex: Int? = nil

    /// Whether THIS window's vertical tab bar is collapsed. Passed in because
    /// the collapse state is per-window (BrowserViewModel) — the value kept in
    /// SettingsManager is only the seed/default for newly opened windows.
    var isVerticalTabBarCollapsed: Bool = false

    /// Incremented by `BrowserContentView` when the "Focus Address Bar" (⌘L)
    /// command targets THIS pane. Forwarded to the omnibox, which takes focus
    /// on every change.
    var focusAddressBarTrigger: Int = 0

    /// Whether to surface loading chrome (omnibox spinner, Stop button).
    /// The covered site stays live behind an internal cherry:// page, but its
    /// loading state must not leak onto the internal page's chrome.
    private var showsLoadingChrome: Bool {
        // The home page is a static internal location — never surface a spinner
        // or Stop button on it, even if a just-released web view's KVO briefly
        // reports loading.
        tab.isLoading && tab.internalPage == nil && !tab.showHomePage
    }

    /// What the omnibox shows when NOT editing: the internal page's full
    /// `cherry://` URL while one is active, the `cherry://newtab` home address
    /// on the home page, else the site's host (the pre-existing resting display).
    private var restingAddress: String {
        if let page = tab.internalPage {
            return page.url.absoluteString
        }
        if tab.showHomePage {
            return CherryPage.newTabURLString
        }
        return tab.url?.host ?? tab.url?.absoluteString ?? ""
    }

    /// The user's toolbar layout, read from the `@Observable` settings
    /// singleton on every body pass — which is what makes a change made in one
    /// window's Settings redraw the nav bar in every open window.
    private var toolbarLayout: (order: [ToolbarItem], hidden: Set<ToolbarItem>) {
        SettingsManager.shared.toolbarLayout
    }

    /// Whether `item`'s own condition to exist holds right now.
    ///
    /// These are the pre-existing per-button conditions, unchanged — a button
    /// is drawn when this holds AND the user hasn't hidden it. The `⋯` menu's
    /// hidden-items section asks the same question, so a hidden button is
    /// offered there exactly when it would have been drawn here.
    private func isAvailable(_ item: ToolbarItem) -> Bool {
        switch item {
        case .askThisPage:
            onAskThisPage != nil && tab.url != nil && tab.internalPage == nil && !tab.showHomePage
        case .home:
            true
        case .bookmark:
            onBookmark != nil
        case .savePDF:
            isViewingPDF && onSavePDF != nil
        case .autoFill:
            loginFormDetected && onAutoFill != nil
        case .adBlock:
            SettingsManager.shared.adBlockEnabled && onToggleAdBlock != nil
        case .focusMode:
            onToggleFocusMode != nil
        case .readerMode:
            onToggleReaderMode != nil
        case .privateMode:
            onTogglePrivateMode != nil
        }
    }

    /// The one place each customisable button's action lives, so the toolbar
    /// button and its `⋯` menu stand-in genuinely run the same closure.
    private func invoke(_ item: ToolbarItem) {
        switch item {
        case .askThisPage: onAskThisPage?()
        case .home: onHome()
        case .bookmark: onBookmark?()
        case .savePDF: onSavePDF?()
        case .autoFill: onAutoFill?()
        case .adBlock: onToggleAdBlock?()
        case .focusMode: onToggleFocusMode?()
        case .readerMode: onToggleReaderMode?()
        case .privateMode: onTogglePrivateMode?()
        }
    }

    /// Extra leading padding when vertical tabs are collapsed so nav buttons don't overlap traffic lights
    private var verticalTabsCollapsedPadding: CGFloat {
        if SettingsManager.shared.useVerticalTabs && isVerticalTabBarCollapsed {
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
                isLoading: showsLoadingChrome,
                // The covered site's URL is preserved while an internal page
                // is shown — don't wear its https lock on a cherry:// location.
                isSecure: tab.internalPage == nil && tab.url?.scheme == "https",
                isPrivateMode: isPrivateMode,
                focusTrigger: focusAddressBarTrigger,
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
                    // Update address text to the full displayed location when
                    // focused — the cherry:// URL while an internal page is
                    // active, else the web URL.
                    addressText = tab.displayURL
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

            // Extension toolbar buttons — one per loaded extension, reflecting
            // this tab. Extensions have no access to private/incognito
            // windows at all (see ExtensionManager.extensionVisibleViewModels),
            // so never show their buttons there, regardless of showExtensionButtons.
            if showExtensionButtons && !isPrivateMode {
                extensionButtons
            }

            // Action buttons
            actionButtons
        }
        // Hierarchical styles (.primary/.secondary) on the buttons resolve
        // against this, so the whole toolbar's icons/text follow the theme's
        // toolbar_text; Color.primary is the stock look when unthemed.
        .foregroundStyle(themedToolbarText ?? Color.primary)
        .padding(.leading, verticalTabsCollapsedPadding)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .padding(.top, showWindowDragArea ? 6 : 0)
        .background {
            ZStack {
                if !isPrivateMode && FirefoxThemeManager.shared.hasHeaderBackdrop {
                    // Firefox compositing: the opaque frame color + header
                    // images back the toolbar, and the theme's own `toolbar`
                    // color (often semi- or fully transparent) is layered on
                    // top — so transparent-toolbar themes show frame/images
                    // through instead of the app's default material.
                    ThemeHeaderBackdropView()
                    if let toolbarOverlay = FirefoxThemeManager.shared.toolbarColor {
                        Rectangle().fill(toolbarOverlay)
                    }
                } else if let themedToolbarBackground {
                    Rectangle().fill(themedToolbarBackground)
                } else {
                    Rectangle().fill(.bar)
                    if isPrivateMode { Color.purple.opacity(0.12) }
                }
            }
        }
        // Right-click the bar — the empty background between the buttons, and
        // the buttons themselves, the way Safari's toolbar behaves — to reach
        // the customisation UI. `contextMenu` answers secondary clicks only,
        // so every left click the buttons and the omnibox used to get still
        // reaches them.
        .contextMenu {
            Button {
                onSettings?()
            } label: {
                Label("Customise Toolbar…", systemImage: "slider.horizontal.3")
            }
        }
        .overlay(alignment: .top) {
            if showWindowDragArea {
                WindowDragAreaView()
                    .frame(height: 14)
                    .frame(maxWidth: .infinity)
            }
        }
        .onChange(of: tab.url) { _, _ in
            // Update display text when URL changes (show host when not editing)
            if !isEditing {
                addressText = restingAddress
            }
        }
        .onChange(of: tab.internalPage) { _, _ in
            // Entering/leaving an internal cherry:// page changes the tab's
            // displayed location even though it isn't a web navigation.
            if !isEditing {
                addressText = restingAddress
            }
        }
        .onChange(of: tab.id) { _, _ in
            // Reset when tab changes
            isEditing = false
            addressText = restingAddress
        }
        .onAppear {
            addressText = restingAddress
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
            if showsLoadingChrome {
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

    /// The customisable action buttons, in the user's order, minus the ones
    /// they have hidden — followed by the always-present `⋯` menu.
    @ViewBuilder
    private var actionButtons: some View {
        let layout = toolbarLayout
        let visible = layout.order.filter { !layout.hidden.contains($0) && isAvailable($0) }
        let overflow = ToolbarLayout.overflowItems(
            order: layout.order,
            hidden: layout.hidden,
            isAvailable: isAvailable
        )

        HStack(spacing: 2) {
            ForEach(visible, id: \.self) { item in
                actionButton(for: item)
            }

            overflowMenu(hiddenItems: overflow)
        }
    }

    /// One customisable button. Each case is the button as it has always been
    /// drawn — same symbol, same state-dependent tint, same tooltip; only the
    /// decision of *whether* and *where* to draw it moved out.
    @ViewBuilder
    private func actionButton(for item: ToolbarItem) -> some View {
        switch item {
        case .askThisPage:
            // Ask This Page (on-device AI) — quick access, first action icon right
            // by the search bar, immediately left of Home. Only on a real web page.
            Button { invoke(.askThisPage) } label: {
                Image(systemName: "sparkles")
                    .font(.system(size: AppConstants.UI.toolbarIconSize, weight: .medium))
                    .foregroundStyle(SettingsManager.shared.accentColor)
            }
            .buttonStyle(ToolbarButtonStyle())
            .help("Ask This Page (Cmd+Shift+K)")

        case .home:
            Button { invoke(.home) } label: {
                Image(systemName: "house")
                    .font(.system(size: AppConstants.UI.toolbarIconSize, weight: .medium))
            }
            .buttonStyle(ToolbarButtonStyle())
            .help("Go Home")

        case .bookmark:
            Button { invoke(.bookmark) } label: {
                Image(systemName: isBookmarked ? "star.fill" : "star")
                    .font(.system(size: AppConstants.UI.toolbarIconSize, weight: .medium))
                    .foregroundStyle(isBookmarked ? Color.yellow : .primary)
            }
            .buttonStyle(ToolbarButtonStyle())
            .help("Add Bookmark (Cmd+D)")

        case .savePDF:
            Button { invoke(.savePDF) } label: {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: AppConstants.UI.toolbarIconSize, weight: .medium))
                    .foregroundStyle(SettingsManager.shared.accentColor)
            }
            .buttonStyle(ToolbarButtonStyle())
            .help("Save PDF")

        case .autoFill:
            Button { invoke(.autoFill) } label: {
                Image(systemName: "key.fill")
                    .font(.system(size: AppConstants.UI.toolbarIconSize, weight: .medium))
                    .foregroundStyle(SettingsManager.shared.accentColor)
            }
            .buttonStyle(ToolbarButtonStyle())
            .help("Auto-fill Password (Cmd+\\)")

        case .adBlock:
            Button { invoke(.adBlock) } label: {
                Image(systemName: isAdBlockPaused ? "shield.slash" : "shield.checkered")
                    .font(.system(size: AppConstants.UI.toolbarIconSize, weight: .medium))
                    .foregroundStyle(isAdBlockPaused ? .secondary : SettingsManager.shared.accentColor)
            }
            .buttonStyle(ToolbarButtonStyle())
            .help(isAdBlockPaused ? "Ad blocker paused for this site" : "Ad blocker active — click to pause for this site")

        case .focusMode:
            let isFocusOn = FocusModeManager.shared.focusModeEnabled
            Button { invoke(.focusMode) } label: {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: AppConstants.UI.toolbarIconSize, weight: .medium))
                    .foregroundStyle(isFocusOn ? SettingsManager.shared.accentColor : .primary)
                    .symbolVariant(isFocusOn ? .fill : .none)
            }
            .buttonStyle(ToolbarButtonStyle())
            .help(isFocusOn ? "Focus Mode On — click to disable (Cmd+Shift+F)" : "Enable Focus Mode (Cmd+Shift+F)")

        case .readerMode:
            Button { invoke(.readerMode) } label: {
                Image(systemName: showReaderMode ? "book.fill" : "book")
                    .font(.system(size: AppConstants.UI.toolbarIconSize, weight: .medium))
                    .foregroundStyle(showReaderMode ? SettingsManager.shared.accentColor : .primary)
            }
            .buttonStyle(ToolbarButtonStyle())
            .help("Reader Mode (Cmd+Shift+R)")

        case .privateMode:
            Button { invoke(.privateMode) } label: {
                Image(systemName: isPrivateMode ? "eye.slash.fill" : "eye.slash")
                    .font(.system(size: AppConstants.UI.toolbarIconSize, weight: .medium))
                    .foregroundStyle(isPrivateMode ? Color.purple : .primary)
            }
            .buttonStyle(ToolbarButtonStyle())
            .help(isPrivateMode ? "Exit Incognito Mode" : "Enter Incognito Mode")
        }
    }

    /// The 3-dot menu. `hiddenItems` are the buttons the user has taken off
    /// the toolbar and that are usable right now: they lead the menu so
    /// hiding a button is only ever a layout choice, never a loss of function.
    @ViewBuilder
    private func overflowMenu(hiddenItems: [ToolbarItem]) -> some View {
        Menu {
            if !hiddenItems.isEmpty {
                ForEach(hiddenItems, id: \.self) { item in
                    Button {
                        invoke(item)
                    } label: {
                        Label(item.title, systemImage: item.systemImage)
                    }
                }

                Divider()
            }

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
                onAskThisPage?()
            } label: {
                Label("Ask This Page", systemImage: "sparkles")
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
