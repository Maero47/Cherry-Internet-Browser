//
//  HistoryRepository.swift
//  Cherry Browser
//

import CoreData
import AppKit
import Observation

@Observable
final class HistoryRepository {
    static let shared = HistoryRepository()

    private let persistence: PersistenceController
    private(set) var historyItems: [HistoryItem] = []
    private(set) var groupedHistory: [HistoryGroup] = []

    /// - Parameter persistence: the store to read and write. The app always uses
    ///   the shared one; the parameter exists so a test can point a repository at
    ///   `PersistenceController(inMemory: true)` and populate it, which is how
    ///   `MCPHistorySearchCostTests` measures `searchHistory` against 20,000 rows
    ///   without touching the user's real history.
    init(persistence: PersistenceController = .shared) {
        self.persistence = persistence
        fetchHistory()
    }

    // MARK: - Fetch

    func fetchHistory(limit: Int? = nil) {
        let context = persistence.viewContext
        let request = NSFetchRequest<HistoryEntity>(entityName: "HistoryEntity")
        request.sortDescriptors = [NSSortDescriptor(key: "visitDate", ascending: false)]

        if let limit = limit {
            request.fetchLimit = limit
        }

        do {
            let entities = try context.fetch(request)
            historyItems = entities.map { HistoryItem(entity: $0) }
            groupedHistory = groupHistoryByDate(historyItems)
        } catch {
            print("Failed to fetch history: \(error)")
        }
    }

    func fetchHistory(from startDate: Date, to endDate: Date) -> [HistoryItem] {
        let context = persistence.viewContext
        let request = NSFetchRequest<HistoryEntity>(entityName: "HistoryEntity")
        request.predicate = NSPredicate(format: "visitDate >= %@ AND visitDate <= %@", startDate as CVarArg, endDate as CVarArg)
        request.sortDescriptors = [NSSortDescriptor(key: "visitDate", ascending: false)]

        do {
            let entities = try context.fetch(request)
            return entities.map { HistoryItem(entity: $0) }
        } catch {
            print("Failed to fetch history: \(error)")
            return []
        }
    }

    func recentHistory(limit: Int = 10) -> [HistoryItem] {
        Array(historyItems.prefix(limit))
    }

    // MARK: - Add

    func addHistoryItem(url: URL, title: String, favicon: NSImage? = nil) {
        let context = persistence.viewContext

        // Check if URL already exists in history
        let request = NSFetchRequest<HistoryEntity>(entityName: "HistoryEntity")
        request.predicate = NSPredicate(format: "url == %@", url.absoluteString)

        do {
            if let existing = try context.fetch(request).first {
                // Update existing entry
                existing.title = title
                existing.visitDate = Date()
                existing.visitCount += 1
                if let favicon = favicon {
                    existing.favicon = favicon
                }
            } else {
                // Create new entry
                let entity = HistoryEntity(context: context)
                entity.id = UUID()
                entity.url = url.absoluteString
                entity.title = title
                entity.favicon = favicon
                entity.visitDate = Date()
                entity.visitCount = 1
            }

            persistence.save()
            fetchHistory()
        } catch {
            print("Failed to add history item: \(error)")
        }
    }

    /// Batch add for browser import, preserving the source browser's real
    /// visit dates. URLs already in history are merged (visit counts add up,
    /// the newest visit date wins, an icon fills in a missing one) rather
    /// than duplicated. `favicon` is the already-encoded icon bytes (PNG)
    /// from the source browser, stored as-is. Saves and refetches once.
    /// Returns how many entries were new vs merged, and how many received
    /// a source icon.
    @discardableResult
    func importHistoryItems(_ entries: [(url: URL, title: String, favicon: Data?, visitDate: Date, visitCount: Int)]) -> (added: Int, merged: Int, withFavicons: Int) {
        let context = persistence.viewContext

        var existingByURL: [String: HistoryEntity] = [:]
        let request = NSFetchRequest<HistoryEntity>(entityName: "HistoryEntity")
        if let existing = try? context.fetch(request) {
            for entity in existing {
                existingByURL[entity.url] = entity
            }
        }

        var added = 0
        var merged = 0
        var withFavicons = 0
        for entry in entries {
            let urlString = entry.url.absoluteString
            if let existing = existingByURL[urlString] {
                existing.visitCount = Int32(clamping: Int64(existing.visitCount) + Int64(entry.visitCount))
                if entry.visitDate > existing.visitDate {
                    existing.visitDate = entry.visitDate
                    existing.title = entry.title
                }
                if existing.faviconData == nil, let favicon = entry.favicon {
                    existing.faviconData = favicon
                    withFavicons += 1
                }
                merged += 1
            } else {
                let entity = HistoryEntity(context: context)
                entity.id = UUID()
                entity.url = urlString
                entity.title = entry.title
                entity.faviconData = entry.favicon
                entity.visitDate = entry.visitDate
                entity.visitCount = Int32(clamping: entry.visitCount)
                existingByURL[urlString] = entity
                added += 1
                if entry.favicon != nil { withFavicons += 1 }
            }
        }

        if added > 0 || merged > 0 {
            persistence.save()
            fetchHistory()
        }
        return (added, merged, withFavicons)
    }

    // MARK: - Delete

    func deleteHistoryItem(_ item: HistoryItem) {
        let context = persistence.viewContext
        let request = NSFetchRequest<HistoryEntity>(entityName: "HistoryEntity")
        request.predicate = NSPredicate(format: "id == %@", item.id as CVarArg)

        do {
            if let entity = try context.fetch(request).first {
                context.delete(entity)
                persistence.save()
                fetchHistory()
            }
        } catch {
            print("Failed to delete history item: \(error)")
        }
    }

    func deleteHistory(from startDate: Date, to endDate: Date) {
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "HistoryEntity")
        request.predicate = NSPredicate(format: "visitDate >= %@ AND visitDate <= %@", startDate as CVarArg, endDate as CVarArg)

        do {
            try persistence.batchDelete(fetchRequest: request)
            fetchHistory()
        } catch {
            print("Failed to delete history: \(error)")
        }
    }

    func clearAllHistory() {
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "HistoryEntity")

        do {
            try persistence.batchDelete(fetchRequest: request)
            fetchHistory()
        } catch {
            print("Failed to clear history: \(error)")
        }
    }

    func clearHistory(since date: Date) {
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "HistoryEntity")
        request.predicate = NSPredicate(format: "visitDate >= %@", date as CVarArg)

        do {
            try persistence.batchDelete(fetchRequest: request)
            fetchHistory()
        } catch {
            print("Failed to clear history since date: \(error)")
        }
    }

    func clearHistoryOlderThan(days: Int) {
        let calendar = Calendar.current
        guard let cutoffDate = calendar.date(byAdding: .day, value: -days, to: Date()) else { return }

        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "HistoryEntity")
        request.predicate = NSPredicate(format: "visitDate < %@", cutoffDate as CVarArg)

        do {
            try persistence.batchDelete(fetchRequest: request)
            fetchHistory()
        } catch {
            print("Failed to clear old history: \(error)")
        }
    }

    // MARK: - Search

    /// Every row whose title or URL contains `query`, in `historyItems` order
    /// (newest visit first). Unranked — this is the general-purpose search the
    /// library screen and the MCP tool use.
    ///
    /// The scan is still linear in history size, which is a fact about
    /// `historyItems` being an in-memory array; what changed is the constant.
    /// It used to case-fold both fields of every row on every call, and now
    /// reads the fold `HistoryItem` did when it was built. See
    /// `HistoryItem.loweredTitle`.
    func searchHistory(query: String) -> [HistoryItem] {
        guard !query.isEmpty else { return historyItems }

        let needle = OmniboxRanking.needle(for: query)
        guard !needle.isEmpty else { return historyItems }
        return historyItems.filter { item in
            item.searchText.urlContains(needle) || item.searchText.titleContains(needle)
        }
    }

    /// The omnibox's history matches, ranked by frecency and match position.
    ///
    /// The query is folded to bytes once, and every row is then matched, scored
    /// and (if it is still in the running) deduplicated in a single pass. There
    /// is no separate filter step: `OmniboxRanking.matchKind` answers "does this
    /// match" and "where did it match" from the same two byte searches, so a
    /// row that is going to be discarded costs nothing beyond those. Nothing on
    /// this path allocates per row — the folding, and the host/path/query
    /// boundaries the ranking needs, were done when the row was built
    /// (`HistoryItem.searchText`).
    ///
    /// Private-window visits cannot appear here because they are never written:
    /// `WebViewWrapper.Coordinator.saveHistory` refuses to record a tab whose
    /// `isPrivate` is true — or whose tab has been deallocated, so a
    /// just-closed private tab cannot slip through either. This method reads
    /// `historyItems`, which is the store, so there is nothing extra to filter
    /// here and nothing that could be forgotten — the omnibox cannot rank a
    /// private visit because no private visit exists to rank.
    ///
    /// `OmniboxHistoryCostTests` measures the whole thing at 20,000 rows.
    func rankedSuggestions(
        query: String, limit: Int, now: Date = Date()
    ) -> [RankedOmniboxCandidate] {
        let needle = OmniboxRanking.needle(for: query)
        guard !needle.isEmpty, limit > 0 else { return [] }

        let candidates = historyItems.lazy.map { item in
            OmniboxCandidate(
                url: item.url,
                title: item.title,
                visitCount: item.visitCount,
                lastVisit: item.visitDate,
                text: item.searchText
            )
        }
        return OmniboxRanking.rank(candidates, needle: needle, now: now, limit: limit)
    }

    // MARK: - Grouping

    private func groupHistoryByDate(_ items: [HistoryItem]) -> [HistoryGroup] {
        let calendar = Calendar.current
        var groups: [String: [HistoryItem]] = [:]

        for item in items {
            let key: String
            if calendar.isDateInToday(item.visitDate) {
                key = "Today"
            } else if calendar.isDateInYesterday(item.visitDate) {
                key = "Yesterday"
            } else if calendar.isDate(item.visitDate, equalTo: Date(), toGranularity: .weekOfYear) {
                let formatter = DateFormatter()
                formatter.dateFormat = "EEEE"
                key = formatter.string(from: item.visitDate)
            } else {
                let formatter = DateFormatter()
                formatter.dateFormat = "MMMM d, yyyy"
                key = formatter.string(from: item.visitDate)
            }

            groups[key, default: []].append(item)
        }

        // Sort groups by date (most recent first)
        let sortedKeys = groups.keys.sorted { key1, key2 in
            if key1 == "Today" { return true }
            if key2 == "Today" { return false }
            if key1 == "Yesterday" { return true }
            if key2 == "Yesterday" { return false }

            // For other dates, compare by first item's date
            let date1 = groups[key1]?.first?.visitDate ?? Date.distantPast
            let date2 = groups[key2]?.first?.visitDate ?? Date.distantPast
            return date1 > date2
        }

        return sortedKeys.map { key in
            HistoryGroup(id: key, title: key, items: groups[key] ?? [])
        }
    }

    // MARK: - Export

    /// Snapshots the history rows the export needs. Cheap and main-actor-bound
    /// (it reads `historyItems`); the encoding half is `encodeToJSON`, which is
    /// pure and can run off the main actor.
    func exportSnapshot() -> [(url: URL, title: String, visitDate: Date, visitCount: Int)] {
        historyItems.map { ($0.url, $0.title, $0.visitDate, $0.visitCount) }
    }

    func exportToJSON() -> Data? {
        Self.encodeToJSON(exportSnapshot())
    }

    /// Serializes an export snapshot. `nonisolated` and taking its input by
    /// value so `DataExportService` can run it off the main actor — a large
    /// history otherwise froze the UI before the save panel even appeared.
    ///
    /// One formatter for the whole export, not one per row: constructing an
    /// `ISO8601DateFormatter` is expensive, and it used to be allocated inside
    /// the `map`.
    nonisolated static func encodeToJSON(
        _ items: [(url: URL, title: String, visitDate: Date, visitCount: Int)]
    ) -> Data? {
        let formatter = ISO8601DateFormatter()
        let exportItems = items.map { item in
            [
                "url": item.url.absoluteString,
                "title": item.title,
                "visitDate": formatter.string(from: item.visitDate),
                "visitCount": item.visitCount
            ] as [String: Any]
        }

        return try? JSONSerialization.data(withJSONObject: exportItems, options: .prettyPrinted)
    }
}
