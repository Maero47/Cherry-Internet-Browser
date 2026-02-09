//
//  TabSearchView.swift
//  Internet Browser
//

import SwiftUI

struct TabSearchView: View {
    @Bindable var tabManager: TabManager
    @Binding var isPresented: Bool

    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

    private var filteredTabs: [Tab] {
        if searchText.isEmpty {
            return tabManager.tabs
        }
        let query = searchText.lowercased()
        return tabManager.tabs.filter {
            $0.displayTitle.lowercased().contains(query) ||
            ($0.url?.absoluteString.lowercased().contains(query) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 14))

                TextField("Search tabs...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($isSearchFocused)

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                }

                Text("\(filteredTabs.count) tab\(filteredTabs.count == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)

            Divider()

            // Tab list
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(filteredTabs) { tab in
                        tabRow(tab)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 400)
        }
        .frame(width: 420)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.2), radius: 20, y: 10)
        .onAppear {
            isSearchFocused = true
        }
        .onKeyPress(.escape) {
            isPresented = false
            return .handled
        }
    }

    @ViewBuilder
    private func tabRow(_ tab: Tab) -> some View {
        let isSelected = tabManager.selectedTabID == tab.id

        Button {
            tabManager.selectTab(tab)
            isPresented = false
        } label: {
            HStack(spacing: 10) {
                // Favicon
                Group {
                    if tab.isSleeping {
                        Image(systemName: "moon.zzz.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    } else if let favicon = tab.favicon {
                        Image(nsImage: favicon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "globe")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 16, height: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(tab.displayTitle)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let url = tab.url {
                        Text(url.host ?? url.absoluteString)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if tab.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }

                if tab.isSleeping {
                    Text("Sleeping")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }

                if let group = tab.group {
                    Circle()
                        .fill(group.swiftUIColor)
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? AppConstants.Colors.accent.opacity(0.1) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
