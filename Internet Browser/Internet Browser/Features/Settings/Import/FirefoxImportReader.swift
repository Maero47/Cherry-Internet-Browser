//
//  FirefoxImportReader.swift
//  Cherry Browser
//
//  Reads bookmarks and history from Firefox profiles. Both live in
//  <profile>/places.sqlite:
//   - Bookmarks: moz_bookmarks(id, type, parent, fk, title, guid) with
//     type 1 = bookmark, 2 = folder, joined to moz_places(id, url) via fk.
//     The toolbar folder has guid "toolbar_____"; tags live under
//     "tags________" and are excluded.
//   - History: moz_places(id, url, title) + moz_historyvisits(place_id,
//     visit_date); visit_date is microseconds since 1970-01-01 UTC.
//

import Foundation

struct FirefoxImportReader: BrowserDataReader {

    func read(_ type: ImportableDataType, from profile: SourceProfile) throws -> ImportedPayload {
        switch type {
        case .bookmarks:
            .bookmarks(try readBookmarks(from: profile))
        case .history:
            .history(try readHistory(from: profile))
        case .favorites:
            .favorites(try readBookmarks(from: profile).filter(\.isInBookmarkBar))
        case .passwords:
            throw ImportError.unsupportedDataType(type)
        }
    }

    /// Site icons live in <profile>/favicons.sqlite (separate DB since FF 55).
    func readFavicons(from profile: SourceProfile) -> ImportedFaviconStore {
        ImportFaviconReader.firefoxStore(profileDirectory: profile.directory)
    }

    private func placesDatabase(for profile: SourceProfile) throws -> ImportSQLiteDatabase {
        try ImportSQLiteDatabase(copying: profile.directory.appendingPathComponent("places.sqlite"))
    }

    // MARK: - Bookmarks

    private struct Node {
        let parent: Int64
        let type: Int64
        let title: String?
        let url: String?
        let guid: String
    }

    private func readBookmarks(from profile: SourceProfile) throws -> [ImportedBookmark] {
        let database = try placesDatabase(for: profile)
        defer { database.close() }

        var nodes: [Int64: Node] = [:]
        try database.forEachRow("""
            SELECT b.id, b.parent, b.type, b.title, p.url, b.guid
            FROM moz_bookmarks b LEFT JOIN moz_places p ON b.fk = p.id
            """) { row in
            nodes[row.int64(0)] = Node(
                parent: row.int64(1),
                type: row.int64(2),
                title: row.text(3),
                url: row.text(4),
                guid: row.text(5) ?? ""
            )
        }

        var results: [ImportedBookmark] = []
        for node in nodes.values where node.type == 1 {
            guard let urlString = node.url, let url = isImportableSourceURL(urlString) else { continue }

            // Walk up the folder chain to the containing root; skip anything
            // under the tags root. Bounded to guard against parent cycles.
            var path: [String] = []
            var isInToolbar = false
            var underTags = false
            var currentParent = node.parent
            var hops = 0
            while let parent = nodes[currentParent], hops < 64 {
                hops += 1
                if parent.guid == "tags________" { underTags = true; break }
                let isRoot = parent.guid == "root________" || parent.guid == "menu________"
                    || parent.guid == "toolbar_____" || parent.guid == "unfiled_____"
                    || parent.guid == "mobile______"
                if isRoot {
                    isInToolbar = parent.guid == "toolbar_____"
                    break
                }
                if let title = parent.title, !title.isEmpty {
                    path.insert(title, at: 0)
                }
                currentParent = parent.parent
            }
            if underTags { continue }

            let title = node.title.flatMap { $0.isEmpty ? nil : $0 } ?? url.absoluteString
            results.append(ImportedBookmark(
                url: url,
                title: title,
                folderPath: path,
                isInBookmarkBar: isInToolbar && path.isEmpty
            ))
        }
        return results
    }

    // MARK: - History

    private func readHistory(from profile: SourceProfile) throws -> [ImportedHistoryRow] {
        let database = try placesDatabase(for: profile)
        defer { database.close() }

        var rows: [ImportedHistoryRow] = []
        try database.forEachRow("""
            SELECT p.url, p.title, MAX(v.visit_date), COUNT(v.id)
            FROM moz_places p JOIN moz_historyvisits v ON v.place_id = p.id
            GROUP BY p.id
            """) { row in
            guard let urlString = row.text(0), let url = isImportableSourceURL(urlString) else { return }
            let title = row.text(1).flatMap { $0.isEmpty ? nil : $0 } ?? url.absoluteString
            let lastVisit = BrowserEpoch.dateFromFirefox(microseconds: row.int64(2))
            let visitCount = max(1, Int(row.int64(3)))
            rows.append(ImportedHistoryRow(url: url, title: title, lastVisit: lastVisit, visitCount: visitCount))
        }
        return rows
    }
}
