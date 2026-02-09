//
//  BrowserView.swift
//  Cherry Browser
//

import SwiftUI

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

    var body: some View {
        HStack(spacing: 0) {
            // Vertical tab bar (left side)
            if viewModel.useVerticalTabs {
                VerticalTabBarView(
                    tabManager: viewModel.tabManager,
                    isCollapsed: $viewModel.verticalTabBarCollapsed,
                    onNewTab: { viewModel.newTab() }
                )
                Divider()
                    .padding(.top, viewModel.showBookmarkBar ? 73 : 43)
            }

            // Main browser content
            VStack(spacing: 0) {
                // Horizontal tab bar (only when not using vertical tabs)
                if !viewModel.useVerticalTabs {
                    TabBarView(
                        tabManager: viewModel.tabManager,
                        isFullScreen: viewModel.isFullScreen,
                        isPrivateMode: viewModel.isPrivateMode,
                        onNewTab: { viewModel.newTab() },
                        onDetachTab: { tab in viewModel.detachTab(tab) }
                    )
                    Divider()
                }

                // Navigation bar and web content
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
                        onDownloads: {},
                        onSettings: { viewModel.showSettings() },
                        onToggleAdBlock: { viewModel.toggleAdBlockForCurrentSite() }
                    )
                } else {
                    emptyState
                }
            }

            // Sidebar
            if viewModel.isSidebarVisible {
                Divider()

                switch viewModel.sidebarContent {
                case .history:
                    HistoryView(
                        repository: viewModel.historyRepository,
                        onItemClick: { viewModel.openHistoryItem($0) },
                        onClose: { viewModel.closeSidebar() }
                    )
                case .bookmarks:
                    BookmarksSidebarView(
                        repository: viewModel.bookmarkRepository,
                        onBookmarkClick: { viewModel.openBookmark($0) },
                        onClose: { viewModel.closeSidebar() }
                    )
                case .none:
                    EmptyView()
                }
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .ignoresSafeArea(.all, edges: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .background { WindowConfigurator() }
        .preferredColorScheme(SettingsManager.shared.resolvedColorScheme)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.return) { .ignored }
        .background {
            keyboardShortcutButtons
        }
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
        .overlay {
            // Tab search overlay
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
                isAdBlockPaused: SettingsManager.shared.isAdBlockPaused(for: tab.url)
            )

            // Bookmark bar
            if viewModel.showBookmarkBar {
                BookmarkBarView(
                    repository: viewModel.bookmarkRepository,
                    onBookmarkClick: { viewModel.openBookmark($0) }
                )
                Divider()
            }

            // Loading progress bar
            if tab.isLoading {
                GeometryReader { geometry in
                    Rectangle()
                        .fill(SettingsManager.shared.accentColor)
                        .frame(width: geometry.size.width * tab.loadingProgress, height: 2)
                        .animation(.linear(duration: 0.1), value: tab.loadingProgress)
                }
                .frame(height: 2)
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
                WebViewWrapper(tab: tab, urlVersion: urlVersion)
                    .id(tab.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: tab.url) { _, _ in
            urlVersion += 1
        }
    }
}

#Preview {
    BrowserView()
}
