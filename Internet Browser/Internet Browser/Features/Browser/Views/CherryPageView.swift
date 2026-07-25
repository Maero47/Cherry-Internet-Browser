//
//  CherryPageView.swift
//  Cherry Browser
//

import SwiftUI

/// Renders an internal `cherry://` page full-screen in a tab's content slot
/// (shown instead of the WKWebView while `tab.internalPage` is set). Reuses
/// the existing settings/sidebar views; history, bookmarks and downloads are
/// laid out as a centered readable column instead of a 300pt sidebar, keeping
/// all their existing actions (open/delete/search/clear/context menus).
struct CherryPageView: View {
    let page: CherryPage
    @Bindable var viewModel: BrowserViewModel
    @Bindable var tab: Tab

    var body: some View {
        Group {
            switch page {
            case .settings:
                SettingsPageView()
            case .extensions:
                ExtensionsPageView()
            case .history:
                fullPageColumn {
                    HistoryView(
                        repository: viewModel.historyRepository,
                        onItemClick: { viewModel.openHistoryItem($0, in: tab) },
                        onOpenInNewTab: { viewModel.openHistoryItemInNewTab($0) },
                        onClose: { viewModel.goBack(for: tab) }
                    )
                }
            case .bookmarks:
                fullPageColumn {
                    BookmarksSidebarView(
                        repository: viewModel.bookmarkRepository,
                        onBookmarkClick: { viewModel.openBookmark($0, in: tab) },
                        onOpenInNewTab: { viewModel.openBookmarkInNewTab($0) },
                        onClose: { viewModel.goBack(for: tab) },
                        isPrivateMode: viewModel.isPrivateMode
                    )
                }
            case .downloads:
                fullPageColumn {
                    DownloadsSidebarView(
                        repository: viewModel.downloadRepository,
                        downloadManager: viewModel.downloadManager,
                        onClose: { viewModel.goBack(for: tab) },
                        isPrivateMode: viewModel.isPrivateMode
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Centers a reused sidebar view as a full-page column. Its close (X)
    /// button acts as Back — the same "return to the site" step the nav
    /// bar's Back button performs while an internal page is open.
    @ViewBuilder
    private func fullPageColumn(@ViewBuilder content: () -> some View) -> some View {
        content()
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Full-page Extensions management for `cherry://extensions` — the same
/// `ExtensionsSettingsView` shown inside Settings, in its own page layout so
/// the location and the visible page match.
struct ExtensionsPageView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Extensions")
                        .font(.system(size: 22, weight: .bold))
                    Text("Manage installed WebExtensions")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                ExtensionsSettingsView()
            }
            .padding(24)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
