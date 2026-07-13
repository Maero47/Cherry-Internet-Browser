//
//  CommandPaletteView.swift
//  Cherry Browser
//

import SwiftUI

// MARK: - Data Model

struct CommandPaletteItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let iconColor: Color
    let action: () -> Void
}

struct CommandPaletteSection: Identifiable {
    let id: String
    let title: String
    var items: [CommandPaletteItem]
}

// MARK: - Main View

struct CommandPaletteView: View {
    @Bindable var viewModel: BrowserViewModel
    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @FocusState private var searchFocused: Bool

    private var sections: [CommandPaletteSection] { buildSections() }
    private var flatItems: [CommandPaletteItem] { sections.flatMap(\.items) }

    var body: some View {
        ZStack {
            // Scrim
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { viewModel.showCommandPalette = false }

            // Glass card
            VStack(spacing: 0) {
                // Search bar
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 16, weight: .medium))

                    TextField("Search tabs, bookmarks, history, or actions…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .focused($searchFocused)
                        .onChange(of: query) { _, _ in selectedIndex = 0 }

                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                if !flatItems.isEmpty {
                    Divider()

                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                                ForEach(sections) { section in
                                    if !section.items.isEmpty {
                                        Section {
                                            ForEach(section.items) { item in
                                                let globalIndex = flatItems.firstIndex(where: { $0.id == item.id }) ?? 0
                                                PaletteResultRow(
                                                    item: item,
                                                    isSelected: selectedIndex == globalIndex
                                                ) {
                                                    item.action()
                                                    viewModel.showCommandPalette = false
                                                }
                                                .id(item.id)
                                            }
                                        } header: {
                                            Text(section.title)
                                                .font(.system(size: 10, weight: .semibold))
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, 16)
                                                .padding(.top, 10)
                                                .padding(.bottom, 2)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .background(.regularMaterial)
                                        }
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 340)
                        .onChange(of: selectedIndex) { _, newValue in
                            guard flatItems.indices.contains(newValue) else { return }
                            withAnimation(.easeInOut(duration: 0.1)) {
                                proxy.scrollTo(flatItems[newValue].id, anchor: .center)
                            }
                        }
                    }
                } else if !query.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 28))
                            .foregroundStyle(.tertiary)
                        Text("No results for \"\(query)\"")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 13))
                    }
                    .frame(height: 100)
                }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.28), radius: 30, y: 10)
            .frame(width: 580)
            .padding(.horizontal, 20)
            // Keyboard navigation (invisible button layer)
            .background {
                Group {
                    Button("") {
                        selectedIndex = max(0, selectedIndex - 1)
                    }
                    .keyboardShortcut(.upArrow, modifiers: [])

                    Button("") {
                        selectedIndex = min(flatItems.count - 1, selectedIndex + 1)
                    }
                    .keyboardShortcut(.downArrow, modifiers: [])

                    Button("") {
                        guard flatItems.indices.contains(selectedIndex) else { return }
                        flatItems[selectedIndex].action()
                        viewModel.showCommandPalette = false
                    }
                    .keyboardShortcut(.return, modifiers: [])

                    Button("") {
                        viewModel.showCommandPalette = false
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                }
                .opacity(0)
                .frame(width: 0, height: 0)
            }
        }
        .onAppear { searchFocused = true }
    }

    // MARK: - Build Sections

    private func buildSections() -> [CommandPaletteSection] {
        let lowercaseQuery = query.lowercased()

        // --- Open Tabs ---
        let tabItems: [CommandPaletteItem] = viewModel.tabManager.tabs.compactMap { tab in
            let title = tab.displayTitle
            let url = tab.url?.absoluteString ?? ""
            if !query.isEmpty {
                guard title.lowercased().contains(lowercaseQuery)
                        || url.lowercased().contains(lowercaseQuery) else { return nil }
            }
            return CommandPaletteItem(
                id: "tab-\(tab.id)",
                title: title,
                subtitle: url,
                icon: "rectangle.on.rectangle",
                iconColor: .blue
            ) {
                viewModel.tabManager.selectTab(tab)
            }
        }

        // --- Bookmarks ---
        let bookmarkItems: [CommandPaletteItem] = viewModel.bookmarkRepository.bookmarks.compactMap { bookmark in
            if !query.isEmpty {
                guard bookmark.title.lowercased().contains(lowercaseQuery)
                        || bookmark.url.absoluteString.lowercased().contains(lowercaseQuery) else { return nil }
            }
            return CommandPaletteItem(
                id: "bookmark-\(bookmark.id)",
                title: bookmark.title,
                subtitle: bookmark.url.absoluteString,
                icon: "bookmark.fill",
                iconColor: .orange
            ) {
                viewModel.openBookmark(bookmark)
            }
        }

        // --- History ---
        let historyLimit = query.isEmpty ? 5 : 20
        let historyItems: [CommandPaletteItem] = viewModel.historyRepository.historyItems
            .prefix(100)
            .compactMap { item in
                let title = item.title.isEmpty ? item.url.absoluteString : item.title
                let url = item.url.absoluteString
                if !query.isEmpty {
                    guard title.lowercased().contains(lowercaseQuery)
                            || url.lowercased().contains(lowercaseQuery) else { return nil }
                }
                return CommandPaletteItem(
                    id: "history-\(item.id)",
                    title: title,
                    subtitle: url,
                    icon: "clock",
                    iconColor: .secondary
                ) {
                    viewModel.openHistoryItem(item)
                }
            }
            .prefix(historyLimit)
            .map { $0 }

        // --- Actions ---
        let allActions: [CommandPaletteItem] = [
            CommandPaletteItem(id: "action-newtab", title: "New Tab", subtitle: "Open a blank new tab", icon: "plus.square", iconColor: .green) {
                viewModel.newTab()
            },
            CommandPaletteItem(id: "action-newinc", title: "New Private Window", subtitle: "Open incognito window", icon: "theatermasks", iconColor: .purple) {
                viewModel.openPrivateWindow()
            },
            CommandPaletteItem(id: "action-find", title: "Find in Page", subtitle: "Search text on current page", icon: "doc.text.magnifyingglass", iconColor: .blue) {
                viewModel.toggleFindInPage()
            },
            CommandPaletteItem(id: "action-bookmark", title: "Bookmark This Page", subtitle: "Add current page to bookmarks", icon: "bookmark", iconColor: .orange) {
                viewModel.showAddBookmark = true
            },
            CommandPaletteItem(id: "action-history", title: "Show History", subtitle: "Open cherry://history", icon: "clock.arrow.circlepath", iconColor: Color.secondary) {
                viewModel.openInternalPage(.history)
            },
            CommandPaletteItem(id: "action-bookmarks", title: "Show Bookmarks", subtitle: "Open cherry://bookmarks", icon: "bookmark.square", iconColor: .orange) {
                viewModel.openInternalPage(.bookmarks)
            },
            CommandPaletteItem(id: "action-downloads", title: "Show Downloads", subtitle: "Open cherry://downloads", icon: "arrow.down.circle", iconColor: .blue) {
                viewModel.openInternalPage(.downloads)
            },
            CommandPaletteItem(id: "action-extensions", title: "Show Extensions", subtitle: "Open cherry://extensions", icon: "puzzlepiece.extension", iconColor: .teal) {
                viewModel.openInternalPage(.extensions)
            },
            CommandPaletteItem(id: "action-reopen", title: "Reopen Closed Tab", subtitle: "Restore last closed tab", icon: "arrow.uturn.backward", iconColor: Color.secondary) {
                viewModel.reopenClosedTab()
            },
            CommandPaletteItem(id: "action-reader", title: "Toggle Reader Mode", subtitle: "Distraction-free reading view", icon: "doc.plaintext", iconColor: .brown) {
                viewModel.toggleReaderMode()
            },
            CommandPaletteItem(id: "action-settings", title: "Open Settings", subtitle: "Browser preferences", icon: "gear", iconColor: Color.secondary) {
                viewModel.showSettings()
            },
        ]

        let actionItems = allActions.filter { item in
            guard !query.isEmpty else { return true }
            return item.title.lowercased().contains(lowercaseQuery)
                || item.subtitle.lowercased().contains(lowercaseQuery)
        }

        // Build sections — only include non-empty ones
        var result: [CommandPaletteSection] = []
        if !tabItems.isEmpty {
            result.append(CommandPaletteSection(id: "tabs", title: "OPEN TABS", items: Array(tabItems.prefix(5))))
        }
        if !bookmarkItems.isEmpty {
            result.append(CommandPaletteSection(id: "bookmarks", title: "BOOKMARKS", items: Array(bookmarkItems.prefix(5))))
        }
        if !historyItems.isEmpty {
            result.append(CommandPaletteSection(id: "history", title: "HISTORY", items: historyItems))
        }
        if !actionItems.isEmpty {
            result.append(CommandPaletteSection(id: "actions", title: "ACTIONS", items: actionItems))
        }
        return result
    }
}

// MARK: - Result Row

private struct PaletteResultRow: View {
    let item: CommandPaletteItem
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: item.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(item.iconColor)
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)

                    if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(isSelected ? SettingsManager.shared.accentColor.opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
