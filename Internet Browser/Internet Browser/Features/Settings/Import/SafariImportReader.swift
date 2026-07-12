//
//  SafariImportReader.swift
//  Cherry Browser
//
//  Reads bookmarks and history from Safari (~/Library/Safari). Requires
//  Full Disk Access; a TCC denial surfaces as ImportError.fullDiskAccessRequired.
//   - Bookmarks: Bookmarks.plist (binary plist) — nested Children arrays;
//     leaves have WebBookmarkType == WebBookmarkTypeLeaf (URLString +
//     URIDictionary.title), folders are WebBookmarkTypeList (Title +
//     Children). The bookmarks bar list is titled "BookmarksBar".
//   - History: History.db — SQLite, history_items(id, url) +
//     history_visits(history_item, visit_time, title); visit_time is
//     CFAbsoluteTime (seconds since 2001-01-01 UTC).
//

import Foundation

struct SafariImportReader: BrowserDataReader {

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
        let fileURL = profile.directory.appendingPathComponent("Bookmarks.plist")
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw ImportError.wrapping(error)
        }

        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let root = plist as? [String: Any] else {
            throw ImportError.parseError("unexpected Bookmarks.plist structure")
        }

        var results: [ImportedBookmark] = []
        let children = root["Children"] as? [[String: Any]] ?? []
        for child in children {
            let title = (child["Title"] as? String) ?? ""
            // Skip Safari's special top-level lists that aren't user bookmarks.
            if title == "History" || title == "com.apple.ReadingList" { continue }
            let isBar = title == "BookmarksBar"
            collect(node: child, folderPath: [], isBarRoot: isBar, isRootNode: true, into: &results)
        }
        return results
    }

    private func collect(node: [String: Any], folderPath: [String], isBarRoot: Bool, isRootNode: Bool, into results: inout [ImportedBookmark]) {
        let type = node["WebBookmarkType"] as? String

        if type == "WebBookmarkTypeLeaf" {
            guard let urlString = node["URLString"] as? String,
                  let url = isImportableSourceURL(urlString) else { return }
            let uriDictionary = node["URIDictionary"] as? [String: Any]
            let title = (uriDictionary?["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url.absoluteString
            results.append(ImportedBookmark(
                url: url,
                title: title,
                folderPath: folderPath,
                isInBookmarkBar: isBarRoot && folderPath.isEmpty
            ))
        } else if type == "WebBookmarkTypeList" || node["Children"] != nil {
            // The BookmarksBar/Menu roots don't become Cherry folders; nested lists do.
            var childPath = folderPath
            if !isRootNode, let name = node["Title"] as? String, !name.isEmpty {
                childPath.append(name)
            }
            for child in node["Children"] as? [[String: Any]] ?? [] {
                collect(node: child, folderPath: childPath, isBarRoot: isBarRoot, isRootNode: false, into: &results)
            }
        }
        // WebBookmarkTypeProxy and anything unrecognized is skipped.
    }

    // MARK: - History

    private func readHistory(from profile: SourceProfile) throws -> [ImportedHistoryRow] {
        let fileURL = profile.directory.appendingPathComponent("History.db")
        let database = try ImportSQLiteDatabase(copying: fileURL)
        defer { database.close() }

        // Aggregate visits per item in Swift: newest visit wins the title/date.
        struct Aggregate {
            var url: URL
            var title: String?
            var lastVisit: Double = -.greatestFiniteMagnitude
            var count = 0
        }
        var aggregates: [Int64: Aggregate] = [:]

        try database.forEachRow("""
            SELECT i.id, i.url, v.visit_time, v.title
            FROM history_items i JOIN history_visits v ON v.history_item = i.id
            """) { row in
            guard let urlString = row.text(1), let url = isImportableSourceURL(urlString) else { return }
            let itemID = row.int64(0)
            var aggregate = aggregates[itemID] ?? Aggregate(url: url)
            let visitTime = row.double(2)
            aggregate.count += 1
            if visitTime >= aggregate.lastVisit {
                aggregate.lastVisit = visitTime
                if let title = row.text(3), !title.isEmpty {
                    aggregate.title = title
                }
            }
            aggregates[itemID] = aggregate
        }

        return aggregates.values.map { aggregate in
            ImportedHistoryRow(
                url: aggregate.url,
                title: aggregate.title ?? aggregate.url.absoluteString,
                lastVisit: BrowserEpoch.dateFromSafari(seconds: aggregate.lastVisit),
                visitCount: max(1, aggregate.count)
            )
        }
    }
}
