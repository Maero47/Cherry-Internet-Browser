//
//  BrowserView.swift
//  Cherry Browser
//

import SwiftUI
import UniformTypeIdentifiers

struct BrowserView: View {
    @State private var viewModel: BrowserViewModel
    @FocusState private var isOmniboxFocused: Bool

    init(initialURL: URL? = nil, isPrivate: Bool = false) {
        let vm = BrowserViewModel()
        vm.isPrivateMode = isPrivate
        if let tab = vm.tabManager.selectedTab {
            tab.isPrivate = isPrivate
            if let url = initialURL {
                tab.url = url
                tab.showHomePage = false
                tab.title = url.host ?? "Loading..."
            }
        }
        _viewModel = State(initialValue: vm)
    }

    /// Init with an existing tab (preserves webView state, no reload)
    init(existingTab: Tab) {
        let vm = BrowserViewModel(withDefaultTab: false)
        vm.isPrivateMode = existingTab.isPrivate
        vm.tabManager.addExistingTab(existingTab)
        _viewModel = State(initialValue: vm)
    }

    var body: some View {
        browserLayout
            .frame(minWidth: 1000, minHeight: 600)
            .ignoresSafeArea(.all, edges: .top)
            .background(Color(nsColor: .windowBackgroundColor))
            .background { WindowConfigurator() }
            .preferredColorScheme(SettingsManager.shared.resolvedColorScheme)
            .tint(SettingsManager.shared.accentColor)
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.return) { .ignored }
            .background { keyboardShortcutButtons }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { _ in
                viewModel.isFullScreen = true
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in
                viewModel.isFullScreen = false
            }
            .sheet(isPresented: $viewModel.showAddBookmark) {
                if let tab = viewModel.currentTab, let url = tab.url {
                    AddBookmarkView(
                        url: url,
                        pageTitle: tab.title,
                        favicon: tab.favicon
                    ) { title, folder, isInBar in
                        viewModel.addBookmark(title: title, folder: folder, isInBookmarkBar: isInBar)
                    }
                }
            }
            .alert(
                viewModel.isPrivateMode ? "Exit Incognito Mode?" : "Enter Incognito Mode?",
                isPresented: $viewModel.showPrivateModeAlert
            ) {
                Button(viewModel.isPrivateMode ? "Exit" : "Enter", role: viewModel.isPrivateMode ? .destructive : nil) {
                    viewModel.confirmTogglePrivateMode()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if viewModel.isPrivateMode {
                    Text("Exiting incognito mode will restore normal browsing. Your tabs will reload with standard browsing data.")
                } else {
                    Text("In incognito mode, your browsing history, cookies, and site data won't be saved after you close the window.")
                }
            }
            .overlay { tabSearchOverlay }
            .overlay(alignment: .topTrailing) { downloadToastOverlay }
            .overlay(alignment: .top) { savePasswordOverlay }
            .animation(.spring(duration: 0.3), value: viewModel.passwordManager.showSavePrompt)
            .animation(.spring(duration: 0.3), value: viewModel.showDownloadToast)
            .onChange(of: viewModel.downloadManager.downloadStartedTrigger) { _, _ in
                guard let id = viewModel.downloadManager.latestDownloadID else { return }
                viewModel.toastDismissTask?.cancel()
                viewModel.toastIsCompleted = false
                viewModel.toastDownloadID = id
                viewModel.showDownloadToast = true
            }
            .onChange(of: viewModel.downloadManager.downloadCompletedTrigger) { _, _ in
                guard let id = viewModel.downloadManager.lastCompletedDownloadID else { return }
                viewModel.toastIsCompleted = true
                viewModel.toastDownloadID = id
                viewModel.toastDismissTask?.cancel()
                viewModel.toastDismissTask = Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        viewModel.showDownloadToast = false
                    }
                }
            }
    }

    // MARK: - Extracted Sub-Views

    @ViewBuilder
    private var browserLayout: some View {
        HStack(spacing: 0) {
            if viewModel.useVerticalTabs {
                VerticalTabBarView(
                    tabManager: viewModel.tabManager,
                    isCollapsed: $viewModel.verticalTabBarCollapsed,
                    onNewTab: { viewModel.newTab() },
                    onDetachTab: { tab in viewModel.detachTab(tab) },
                    onReceiveTab: { tabID in
                        _ = BrowserViewModel.transferTab(tabID: tabID, to: viewModel)
                    }
                )
                .frame(
                    minWidth: viewModel.verticalTabBarCollapsed ? 44 : 240,
                    maxWidth: viewModel.verticalTabBarCollapsed ? 44 : 240
                )
                Divider()
                    .padding(.top, viewModel.showBookmarkBar ? 73 : 43)
            }

            VStack(spacing: 0) {
                if !viewModel.useVerticalTabs {
                    TabBarView(
                        tabManager: viewModel.tabManager,
                        isFullScreen: viewModel.isFullScreen,
                        isPrivateMode: viewModel.isPrivateMode,
                        onNewTab: { viewModel.newTab() },
                        onDetachTab: { tab in viewModel.detachTab(tab) },
                        onReceiveTab: { tabID in
                            _ = BrowserViewModel.transferTab(tabID: tabID, to: viewModel)
                        }
                    )
                    Divider()
                }

                if let currentTab = viewModel.currentTab {
                    BrowserContentView(
                        viewModel: viewModel,
                        tab: currentTab,
                        onNavigate: { viewModel.navigate(to: $0) },
                        onBack: { viewModel.goBack() },
                        onForward: { viewModel.goForward() },
                        onReload: { viewModel.reload() },
                        onStop: { viewModel.stopLoading() },
                        onHome: { viewModel.goHome() },
                        onBookmark: { viewModel.showAddBookmark = true },
                        onToggleHistory: { viewModel.toggleHistory() },
                        onToggleBookmarks: { viewModel.toggleBookmarks() },
                        onDownloads: { viewModel.toggleDownloads() },
                        onSettings: { viewModel.showSettings() },
                        onToggleAdBlock: { viewModel.toggleAdBlockForCurrentSite() },
                        onTogglePrivateMode: { viewModel.requestTogglePrivateMode() },
                        onAutoFill: { viewModel.toggleAutoFillPopup() },
                        onGeneratePassword: { viewModel.generateAndFillPassword() }
                    )
                    .onDrop(of: [.cherryBrowserTab], isTargeted: nil) { providers in
                        viewModel.handleContentAreaDrop()
                    }
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity)

            if viewModel.isSidebarVisible {
                Divider()
                sidebarView
            }
        }
    }

    @ViewBuilder
    private var sidebarView: some View {
        switch viewModel.sidebarContent {
        case .history:
            HistoryView(
                repository: viewModel.historyRepository,
                onItemClick: { viewModel.openHistoryItem($0) },
                onClose: { viewModel.closeSidebar() }
            )
            .frame(minWidth: 300, maxWidth: 300)
        case .bookmarks:
            BookmarksSidebarView(
                repository: viewModel.bookmarkRepository,
                onBookmarkClick: { viewModel.openBookmark($0) },
                onClose: { viewModel.closeSidebar() }
            )
            .frame(minWidth: 300, maxWidth: 300)
        case .downloads:
            DownloadsSidebarView(
                repository: viewModel.downloadRepository,
                downloadManager: viewModel.downloadManager,
                onClose: { viewModel.closeSidebar() }
            )
            .frame(minWidth: 300, maxWidth: 300)
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private var tabSearchOverlay: some View {
        if viewModel.showTabSearch {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture {
                    viewModel.showTabSearch = false
                }

            VStack {
                TabSearchView(
                    tabManager: viewModel.tabManager,
                    isPresented: $viewModel.showTabSearch
                )
                .padding(.top, 60)

                Spacer()
            }
        }
    }

    @ViewBuilder
    private var downloadToastOverlay: some View {
        if viewModel.showDownloadToast, let downloadID = viewModel.toastDownloadID {
            DownloadToastView(
                downloadManager: viewModel.downloadManager,
                downloadRepository: viewModel.downloadRepository,
                downloadID: downloadID,
                isCompleted: viewModel.toastIsCompleted,
                onShowAll: { viewModel.showDownloadsFromToast() },
                onDismiss: { viewModel.dismissDownloadToast() }
            )
            .transition(.move(edge: .trailing).combined(with: .opacity))
            .padding(.top, 50)
            .zIndex(999)
        }
    }

    @ViewBuilder
    private var savePasswordOverlay: some View {
        if viewModel.passwordManager.showSavePrompt {
            SavePasswordBanner(
                domain: viewModel.passwordManager.pendingSaveDomain,
                username: viewModel.passwordManager.pendingSaveUsername ?? "",
                onSave: { viewModel.passwordManager.savePromptAccepted() },
                onDismiss: { viewModel.passwordManager.savePromptDismissed() }
            )
            .transition(.move(edge: .top).combined(with: .opacity))
            .padding(.top, viewModel.showBookmarkBar ? 88 : 52)
            .zIndex(998)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "globe")
                .font(.system(size: 64))
                .foregroundStyle(.tertiary)

            Text("No tab selected")
                .font(.title2)
                .foregroundStyle(.secondary)

            Button("New Tab") {
                viewModel.newTab()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var keyboardShortcutButtons: some View {
        Group {
            // New Tab (Cmd+T)
            Button("") { viewModel.newTab() }
                .keyboardShortcut("t", modifiers: .command)

            // Close Tab (Cmd+W)
            Button("") { viewModel.closeCurrentTab() }
                .keyboardShortcut("w", modifiers: .command)

            // Reopen Closed Tab (Cmd+Shift+T)
            Button("") { viewModel.reopenClosedTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])

            // Reload (Cmd+R)
            Button("") { viewModel.reload() }
                .keyboardShortcut("r", modifiers: .command)

            // Go Back (Cmd+[)
            Button("") { viewModel.goBack() }
                .keyboardShortcut("[", modifiers: .command)

            // Go Forward (Cmd+])
            Button("") { viewModel.goForward() }
                .keyboardShortcut("]", modifiers: .command)

            // Focus Address Bar (Cmd+L)
            Button("") { isOmniboxFocused = true }
                .keyboardShortcut("l", modifiers: .command)

            // Add Bookmark (Cmd+D)
            Button("") { viewModel.showAddBookmark = true }
                .keyboardShortcut("d", modifiers: .command)

            // Toggle History (Cmd+Y)
            Button("") { viewModel.toggleHistory() }
                .keyboardShortcut("y", modifiers: .command)

            // Toggle Bookmarks (Cmd+Shift+B)
            Button("") { viewModel.toggleBookmarks() }
                .keyboardShortcut("b", modifiers: [.command, .shift])

            // Toggle Bookmark Bar (Cmd+Option+B)
            Button("") { viewModel.toggleBookmarkBar() }
                .keyboardShortcut("b", modifiers: [.command, .option])

            // Next Tab (Ctrl+Tab)
            Button("") { viewModel.selectNextTab() }
                .keyboardShortcut(.tab, modifiers: .control)

            // Previous Tab (Ctrl+Shift+Tab)
            Button("") { viewModel.selectPreviousTab() }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])

            // Tab Search (Cmd+Shift+A)
            Button("") { viewModel.toggleTabSearch() }
                .keyboardShortcut("a", modifiers: [.command, .shift])

            // Toggle Vertical Tabs (Cmd+Option+V)
            Button("") { viewModel.toggleVerticalTabs() }
                .keyboardShortcut("v", modifiers: [.command, .option])

            // Downloads (Cmd+Shift+J)
            Button("") { viewModel.toggleDownloads() }
                .keyboardShortcut("j", modifiers: [.command, .shift])

            // Auto-fill Password (Cmd+\)
            Button("") { viewModel.autoFillCurrentPage() }
                .keyboardShortcut("\\", modifiers: .command)

            // New Private Window (Cmd+Shift+N)
            Button("") { viewModel.openPrivateWindow() }
                .keyboardShortcut("n", modifiers: [.command, .shift])

            // Tab selection 1-9
            ForEach(1...9, id: \.self) { index in
                Button("") { viewModel.selectTab(at: index) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index))), modifiers: .command)
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
    }
}

// Separate view to properly observe tab changes with @Bindable
struct BrowserContentView: View {
    @Bindable var viewModel: BrowserViewModel
    @Bindable var tab: Tab
    let onNavigate: (String) -> Void
    let onBack: () -> Void
    let onForward: () -> Void
    let onReload: () -> Void
    let onStop: () -> Void
    let onHome: () -> Void
    let onBookmark: () -> Void
    let onToggleHistory: () -> Void
    let onToggleBookmarks: () -> Void
    let onDownloads: () -> Void
    let onSettings: () -> Void
    let onToggleAdBlock: () -> Void
    var onTogglePrivateMode: (() -> Void)? = nil
    var onAutoFill: (() -> Void)? = nil
    var onGeneratePassword: (() -> Void)? = nil

    // Track URL changes to force WebViewWrapper updates
    @State private var urlVersion: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            NavigationBarView(
                tab: tab,
                isBookmarked: viewModel.isCurrentPageBookmarked(),
                onNavigate: onNavigate,
                onBack: onBack,
                onForward: onForward,
                onReload: onReload,
                onStop: onStop,
                onHome: onHome,
                onBookmark: onBookmark,
                onToggleHistory: onToggleHistory,
                onToggleBookmarks: onToggleBookmarks,
                onDownloads: onDownloads,
                onSettings: onSettings,
                onToggleAdBlock: onToggleAdBlock,
                onAutoFill: onAutoFill,
                loginFormDetected: viewModel.passwordManager.loginFormDetected,
                isPrivateMode: viewModel.isPrivateMode,
                onTogglePrivateMode: onTogglePrivateMode,
                showWindowDragArea: viewModel.useVerticalTabs && !viewModel.isFullScreen
            )
            .overlay(alignment: .topTrailing) {
                if viewModel.showAutoFillPopup {
                    PasswordAutoFillPopup(
                        credentials: viewModel.passwordManager.matchingCredentials,
                        onSelect: { credential in
                            viewModel.fillCredential(credential)
                        },
                        onGenerate: {
                            onGeneratePassword?()
                        },
                        onDismiss: {
                            viewModel.showAutoFillPopup = false
                        }
                    )
                    .padding(.trailing, 80)
                    .offset(y: 36)
                    .zIndex(100)
                }
            }
            .zIndex(200)

            // Bookmark bar
            if viewModel.showBookmarkBar {
                BookmarkBarView(
                    repository: viewModel.bookmarkRepository,
                    onBookmarkClick: { viewModel.openBookmark($0) },
                    isPrivateMode: viewModel.isPrivateMode
                )
                Divider()
            }

            // Loading progress bar
            if tab.isLoading {
                ProgressBarView(progress: tab.loadingProgress)
            } else {
                Divider()
            }

            // Content - show settings, homepage, or web view
            if tab.showSettingsPage {
                SettingsPageView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tab.showHomePage {
                HomePageView(
                    repository: viewModel.shortcutRepository,
                    onShortcutClick: { url in
                        onNavigate(url.absoluteString)
                    },
                    onSearch: { query in
                        onNavigate(query)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Web content - use urlVersion to force updates when URL changes
                WebViewWrapper(
                    tab: tab,
                    urlVersion: urlVersion,
                    onNewTab: { url in
                        viewModel.newTab(url: url)
                    },
                    onNewTabWithWebView: { webView, url in
                        viewModel.newTabWithWebView(webView, url: url)
                    },
                    viewModel: viewModel
                )
                    .id(tab.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: tab.url) { _, _ in
            urlVersion += 1
        }
    }
}

// MARK: - Progress Bar

struct ProgressBarView: View {
    let progress: Double

    var body: some View {
        Rectangle()
            .fill(SettingsManager.shared.accentColor)
            .frame(height: 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .scaleEffect(x: progress, y: 1, anchor: .leading)
            .animation(.linear(duration: 0.15), value: progress)
    }
}

#Preview {
    BrowserView()
}
