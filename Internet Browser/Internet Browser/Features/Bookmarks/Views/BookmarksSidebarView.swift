//
//  BookmarksSidebarView.swift
//  Cherry Browser
//

import SwiftUI

struct BookmarksSidebarView: View {
    @Bindable var repository: BookmarkRepository
    let onBookmarkClick: (Bookmark) -> Void
    let onClose: () -> Void

    @State private var searchText: String = ""
    @State private var selectedFolder: String? = nil

    var filteredBookmarks: [Bookmark] {
        var results: [Bookmark]

        if !searchText.isEmpty {
            results = repository.searchBookmarks(query: searchText)
        } else if let folder = selectedFolder {
            results = repository.bookmarks(in: folder)
        } else {
            results = repository.bookmarks
        }

        return results
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Bookmarks")
                    .font(.headline)

                Spacer()

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
                TextField("Search bookmarks", text: $searchText)
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

            // Folder filter
            if !repository.folders.isEmpty && searchText.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        FolderChip(name: "All", isSelected: selectedFolder == nil) {
                            selectedFolder = nil
                        }

                        ForEach(repository.folders, id: \.self) { folder in
                            FolderChip(name: folder, isSelected: selectedFolder == folder) {
                                selectedFolder = folder
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .padding(.bottom, 8)
            }

            Divider()

            // Bookmarks list
            if filteredBookmarks.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "book")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text(searchText.isEmpty ? "No bookmarks" : "No results")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredBookmarks) { bookmark in
                        BookmarkItemRow(bookmark: bookmark) {
                            onBookmarkClick(bookmark)
                        }
                        .contextMenu {
                            Button("Open") { onBookmarkClick(bookmark) }
                            Button("Open in New Tab") { /* TODO */ }
                            Divider()
                            Button("Copy Link") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(bookmark.url.absoluteString, forType: .string)
                            }
                            Divider()
                            if bookmark.isInBookmarkBar {
                                Button("Remove from Bookmark Bar") {
                                    var updated = bookmark
                                    updated.isInBookmarkBar = false
                                    repository.updateBookmark(updated)
                                }
                            } else {
                                Button("Add to Bookmark Bar") {
                                    var updated = bookmark
                                    updated.isInBookmarkBar = true
                                    repository.updateBookmark(updated)
                                }
                            }
                            Divider()
                            Button("Delete", role: .destructive) {
                                repository.deleteBookmark(bookmark)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .frame(width: 300)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct FolderChip: View {
    let name: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(name)
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(isSelected ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                .foregroundStyle(isSelected ? .white : .primary)
                .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }
}

struct BookmarkItemRow: View {
    let bookmark: Bookmark
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let favicon = bookmark.favicon {
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
                    Text(bookmark.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .foregroundStyle(.primary)

                    Text(bookmark.url.host ?? bookmark.url.absoluteString)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if bookmark.isInBookmarkBar {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
