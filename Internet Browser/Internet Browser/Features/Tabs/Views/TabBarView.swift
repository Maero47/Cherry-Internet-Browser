//
//  TabBarView.swift
//  Internet Browser
//

import SwiftUI

struct TabBarView: View {
    @Bindable var tabManager: TabManager
    let onNewTab: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            // Window controls spacer (for frameless window)
            Spacer()
                .frame(width: 76)

            // Tab list
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
                .padding(.horizontal, 8)
            }

            // New tab button
            Button(action: onNewTab) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(ToolbarButtonStyle())
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
