//
//  HistoryView.swift
//  Cherry Browser
//

import SwiftUI

struct HistoryView: View {
    @Bindable var repository: HistoryRepository
    let onItemClick: (HistoryItem) -> Void
    /// ⌘-click, middle-click and "Open in New Tab" — opens in the background.
    var onOpenInNewTab: ((HistoryItem) -> Void)? = nil
    let onClose: () -> Void

    @State private var searchText: String = ""
    @State private var showingClearAlert: Bool = false

    var filteredGroups: [HistoryGroup] {
        if searchText.isEmpty {
            return repository.groupedHistory
        }
        let filtered = repository.searchHistory(query: searchText)
        return [HistoryGroup(id: "Search Results", title: "Search Results", items: filtered)]
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("History")
                    .font(.headline)

                Spacer()

                Button(action: { showingClearAlert = true }) {
                    Text("Clear...")
                        .font(.subheadline)
                }
                .buttonStyle(.borderless)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search history", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(8)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider()

            // History list
            if filteredGroups.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("No history")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredGroups) { group in
                        Section(header: Text(group.title).font(.subheadline).foregroundStyle(.secondary)) {
                            ForEach(group.items) { item in
                                HistoryItemRow(
                                    item: item,
                                    action: { onItemClick(item) },
                                    onOpenInNewTab: onOpenInNewTab.map { open in { open(item) } }
                                )
                                .contextMenu {
                                    Button("Open") { onItemClick(item) }
                                    if let onOpenInNewTab {
                                        Button("Open in New Tab") { onOpenInNewTab(item) }
                                    }
                                    Divider()
                                    Button("Copy Link") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(item.url.absoluteString, forType: .string)
                                    }
                                    Divider()
                                    Button("Delete") {
                                        repository.deleteHistoryItem(item)
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Clear History", isPresented: $showingClearAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Last Hour", role: .destructive) {
                clearHistory(hours: 1)
            }
            Button("Today", role: .destructive) {
                clearHistory(hours: 24)
            }
            Button("All Time", role: .destructive) {
                repository.clearAllHistory()
            }
        } message: {
            Text("Choose how much history to clear.")
        }
    }

    private func clearHistory(hours: Int) {
        let calendar = Calendar.current
        let startDate = calendar.date(byAdding: .hour, value: -hours, to: Date()) ?? Date()
        repository.deleteHistory(from: startDate, to: Date())
    }
}

struct HistoryItemRow: View {
    let item: HistoryItem
    let action: () -> Void
    var onOpenInNewTab: (() -> Void)? = nil

    @State private var isHovering: Bool = false

    private func open() {
        if NSEvent.isCommandClick, let onOpenInNewTab {
            onOpenInNewTab()
        } else {
            action()
        }
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                if let favicon = item.favicon {
                    Image(nsImage: favicon)
                        .resizable()
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "globe")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .foregroundStyle(.primary)

                    Text(item.url.host ?? item.url.absoluteString)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(formatTime(item.visitDate))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay {
            if let onOpenInNewTab {
                AuxClickCatcher(onMiddleClick: onOpenInNewTab)
            }
        }
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }
}
