//
//  CherryPageView.swift
//  Cherry Browser
//

import SwiftUI

/// Renders an internal `cherry://` page full-screen in a tab's content slot
/// (shown instead of the WKWebView while `tab.internalPage` is set).
///
/// History, bookmarks and downloads are handed the whole tab and told they are
/// a page. They used to be handed a `maxWidth: 760` box in the middle of a
/// 1500pt window, which is where the empty half of those screens came from:
/// a 300pt sidebar view widened to 760 knew nothing to do with the extra room,
/// and nothing at all to do with the extra height. `LibraryLayout` reads the
/// width it is actually given and spends it on a scope rail and more columns.
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
                HistoryView(
                    repository: viewModel.historyRepository,
                    onItemClick: { viewModel.openHistoryItem($0, in: tab) },
                    onOpenInNewTab: { viewModel.openHistoryItemInNewTab($0) },
                    presentation: .page
                )
            case .bookmarks:
                BookmarksSidebarView(
                    repository: viewModel.bookmarkRepository,
                    onBookmarkClick: { viewModel.openBookmark($0, in: tab) },
                    onOpenInNewTab: { viewModel.openBookmarkInNewTab($0) },
                    presentation: .page,
                    isPrivateMode: viewModel.isPrivateMode
                )
            case .downloads:
                DownloadsSidebarView(
                    repository: viewModel.downloadRepository,
                    downloadManager: viewModel.downloadManager,
                    presentation: .page,
                    isPrivateMode: viewModel.isPrivateMode
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
