//
//  BookmarksSidebarView.swift
//  Cherry Browser
//

import SwiftUI

/// Scopes, folders and dates for the bookmarks screen. Pure, so the folder
/// arithmetic can be tested without a window.
///
/// `BookmarkRepository` has carried `folder` and `isInBookmarkBar` all along
/// and the screen showed neither, so a hundred bookmarks arrived as one flat
/// run with no structure to navigate by. Both are now first-class: folders are
/// the rail, and the bookmark bar is a scope of its own because "is this one of
/// the five on my bar" is a question people actually ask.
enum BookmarkLibrary {

    static let allScopeID = "all"
    static let barScopeID = "bookmark-bar"
    static let unfiledScopeID = "unfiled"
    static let folderScopePrefix = "folder:"

    static func scopes(for bookmarks: [Bookmark]) -> [LibraryScope] {
        var scopes: [LibraryScope] = [
            LibraryScope(
                id: allScopeID, title: "All Bookmarks", icon: "bookmark",
                count: bookmarks.count
            ),
            LibraryScope(
                id: barScopeID, title: "Bookmark Bar", icon: "menubar.rectangle",
                count: bookmarks.count { $0.isInBookmarkBar }
            ),
        ]

        let folders = Set(bookmarks.compactMap(\.folder)).sorted()
        for folder in folders {
            scopes.append(LibraryScope(
                id: folderScopePrefix + folder, title: folder, icon: "folder",
                count: bookmarks.count { $0.folder == folder }
            ))
        }

        let unfiled = bookmarks.count { $0.folder == nil }
        // Only offered when there is something in it and something outside it,
        // so a user with no folders at all never sees a scope that is just a
        // second name for All.
        if unfiled > 0 && !folders.isEmpty {
            scopes.append(LibraryScope(
                id: unfiledScopeID, title: "Unfiled", icon: "tray",
                count: unfiled
            ))
        }
        return scopes
    }

    static func items(_ bookmarks: [Bookmark], in scopeID: String) -> [Bookmark] {
        switch scopeID {
        case barScopeID:
            return bookmarks.filter(\.isInBookmarkBar)
        case unfiledScopeID:
            return bookmarks.filter { $0.folder == nil }
        case let id where id.hasPrefix(folderScopePrefix):
            let folder = String(id.dropFirst(folderScopePrefix.count))
            return bookmarks.filter { $0.folder == folder }
        default:
            return bookmarks
        }
    }

    /// Headings inside a scope. In `All`, the folders themselves are the
    /// headings, so the structure the data has always had is finally on screen.
    static func sections(
        _ bookmarks: [Bookmark],
        scopeID: String,
        searchQuery: String
    ) -> [LibrarySection<Bookmark>] {
        guard !bookmarks.isEmpty else { return [] }

        if !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            return [LibrarySection(id: "matches", title: "Matches", items: bookmarks)]
        }

        guard scopeID == allScopeID else {
            let title = scopeID == barScopeID ? "On the bookmark bar" : "Bookmarks"
            return [LibrarySection(id: scopeID, title: title, items: bookmarks)]
        }

        var sections: [LibrarySection<Bookmark>] = []
        let unfiled = bookmarks.filter { $0.folder == nil }
        if !unfiled.isEmpty {
            sections.append(LibrarySection(id: "unfiled", title: "Unfiled", items: unfiled))
        }
        for folder in Set(bookmarks.compactMap(\.folder)).sorted() {
            sections.append(LibrarySection(
                id: folderScopePrefix + folder,
                title: folder,
                items: bookmarks.filter { $0.folder == folder }
            ))
        }
        return sections
    }

    static func addedText(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = calendar.isDate(date, equalTo: now, toGranularity: .year)
            ? "d MMM"
            : "d MMM yy"
        return formatter.string(from: date)
    }
}

struct BookmarksSidebarView: View {
    @Bindable var repository: BookmarkRepository
    let onBookmarkClick: (Bookmark) -> Void
    /// ⌘-click, middle-click and "Open in New Tab" — opens in the background.
    var onOpenInNewTab: ((Bookmark) -> Void)? = nil
    var presentation: LibraryPresentation = .sidebar
    var onClose: (() -> Void)? = nil
    /// Private windows are never themed by an imported Firefox theme.
    var isPrivateMode: Bool = false

    @State private var searchText: String = ""
    @State private var scopeID: String = BookmarkLibrary.allScopeID
    @State private var selection: Set<UUID> = []
    @State private var showingRemoveAllAlert: Bool = false

    private var matchingBookmarks: [Bookmark] {
        let base = searchText.trimmingCharacters(in: .whitespaces).isEmpty
            ? repository.bookmarks
            : repository.searchBookmarks(query: searchText)
        return BookmarkLibrary.items(base, in: scopeID)
    }

    var body: some View {
        LibraryLayout(
            title: "Bookmarks",
            searchPrompt: "Search bookmarks",
            presentation: presentation,
            scopes: BookmarkLibrary.scopes(for: repository.bookmarks),
            scopeID: $scopeID,
            searchText: $searchText,
            sections: BookmarkLibrary.sections(
                matchingBookmarks, scopeID: scopeID, searchQuery: searchText
            ),
            selection: $selection,
            emptyState: LibraryEmptyState(
                icon: "bookmark",
                headline: "No bookmarks yet",
                detail: "Press ⌘D on a page to save it here. Bookmarks you put on the bookmark bar are listed too.",
                isUntouched: true
            ),
            noResultsState: LibraryEmptyState(
                icon: "magnifyingglass",
                headline: "No bookmarks match that search",
                detail: "Search matches titles and addresses. Try a shorter word, or pick a different folder on the left."
            ),
            destructive: LibraryDestructiveAction(
                title: "Remove All Bookmarks",
                icon: "trash",
                isEnabled: !repository.bookmarks.isEmpty,
                action: { showingRemoveAllAlert = true }
            ),
            onClose: onClose,
            onOpen: open,
            onRemove: { items in items.forEach(repository.deleteBookmark) },
            rowMenu: menu,
            row: { bookmark, density in BookmarkRow(bookmark: bookmark, density: density) }
        )
        // A full page is one of Cherry's own surfaces, like Settings, and takes
        // the app's colours. The 300pt sidebar still follows an imported
        // Firefox theme, because it sits inside the themed window chrome.
        .modifier(BookmarkSidebarTheming(
            isThemed: presentation == .sidebar && !isPrivateMode
        ))
        .alert("Remove All Bookmarks", isPresented: $showingRemoveAllAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Remove All", role: .destructive) { repository.deleteAllBookmarks() }
        } message: {
            Text("This removes every bookmark, including the ones on your bookmark bar. This cannot be undone.")
        }
    }

    private func open(_ bookmarks: [Bookmark]) {
        guard let first = bookmarks.first else { return }
        if bookmarks.count == 1 || onOpenInNewTab == nil {
            onBookmarkClick(first)
        } else {
            bookmarks.forEach { onOpenInNewTab?($0) }
        }
    }

    @CherryMenuBuilder
    private func menu(for bookmark: Bookmark) -> [CherryMenuItem] {
        CherryMenuItem.action("Open") { onBookmarkClick(bookmark) }
        if let onOpenInNewTab {
            CherryMenuItem.action("Open in New Tab") { onOpenInNewTab(bookmark) }
        }
        CherryMenuItem.separator
        CherryMenuItem.action("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(bookmark.url.absoluteString, forType: .string)
        }
        CherryMenuItem.separator
        CherryMenuItem.action(
            bookmark.isInBookmarkBar ? "Remove from Bookmark Bar" : "Add to Bookmark Bar"
        ) {
            var updated = bookmark
            updated.isInBookmarkBar.toggle()
            repository.updateBookmark(updated)
        }
        CherryMenuItem.separator
        CherryMenuItem.action("Delete Bookmark", destructive: true) {
            repository.deleteBookmark(bookmark)
        }
    }
}

/// An imported Firefox theme reaches the sidebar and stops at the page.
private struct BookmarkSidebarTheming: ViewModifier {
    let isThemed: Bool

    func body(content: Content) -> some View {
        if isThemed {
            content
                .foregroundStyle(FirefoxThemeManager.shared.sidebarText ?? Color.primary)
                .background(
                    FirefoxThemeManager.shared.sidebarBackground
                        ?? Color(nsColor: .windowBackgroundColor)
                )
        } else {
            content
        }
    }
}

/// What a bookmark row encodes: which site, what you called it, where it
/// lives, which folder it is filed in, whether it is on the bookmark bar, and
/// when you saved it.
///
/// The folder and the bar flag were in the store and not on the screen. They
/// are the two facts that turn a flat list into something you can navigate.
struct BookmarkRow: View {
    let bookmark: Bookmark
    let density: LibraryDensity

    private var accent: Color { SettingsManager.shared.accentColor }

    var body: some View {
        LibraryRow(
            title: bookmark.title.isEmpty
                ? (bookmark.url.host ?? bookmark.url.absoluteString)
                : bookmark.title,
            subtitle: bookmark.url.host ?? bookmark.url.absoluteString,
            density: density,
            subtitleWidth: density.showsSecondaryColumns ? 172 : 146
        ) {
            LibraryFavicon(image: bookmark.favicon)
        } meta: {
            // The folder column is the first thing to go when the window
            // narrows: in every scope the section heading above the row is
            // already the folder's name, so the column is the one fact on this
            // row that is stated twice.
            if density.showsSecondaryColumns {
                LibraryMeta(text: bookmark.folder ?? "", width: 100, alignment: .leading)
            }
            // The pin keeps its slot whether or not it is filled, so the date
            // column beside it stays a column instead of stepping sideways
            // every time a bookmark is or is not on the bar.
            Image(systemName: bookmark.isInBookmarkBar ? "pin.fill" : "pin")
                .font(.system(size: density.isColumnar ? 10 : 9))
                .foregroundStyle(bookmark.isInBookmarkBar ? accent : Color.clear)
                .frame(width: density.isColumnar ? 16 : 14)
                .help(bookmark.isInBookmarkBar ? "On the bookmark bar" : "")
            LibraryMeta(
                text: BookmarkLibrary.addedText(bookmark.createdAt),
                width: density.isColumnar ? 62 : 56
            )
        } accessory: {}
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var parts = [bookmark.title, bookmark.url.host ?? ""]
        if let folder = bookmark.folder { parts.append("in \(folder)") }
        if bookmark.isInBookmarkBar { parts.append("on the bookmark bar") }
        parts.append("saved \(BookmarkLibrary.addedText(bookmark.createdAt))")
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}
