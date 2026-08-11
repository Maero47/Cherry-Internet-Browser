//
//  HistoryEntity.swift
//  Cherry Browser
//

import CoreData
import AppKit

@objc(HistoryEntity)
public class HistoryEntity: NSManagedObject {
    @NSManaged public var id: UUID
    @NSManaged public var url: String
    @NSManaged public var title: String
    @NSManaged public var faviconData: Data?
    @NSManaged public var visitDate: Date
    @NSManaged public var visitCount: Int32
}

extension HistoryEntity {
    var favicon: NSImage? {
        get {
            guard let data = faviconData else { return nil }
            return NSImage(data: data)
        }
        set {
            faviconData = newValue?.tiffRepresentation
        }
    }

    var urlValue: URL? {
        URL(string: url)
    }
}

// MARK: - History Item Model (for use in views)

struct HistoryItem: Identifiable, Hashable {
    let id: UUID
    var url: URL
    var title: String
    var favicon: NSImage?
    var visitDate: Date
    var visitCount: Int

    /// This row's title and URL, case-folded to UTF-8 once when the row is
    /// built, with the URL's host/path/query boundaries recorded.
    ///
    /// Every history search is a linear scan of `historyItems`, and it used to
    /// call `lowercased()` on BOTH fields of every row on every call — two
    /// allocations per row per keystroke, which is where the 20,000-row search
    /// spent most of its time. Folding here moves that cost to the point where
    /// the row is created, which happens once per fetch rather than once per
    /// keystroke, and lets the scan itself be a byte comparison. See
    /// `OmniboxSearchText` for the measurements.
    ///
    /// `let`, and deliberately not derived on demand from the `var` fields
    /// above: nothing in the app mutates a `HistoryItem` after building it, and
    /// a stale fold would be a silent wrong-results bug rather than a visible
    /// one.
    let searchText: OmniboxSearchText

    init(
        id: UUID = UUID(),
        url: URL,
        title: String,
        favicon: NSImage? = nil,
        visitDate: Date = Date(),
        visitCount: Int = 1
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.favicon = favicon
        self.visitDate = visitDate
        self.visitCount = visitCount
        self.searchText = OmniboxSearchText(url: url.absoluteString, title: title)
    }

    init(entity: HistoryEntity) {
        self.id = entity.id
        self.url = URL(string: entity.url) ?? URL(string: "about:blank")!
        self.title = entity.title
        self.favicon = entity.favicon
        self.visitDate = entity.visitDate
        self.visitCount = Int(entity.visitCount)
        self.searchText = OmniboxSearchText(url: entity.url, title: entity.title)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: HistoryItem, rhs: HistoryItem) -> Bool {
        lhs.id == rhs.id
    }

    var displayDate: String {
        let formatter = DateFormatter()
        let calendar = Calendar.current

        if calendar.isDateInToday(visitDate) {
            formatter.dateFormat = "h:mm a"
            return "Today, \(formatter.string(from: visitDate))"
        } else if calendar.isDateInYesterday(visitDate) {
            formatter.dateFormat = "h:mm a"
            return "Yesterday, \(formatter.string(from: visitDate))"
        } else if calendar.isDate(visitDate, equalTo: Date(), toGranularity: .weekOfYear) {
            formatter.dateFormat = "EEEE, h:mm a"
            return formatter.string(from: visitDate)
        } else {
            formatter.dateFormat = "MMM d, yyyy"
            return formatter.string(from: visitDate)
        }
    }
}

// MARK: - History Group (for grouping by date)

struct HistoryGroup: Identifiable {
    let id: String
    let title: String
    let items: [HistoryItem]

    var date: Date? {
        items.first?.visitDate
    }
}
