//
//  TabBarView.swift
//  Internet Browser
//

import SwiftUI
import AppKit

struct TabBarView: View {
    @Bindable var tabManager: TabManager
    var isFullScreen: Bool = false
    let onNewTab: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            // Tab list - starts after traffic lights (or from edge in fullscreen)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    // Pinned tabs first
                    ForEach(tabManager.tabs.filter { $0.isPinned }) { tab in
                        TabItemView(
                            tab: tab,
                            isSelected: tabManager.selectedTabID == tab.id,
                            onSelect: { tabManager.selectTab(tab) },
                            onClose: { tabManager.closeTab(tab) }
                        )
                    }

                    // Regular tabs
                    ForEach(tabManager.tabs.filter { !$0.isPinned }) { tab in
                        TabItemView(
                            tab: tab,
                            isSelected: tabManager.selectedTabID == tab.id,
                            onSelect: { tabManager.selectTab(tab) },
                            onClose: { tabManager.closeTab(tab) }
                        )
                    }
                }
                .padding(.leading, isFullScreen ? 8 : 76)
                .padding(.trailing, 8)
            }

            // New tab button
            Button(action: onNewTab) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("New Tab (Cmd+T)")
            .padding(.trailing, 8)
        }
        .frame(height: AppConstants.UI.tabBarHeight)
        .background(tabBarBackground)
    }

    @ViewBuilder
    private var tabBarBackground: some View {
        colorScheme == .dark
            ? AppConstants.Colors.darkBackground
            : AppConstants.Colors.lightBackground
    }
}

#Preview {
    TabBarView(
        tabManager: TabManager(),
        onNewTab: {}
    )
    .frame(width: 800)
}
