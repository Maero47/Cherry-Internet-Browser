//
//  ChromiumImportReader.swift
//  Cherry Browser
//
//  Reads bookmarks and history from Chromium-family browsers
//  (Chrome, Brave, Edge). Formats:
//   - Bookmarks: <profile>/Bookmarks — JSON with roots.bookmark_bar/.other/.synced,
//     nodes { "type": "url"|"folder", "name", "url"?, "children"? }.
//   - History:   <profile>/History — SQLite, urls(url, title, last_visit_time,
//     visit_count); last_visit_time is microseconds since 1601-01-01 UTC.
//

import Foundation

struct ChromiumImportReader: BrowserDataReader {

    func read(_ type: ImportableDataType, from profile: SourceProfile) throws -> ImportedPayload {
        switch type {
        case .bookmarks:
            .bookmarks(try readBookmarks(from: profile))
        case .history:
            .history(try readHistory(from: profile))
        case .passwords:
            throw ImportError.unsupportedDataType(type)
        }
    }

    // MARK: - Bookmarks

    private func readBookmarks(from profile: SourceProfile) throws -> [ImportedBookmark] {
        let fileURL = profile.directory.appendingPathComponent("Bookmarks")
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw ImportError.wrapping(error)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = json["roots"] as? [String: Any] else {
            throw ImportError.parseError("unexpected Bookmarks JSON structure")
        }

        var results: [ImportedBookmark] = []
        for rootKey in ["bookmark_bar", "other", "synced"] {
            guard let root = roots[rootKey] as? [String: Any] else { continue }
            collect(node: root, folderPath: [], isBarRoot: rootKey == "bookmark_bar", isRootNode: true, into: &results)
        }
        return results
    }

    /// Depth-first walk. Items directly under the bookmark_bar root land on
    /// Cherry's bookmark bar; anything inside a folder gets the folder chain.
    /// A malformed node is skipped without aborting the walk.
    private func collect(node: [String: Any], folderPath: [String], isBarRoot: Bool, isRootNode: Bool, into results: inout [ImportedBookmark]) {
        guard let type = node["type"] as? String else { return }

        if type == "url" {
            guard let urlString = node["url"] as? String,
                  let url = isImportableSourceURL(urlString) else { return }
            let title = (node["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url.absoluteString
            results.append(ImportedBookmark(
                url: url,
                title: title,
                folderPath: folderPath,
                isInBookmarkBar: isBarRoot && folderPath.isEmpty
            ))
        } else if type == "folder" {
            let children = node["children"] as? [[String: Any]] ?? []
            // The root nodes themselves ("Bookmarks Bar", "Other Bookmarks",
            // "Synced") don't become Cherry folders — only nested ones do.
            var childPath = folderPath
            if !isRootNode, let name = node["name"] as? String, !name.isEmpty {
                childPath.append(name)
            }
            for child in children {
                collect(node: child, folderPath: childPath, isBarRoot: isBarRoot, isRootNode: false, into: &results)
            }
        }
    }

    // MARK: - History

    private func readHistory(from profile: SourceProfile) throws -> [ImportedHistoryRow] {
        let fileURL = profile.directory.appendingPathComponent("History")
        let database = try ImportSQLiteDatabase(copying: fileURL)
        defer { database.close() }

        var rows: [ImportedHistoryRow] = []
        try database.forEachRow(
            "SELECT url, title, last_visit_time, visit_count FROM urls WHERE url <> '' AND last_visit_time > 0"
        ) { row in
            guard let urlString = row.text(0), let url = isImportableSourceURL(urlString) else { return }
            let title = row.text(1).flatMap { $0.isEmpty ? nil : $0 } ?? url.absoluteString
            let lastVisit = BrowserEpoch.dateFromChromium(microseconds: row.int64(2))
            let visitCount = max(1, Int(row.int64(3)))
            rows.append(ImportedHistoryRow(url: url, title: title, lastVisit: lastVisit, visitCount: visitCount))
        }
        return rows
    }
}
