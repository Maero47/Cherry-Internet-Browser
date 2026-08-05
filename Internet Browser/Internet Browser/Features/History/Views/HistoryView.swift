//
//  HistoryView.swift
//  Cherry Browser
//

import SwiftUI

/// The cuts through history the rail offers.
///
/// These are ranges rather than a list of every day, because the point of the
/// rail is to get you near the thing in one click. "I saw it last week" is a
/// thought people have; "I saw it on the 14th" is not.
///
/// `frequent` is here because it answers the one question the old screen threw
/// away: a page visited forty times and a page visited once looked identical,
/// so the sites you actually live on were buried in the sites you glanced at.
enum HistoryScopeKind: String, CaseIterable, Identifiable {
    case all
    case today
    case yesterday
    case lastSevenDays
    case lastThirtyDays
    case frequent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All History"
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .lastSevenDays: "Last 7 Days"
        case .lastThirtyDays: "Last 30 Days"
        case .frequent: "Frequently Visited"
        }
    }

    var icon: String {
        switch self {
        case .all: "clock.arrow.circlepath"
        case .today: "sun.max"
        case .yesterday: "moon"
        case .lastSevenDays: "calendar"
        case .lastThirtyDays: "calendar.badge.clock"
        case .frequent: "flame"
        }
    }

    /// A page is "frequently visited" at five visits. Chosen so the scope stays
    /// a shortlist on a real history rather than a second copy of All.
    static let frequentVisitThreshold = 5

    func contains(_ item: HistoryItem, now: Date, calendar: Calendar) -> Bool {
        switch self {
        case .all:
            return true
        case .today:
            // Deliberately `now`-relative rather than `isDateInToday`, which
            // silently reads the wall clock and would make the injected `now`
            // a lie in every scope but this comment.
            return calendar.isDate(item.visitDate, inSameDayAs: now)
        case .yesterday:
            let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
            return calendar.isDate(item.visitDate, inSameDayAs: yesterday)
        case .lastSevenDays:
            return item.visitDate >= calendar.date(byAdding: .day, value: -7, to: now) ?? now
        case .lastThirtyDays:
            return item.visitDate >= calendar.date(byAdding: .day, value: -30, to: now) ?? now
        case .frequent:
            return item.visitCount >= Self.frequentVisitThreshold
        }
    }
}

/// Pure, so the scopes and the day grouping can be tested without a window.
enum HistoryLibrary {

    static func items(
        _ items: [HistoryItem],
        in scope: HistoryScopeKind,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [HistoryItem] {
        items.filter { scope.contains($0, now: now, calendar: calendar) }
    }

    static func scopes(
        for items: [HistoryItem],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [LibraryScope] {
        HistoryScopeKind.allCases.map { kind in
            LibraryScope(
                id: kind.id,
                title: kind.title,
                icon: kind.icon,
                count: items.count { kind.contains($0, now: now, calendar: calendar) }
            )
        }
    }

    /// Day headings, newest first. `Frequently Visited` is ordered by how often
    /// rather than by when, because that is what you came to that scope for.
    static func sections(
        _ items: [HistoryItem],
        scope: HistoryScopeKind,
        searchQuery: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [LibrarySection<HistoryItem>] {
        if !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            return items.isEmpty ? [] : [
                LibrarySection(id: "matches", title: "Matches", items: items)
            ]
        }

        if scope == .frequent {
            let sorted = items.sorted { $0.visitCount > $1.visitCount }
            return sorted.isEmpty ? [] : [
                LibrarySection(id: "frequent", title: "Most visited", items: sorted)
            ]
        }

        var order: [String] = []
        var buckets: [String: [HistoryItem]] = [:]
        for item in items.sorted(by: { $0.visitDate > $1.visitDate }) {
            let key = dayHeading(for: item.visitDate, now: now, calendar: calendar)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(item)
        }
        return order.map { LibrarySection(id: $0, title: $0, items: buckets[$0] ?? []) }
    }

    static func dayHeading(for date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        if calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }

        let formatter = DateFormatter()
        // The formatter follows the calendar it was handed, so a heading is
        // never computed in one time zone and rendered in another.
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
            formatter.dateFormat = "EEEE"
        } else if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            formatter.dateFormat = "EEEE, d MMMM"
        } else {
            formatter.dateFormat = "d MMMM yyyy"
        }
        return formatter.string(from: date)
    }

    static func timeText(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }

    /// `nil` for a page seen once, because a column of "×1" is noise. Anything
    /// above one is the row telling you it is a place you keep going back to.
    static func visitText(_ item: HistoryItem) -> String? {
        item.visitCount > 1 ? "×\(item.visitCount)" : nil
    }
}

struct HistoryView: View {
    @Bindable var repository: HistoryRepository
    let onItemClick: (HistoryItem) -> Void
    /// ⌘-click, middle-click and "Open in New Tab" — opens in the background.
    var onOpenInNewTab: ((HistoryItem) -> Void)? = nil
    var presentation: LibraryPresentation = .sidebar
    var onClose: (() -> Void)? = nil

    @State private var searchText: String = ""
    @State private var scopeID: String = HistoryScopeKind.all.id
    @State private var selection: Set<UUID> = []
    @State private var showingClearAlert: Bool = false

    private var scope: HistoryScopeKind {
        HistoryScopeKind(rawValue: scopeID) ?? .all
    }

    private var matchingItems: [HistoryItem] {
        let base = searchText.trimmingCharacters(in: .whitespaces).isEmpty
            ? repository.historyItems
            : repository.searchHistory(query: searchText)
        return HistoryLibrary.items(base, in: scope)
    }

    var body: some View {
        LibraryLayout(
            title: "History",
            searchPrompt: "Search history",
            presentation: presentation,
            scopes: HistoryLibrary.scopes(for: repository.historyItems),
            scopeID: $scopeID,
            searchText: $searchText,
            sections: HistoryLibrary.sections(
                matchingItems, scope: scope, searchQuery: searchText
            ),
            selection: $selection,
            emptyState: LibraryEmptyState(
                icon: "clock",
                headline: "No history yet",
                detail: "Pages you visit are listed here, newest first, until you clear them."
            ),
            noResultsState: LibraryEmptyState(
                icon: "magnifyingglass",
                headline: "No pages match that search",
                detail: "Search matches page titles and addresses. Try a shorter word, or pick a wider range on the left."
            ),
            destructive: LibraryDestructiveAction(
                title: "Clear History",
                icon: "trash",
                isEnabled: !repository.historyItems.isEmpty,
                action: { showingClearAlert = true }
            ),
            onClose: onClose,
            onOpen: open,
            onRemove: { items in items.forEach(repository.deleteHistoryItem) },
            rowMenu: menu,
            row: { item, density in HistoryRow(item: item, density: density) }
        )
        .alert("Clear History", isPresented: $showingClearAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Last Hour", role: .destructive) { clearHistory(hours: 1) }
            Button("Today", role: .destructive) { clearHistory(hours: 24) }
            Button("All Time", role: .destructive) { repository.clearAllHistory() }
        } message: {
            Text("Choose how much history to clear. This cannot be undone.")
        }
    }

    /// One item opens where you are looking. Several open as background tabs,
    /// so a bulk open does not throw away the page you started from.
    private func open(_ items: [HistoryItem]) {
        guard let first = items.first else { return }
        if items.count == 1 || onOpenInNewTab == nil {
            onItemClick(first)
        } else {
            items.forEach { onOpenInNewTab?($0) }
        }
    }

    @CherryMenuBuilder
    private func menu(for item: HistoryItem) -> [CherryMenuItem] {
        CherryMenuItem.action("Open") { onItemClick(item) }
        if let onOpenInNewTab {
            CherryMenuItem.action("Open in New Tab") { onOpenInNewTab(item) }
        }
        CherryMenuItem.separator
        CherryMenuItem.action("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.url.absoluteString, forType: .string)
        }
        CherryMenuItem.separator
        CherryMenuItem.action("Remove from History", destructive: true) {
            repository.deleteHistoryItem(item)
        }
    }

    private func clearHistory(hours: Int) {
        let calendar = Calendar.current
        let startDate = calendar.date(byAdding: .hour, value: -hours, to: Date()) ?? Date()
        repository.deleteHistory(from: startDate, to: Date())
    }
}

/// What a history row encodes: which site (favicon), what the page was called,
/// where it lives, how often you go there, and when you were last there.
///
/// The old row carried the first three. The two it dropped are the two the
/// task needs: "how often" is what separates a site you use from a link you
/// followed once, and "when" was drawn at 2.3:1 in light mode.
struct HistoryRow: View {
    let item: HistoryItem
    let density: LibraryDensity

    private var isFrequent: Bool {
        item.visitCount >= HistoryScopeKind.frequentVisitThreshold
    }

    var body: some View {
        LibraryRow(
            title: item.title.isEmpty ? (item.url.host ?? item.url.absoluteString) : item.title,
            subtitle: item.url.host ?? item.url.absoluteString,
            density: density,
            isEmphasised: isFrequent,
            subtitleWidth: density.showsSecondaryColumns ? 186 : 150
        ) {
            LibraryFavicon(image: item.favicon)
        } meta: {
            // Both of history's columns survive every width: "how often" and
            // "when" are the two questions this screen is opened to answer.
            if density.isColumnar {
                LibraryMeta(
                    text: HistoryLibrary.visitText(item) ?? "",
                    width: 46,
                    weight: isFrequent ? .semibold : .regular
                )
                LibraryMeta(text: HistoryLibrary.timeText(item.visitDate), width: 74)
            } else {
                LibraryMeta(text: HistoryLibrary.timeText(item.visitDate), width: 62)
            }
        } accessory: {}
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var parts = [item.title, item.url.host ?? ""]
        if item.visitCount > 1 { parts.append("visited \(item.visitCount) times") }
        parts.append(HistoryLibrary.timeText(item.visitDate))
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// A site's own icon, or a neutral globe. Never a coloured placeholder: the
/// favicon column is how a row is recognised before it is read, and a
/// stand-in that looks like an icon defeats that.
struct LibraryFavicon: View {
    let image: NSImage?

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "globe")
                .font(.system(size: 11))
                .foregroundStyle(LibraryPalette.supporting)
        }
    }
}
