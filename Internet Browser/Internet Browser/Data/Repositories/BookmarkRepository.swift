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

    /// Hosts whose favicon lookup already failed this run — not retried until
    /// the next launch so an unreachable host can't cause a retry storm.
    private var failedFaviconHosts: Set<String> = []
    private var isFetchingMissingFavicons = false

    init() {
        fetchBookmarks()
        fetchMissingFavicons()
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

    /// Batch add for browser import: skips URLs that already exist (in the
    /// store or earlier in `entries`), saves and refetches once instead of
    /// per item. `favicon` is the already-encoded icon bytes (PNG) from the
    /// source browser, stored as-is. Returns how many were added vs skipped
    /// as duplicates, and how many added entries carried an icon.
    @discardableResult
    func importBookmarks(_ entries: [(url: URL, title: String, favicon: Data?, folder: String?, isInBookmarkBar: Bool)]) -> (added: Int, skipped: Int, withFavicons: Int) {
        let context = persistence.viewContext
        var existingURLs = Set(bookmarks.map { $0.url.absoluteString })
        var added = 0
        var withFavicons = 0
        var sortOrder = Int32(bookmarks.count)

        for entry in entries {
            let urlString = entry.url.absoluteString
            guard existingURLs.insert(urlString).inserted else { continue }

            let entity = BookmarkEntity(context: context)
            entity.id = UUID()
            entity.url = urlString
            entity.title = entry.title
            entity.faviconData = entry.favicon
            entity.folder = entry.folder
            entity.createdAt = Date()
            entity.visitCount = 0
            entity.sortOrder = sortOrder
            entity.isInBookmarkBar = entry.isInBookmarkBar
            sortOrder += 1
            added += 1
            if entry.favicon != nil { withFavicons += 1 }
        }

        if added > 0 {
            persistence.save()
            fetchBookmarks()
        }
        return (added, entries.count - added, withFavicons)
    }

    // MARK: - Favicon Fetching

    /// Fills in `faviconData` for every bookmark that has none, using
    /// Google's favicon service. Fetches run off-main, one per distinct host
    /// (50 GitHub bookmarks fetch one icon) with a small concurrency cap;
    /// results are written back on the view context in a single save. A
    /// failed fetch just leaves the placeholder glyph.
    func fetchMissingFavicons() {
        guard !isFetchingMissingFavicons else { return }

        var hostsToFetch: [String: String] = [:] // host key -> host to query
        for bookmark in bookmarks where bookmark.favicon == nil {
            guard let host = bookmark.url.host,
                  let key = bookmark.url.faviconHostKey,
                  !failedFaviconHosts.contains(key) else { continue }
            if hostsToFetch[key] == nil { hostsToFetch[key] = host }
        }
        guard !hostsToFetch.isEmpty else { return }
        isFetchingMissingFavicons = true

        Task.detached(priority: .utility) { [hostsToFetch] in
            let icons = await Self.fetchFavicons(forHosts: hostsToFetch)
            await MainActor.run {
                self.applyFetchedFavicons(icons, requested: Set(hostsToFetch.keys))
            }
        }
    }

    /// Downloads icons for `hosts` (host key -> query host), keeping at most
    /// a handful of requests in flight. Returns only icons whose bytes decode
    /// to a real image.
    private static func fetchFavicons(forHosts hosts: [String: String]) async -> [String: Data] {
        let pairs = Array(hosts)
        let maxConcurrent = 6
        var icons: [String: Data] = [:]

        await withTaskGroup(of: (String, Data?).self) { group in
            var next = 0
            while next < pairs.count && next < maxConcurrent {
                let (key, host) = pairs[next]
                group.addTask { (key, await fetchFaviconData(host: host)) }
                next += 1
            }
            while let (key, data) = await group.next() {
                if let data = data { icons[key] = data }
                if next < pairs.count {
                    let (key, host) = pairs[next]
                    group.addTask { (key, await fetchFaviconData(host: host)) }
                    next += 1
                }
            }
        }
        return icons
    }

    private static func fetchFaviconData(host: String) async -> Data? {
        guard let url = URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=64"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let image = NSImage(data: data), image.size.width > 1 else { return nil }
        return data
    }

    private func applyFetchedFavicons(_ icons: [String: Data], requested: Set<String>) {
        isFetchingMissingFavicons = false
        failedFaviconHosts.formUnion(requested.subtracting(icons.keys))
        guard !icons.isEmpty else { return }

        let context = persistence.viewContext
        let request = NSFetchRequest<BookmarkEntity>(entityName: "BookmarkEntity")
        request.predicate = NSPredicate(format: "faviconData == nil")

        do {
            var changed = false
            for entity in try context.fetch(request) {
                guard let key = entity.urlValue?.faviconHostKey,
                      let data = icons[key] else { continue }
                entity.faviconData = data
                changed = true
            }
            if changed {
                persistence.save()
                fetchBookmarks()
            }
        } catch {
            print("Failed to apply fetched favicons: \(error)")
        }
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
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "BookmarkEntity")

        do {
            try persistence.batchDelete(fetchRequest: request)
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
