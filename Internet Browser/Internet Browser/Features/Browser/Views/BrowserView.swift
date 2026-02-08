//
//  BrowserView.swift
//  Cherry Browser
//

import SwiftUI

struct BrowserView: View {
    @State private var viewModel = BrowserViewModel()
    @FocusState private var isOmniboxFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            // Main browser content
            VStack(spacing: 0) {
                // Tab bar
                TabBarView(
                    tabManager: viewModel.tabManager,
                    onNewTab: { viewModel.newTab() }
                )

                Divider()

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
                        onToggleBookmarks: { viewModel.toggleBookmarks() }
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
        .background(Color(nsColor: .windowBackgroundColor))
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.return) { .ignored }
        .background {
            keyboardShortcutButtons
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

            // Toggle Bookmark Bar (Cmd+Shift+B)
            Button("") { viewModel.toggleBookmarkBar() }
                .keyboardShortcut("b", modifiers: [.command, .option])

            // Next Tab (Ctrl+Tab)
            Button("") { viewModel.selectNextTab() }
                .keyboardShortcut(.tab, modifiers: .control)

            // Previous Tab (Ctrl+Shift+Tab)
            Button("") { viewModel.selectPreviousTab() }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])

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
                onToggleBookmarks: onToggleBookmarks
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
                        .fill(AppConstants.Colors.accent)
                        .frame(width: geometry.size.width * tab.loadingProgress, height: 2)
                        .animation(.linear(duration: 0.1), value: tab.loadingProgress)
                }
                .frame(height: 2)
            } else {
                Divider()
            }

            // Web content - use urlVersion to force updates when URL changes
            WebViewWrapper(tab: tab, urlVersion: urlVersion)
                .id(tab.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: tab.url) { _, _ in
            urlVersion += 1
        }
    }
}

#Preview {
    BrowserView()
}
