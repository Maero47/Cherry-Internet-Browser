//
//  BookmarkRepository.swift
//  Cherry Browser
//

import CoreData
import AppKit
import Observation

@Observable
final class BookmarkRepository {
    static let shared = BookmarkRepository()

    private let persistence = PersistenceController.shared
    private(set) var bookmarks: [Bookmark] = []
    private(set) var bookmarkBarItems: [Bookmark] = []
    private(set) var folders: [String] = []

    init() {
        fetchBookmarks()
    }

    // MARK: - Fetch

    func fetchBookmarks() {
        let context = persistence.viewContext
        let request = NSFetchRequest<BookmarkEntity>(entityName: "BookmarkEntity")
        request.sortDescriptors = [
            NSSortDescriptor(key: "sortOrder", ascending: true),
            NSSortDescriptor(key: "createdAt", ascending: false)
        ]

        do {
            let entities = try context.fetch(request)
            bookmarks = entities.map { Bookmark(entity: $0) }
            bookmarkBarItems = bookmarks.filter { $0.isInBookmarkBar }
            folders = Array(Set(bookmarks.compactMap { $0.folder })).sorted()
        } catch {
            print("Failed to fetch bookmarks: \(error)")
        }
    }

    func bookmarks(in folder: String?) -> [Bookmark] {
        if let folder = folder {
            return bookmarks.filter { $0.folder == folder }
        }
        return bookmarks.filter { $0.folder == nil }
    }

    // MARK: - Add

    @discardableResult
    func addBookmark(url: URL, title: String, favicon: NSImage? = nil, folder: String? = nil, isInBookmarkBar: Bool = false) -> Bookmark {
        let context = persistence.viewContext

        let entity = BookmarkEntity(context: context)
        entity.id = UUID()
        entity.url = url.absoluteString
        entity.title = title
        entity.favicon = favicon
        entity.folder = folder
        entity.createdAt = Date()
        entity.visitCount = 0
        entity.sortOrder = Int32(bookmarks.count)
        entity.isInBookmarkBar = isInBookmarkBar

        persistence.save()
        fetchBookmarks()

        return Bookmark(entity: entity)
    }

    // MARK: - Update

    func updateBookmark(_ bookmark: Bookmark) {
        let context = persistence.viewContext
        let request = NSFetchRequest<BookmarkEntity>(entityName: "BookmarkEntity")
        request.predicate = NSPredicate(format: "id == %@", bookmark.id as CVarArg)

        do {
            if let entity = try context.fetch(request).first {
                entity.url = bookmark.url.absoluteString
                entity.title = bookmark.title
                entity.favicon = bookmark.favicon
                entity.folder = bookmark.folder
                entity.visitCount = Int32(bookmark.visitCount)
                entity.sortOrder = Int32(bookmark.sortOrder)
                entity.isInBookmarkBar = bookmark.isInBookmarkBar

                persistence.save()
                fetchBookmarks()
            }
        } catch {
            print("Failed to update bookmark: \(error)")
        }
    }

    func incrementVisitCount(for bookmark: Bookmark) {
        var updated = bookmark
        updated.visitCount += 1
        updateBookmark(updated)
    }

    // MARK: - Delete

    func deleteBookmark(_ bookmark: Bookmark) {
        let context = persistence.viewContext
        let request = NSFetchRequest<BookmarkEntity>(entityName: "BookmarkEntity")
        request.predicate = NSPredicate(format: "id == %@", bookmark.id as CVarArg)

        do {
            if let entity = try context.fetch(request).first {
                context.delete(entity)
                persistence.save()
                fetchBookmarks()
            }
        } catch {
            print("Failed to delete bookmark: \(error)")
        }
    }

    func deleteAllBookmarks() {
        let context = persistence.viewContext
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "BookmarkEntity")
        let deleteRequest = NSBatchDeleteRequest(fetchRequest: request)

        do {
            try context.execute(deleteRequest)
            persistence.save()
            fetchBookmarks()
        } catch {
            print("Failed to delete all bookmarks: \(error)")
        }
    }

    // MARK: - Search

    func searchBookmarks(query: String) -> [Bookmark] {
        guard !query.isEmpty else { return bookmarks }

        let lowercasedQuery = query.lowercased()
        return bookmarks.filter { bookmark in
            bookmark.title.lowercased().contains(lowercasedQuery) ||
            bookmark.url.absoluteString.lowercased().contains(lowercasedQuery)
        }
    }

    // MARK: - Check

    func isBookmarked(url: URL) -> Bool {
        bookmarks.contains { $0.url.absoluteString == url.absoluteString }
    }

    func bookmark(for url: URL) -> Bookmark? {
        bookmarks.first { $0.url.absoluteString == url.absoluteString }
    }

    // MARK: - Folders

    func createFolder(name: String) {
        if !folders.contains(name) {
            folders.append(name)
            folders.sort()
        }
    }

    func deleteFolder(name: String) {
        // Move all bookmarks in folder to root
        let context = persistence.viewContext
        let request = NSFetchRequest<BookmarkEntity>(entityName: "BookmarkEntity")
        request.predicate = NSPredicate(format: "folder == %@", name)

        do {
            let entities = try context.fetch(request)
            for entity in entities {
                entity.folder = nil
            }
            persistence.save()
            fetchBookmarks()
        } catch {
            print("Failed to delete folder: \(error)")
        }
    }

    // MARK: - Import/Export

    func exportToHTML() -> String {
        var html = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <TITLE>Bookmarks</TITLE>
        <H1>Bookmarks</H1>
        <DL><p>

        """

        // Group by folder
        let rootBookmarks = bookmarks.filter { $0.folder == nil }
        let folderGroups = Dictionary(grouping: bookmarks.filter { $0.folder != nil }) { $0.folder! }

        // Root bookmarks
        for bookmark in rootBookmarks {
            let timestamp = Int(bookmark.createdAt.timeIntervalSince1970)
            html += "    <DT><A HREF=\"\(bookmark.url.absoluteString)\" ADD_DATE=\"\(timestamp)\">\(bookmark.title)</A>\n"
        }

        // Folder bookmarks
        for (folder, items) in folderGroups.sorted(by: { $0.key < $1.key }) {
            html += "    <DT><H3>\(folder)</H3>\n    <DL><p>\n"
            for bookmark in items {
                let timestamp = Int(bookmark.createdAt.timeIntervalSince1970)
                html += "        <DT><A HREF=\"\(bookmark.url.absoluteString)\" ADD_DATE=\"\(timestamp)\">\(bookmark.title)</A>\n"
            }
            html += "    </DL><p>\n"
        }

        html += "</DL><p>\n"
        return html
    }
}
