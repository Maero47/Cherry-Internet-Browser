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

    private let persistence = PersistenceController.shared
    private(set) var historyItems: [HistoryItem] = []
    private(set) var groupedHistory: [HistoryGroup] = []

    init() {
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

    func searchHistory(query: String) -> [HistoryItem] {
        guard !query.isEmpty else { return historyItems }

        let lowercasedQuery = query.lowercased()
        return historyItems.filter { item in
            item.title.lowercased().contains(lowercasedQuery) ||
            item.url.absoluteString.lowercased().contains(lowercasedQuery)
        }
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

    func exportToJSON() -> Data? {
        let exportItems = historyItems.map { item in
            [
                "url": item.url.absoluteString,
                "title": item.title,
                "visitDate": ISO8601DateFormatter().string(from: item.visitDate),
                "visitCount": item.visitCount
            ] as [String: Any]
        }

        return try? JSONSerialization.data(withJSONObject: exportItems, options: .prettyPrinted)
    }
}
