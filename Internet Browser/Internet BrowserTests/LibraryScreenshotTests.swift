//
//  LibraryScreenshotTests.swift
//  Internet BrowserTests
//
//  Renders the library screens in every state, at two widths, in both
//  appearances, and writes them to disk.
//
//  ## Why this is a test and not a mode in the app
//
//  Several of the states that most need proving cannot be produced in a real
//  profile without destroying something: "no bookmarks yet" means deleting the
//  user's bookmarks, "no history" means clearing their history. A failed
//  download cannot be summoned on demand at all. The alternative to this file
//  is either shipping a fixture mode in the browser or wrecking someone's data
//  to take a picture, and both are worse.
//
//  Nothing here is a mock of the screens. It builds the real `LibraryLayout`
//  with the real row views and drives it through the same pure functions
//  (`HistoryLibrary`, `BookmarkLibrary`, `DownloadLibrary`) the real screens
//  call. Only the data is fixed.
//
//  Skipped unless `CHERRY_SHOT_DIR` is set, so an ordinary test run neither
//  slows down nor writes files:
//
//      CHERRY_SHOT_DIR=/tmp/shots xcodebuild test \
//        -scheme "Internet Browser" -destination 'platform=macOS' \
//        -only-testing:"Internet BrowserTests/LibraryScreenshotTests"
//

import AppKit
import SwiftUI
import XCTest
@testable import Cherry

@MainActor
final class LibraryScreenshotTests: XCTestCase {

    /// The two windows the deliverable asks for: one wide enough for the scope
    /// rail, one narrow enough to prove the layout folds instead of clipping.
    private let wide = CGSize(width: 1400, height: 860)
    /// Wide enough for the rail, not wide enough for every column: the middle
    /// tier, where the secondary columns give their width back to the title.
    private let medium = CGSize(width: 900, height: 860)
    private let narrow = CGSize(width: 560, height: 860)
    /// The 300pt browser sidebar, which is the same components at their
    /// tightest.
    private let sidebar = CGSize(width: 300, height: 860)

    private var outputDirectory: URL!

    override func setUpWithError() throws {
        // `xcodebuild` forwards `TEST_RUNNER_`-prefixed variables into the test
        // host and nothing else, so that prefix is the one that works from the
        // command line.
        let environment = ProcessInfo.processInfo.environment
        let path = environment["CHERRY_SHOT_DIR"] ?? environment["TEST_RUNNER_CHERRY_SHOT_DIR"]
        try XCTSkipIf(path == nil, "screenshot rendering is opt-in")

        outputDirectory = URL(fileURLWithPath: path!)
        try FileManager.default.createDirectory(
            at: outputDirectory, withIntermediateDirectories: true
        )
    }

    // MARK: - The gallery

    func testRenderEveryLibraryState() throws {
        for (appearanceLabel, appearanceName) in [("light", NSAppearance.Name.aqua),
                                                  ("dark", NSAppearance.Name.darkAqua)] {
            // Populated, wide: the rail, the columns, the grouping.
            shoot("history-populated-wide", appearanceLabel, appearanceName, wide) {
                HistoryGallery(items: LibraryFixtures.history, selection: [])
            }
            shoot("bookmarks-populated-wide", appearanceLabel, appearanceName, wide) {
                BookmarkGallery(items: LibraryFixtures.bookmarks, selection: [])
            }
            shoot("downloads-populated-wide", appearanceLabel, appearanceName, wide) {
                DownloadGallery(items: LibraryFixtures.downloads, selection: [])
            }

            // The middle tier: rail, but the secondary columns have gone.
            shoot("history-medium", appearanceLabel, appearanceName, medium) {
                HistoryGallery(items: LibraryFixtures.history, selection: [])
            }
            shoot("bookmarks-medium", appearanceLabel, appearanceName, medium) {
                BookmarkGallery(items: LibraryFixtures.bookmarks, selection: [])
            }
            shoot("downloads-medium", appearanceLabel, appearanceName, medium) {
                DownloadGallery(items: LibraryFixtures.downloads, selection: [])
            }

            // The same screens at a width that cannot hold a rail.
            shoot("history-narrow", appearanceLabel, appearanceName, narrow) {
                HistoryGallery(items: LibraryFixtures.history, selection: [])
            }
            shoot("bookmarks-narrow", appearanceLabel, appearanceName, narrow) {
                BookmarkGallery(items: LibraryFixtures.bookmarks, selection: [])
            }
            shoot("downloads-narrow", appearanceLabel, appearanceName, narrow) {
                DownloadGallery(items: LibraryFixtures.downloads, selection: [])
            }

            // The 300pt sidebar: same language, two-line rows, close button.
            shoot("history-sidebar", appearanceLabel, appearanceName, sidebar) {
                HistoryGallery(
                    items: LibraryFixtures.history, selection: [], presentation: .sidebar
                )
            }
            shoot("downloads-sidebar", appearanceLabel, appearanceName, sidebar) {
                DownloadGallery(
                    items: LibraryFixtures.downloads, selection: [], presentation: .sidebar
                )
            }

            // Multi-selection with the bulk-action bar showing.
            shoot("history-multiselection", appearanceLabel, appearanceName, wide) {
                HistoryGallery(
                    items: LibraryFixtures.history,
                    selection: Set(LibraryFixtures.history.prefix(3).map(\.id))
                )
            }
            shoot("downloads-multiselection", appearanceLabel, appearanceName, wide) {
                DownloadGallery(
                    items: LibraryFixtures.downloads,
                    selection: Set(LibraryFixtures.downloads.prefix(3).map(\.id))
                )
            }

            // Empty: never downloaded, never bookmarked, no history.
            shoot("history-empty", appearanceLabel, appearanceName, wide) {
                HistoryGallery(items: [], selection: [])
            }
            shoot("bookmarks-empty", appearanceLabel, appearanceName, wide) {
                BookmarkGallery(items: [], selection: [])
            }
            shoot("downloads-empty", appearanceLabel, appearanceName, wide) {
                DownloadGallery(items: [], selection: [])
            }

            // Searching, with nothing matching.
            shoot("history-no-results", appearanceLabel, appearanceName, wide) {
                HistoryGallery(
                    items: LibraryFixtures.history, selection: [], search: "quarterly"
                )
            }
            shoot("bookmarks-no-results", appearanceLabel, appearanceName, wide) {
                BookmarkGallery(
                    items: LibraryFixtures.bookmarks, selection: [], search: "quarterly"
                )
            }
            shoot("downloads-no-results", appearanceLabel, appearanceName, wide) {
                DownloadGallery(
                    items: LibraryFixtures.downloads, selection: [], search: "quarterly"
                )
            }

            // Downloads in flight, and downloads that did not arrive.
            shoot("downloads-in-progress", appearanceLabel, appearanceName, wide) {
                DownloadGallery(
                    items: LibraryFixtures.downloads, selection: [],
                    scopeID: DownloadLibrary.inProgressScopeID
                )
            }
            shoot("downloads-failed", appearanceLabel, appearanceName, wide) {
                DownloadGallery(
                    items: LibraryFixtures.downloads, selection: [],
                    scopeID: DownloadLibrary.unfinishedScopeID
                )
            }

            // Still reading the list off disk.
            shoot("history-loading", appearanceLabel, appearanceName, wide) {
                HistoryGallery(items: [], selection: [], isLoading: true)
            }

            // A folder scope, which is the structure bookmarks always had and
            // never showed.
            shoot("bookmarks-folder", appearanceLabel, appearanceName, wide) {
                BookmarkGallery(
                    items: LibraryFixtures.bookmarks, selection: [],
                    scopeID: BookmarkLibrary.folderScopePrefix + "Work"
                )
            }
        }
    }

    // MARK: - Rendering

    private func shoot(
        _ name: String,
        _ appearanceLabel: String,
        _ appearanceName: NSAppearance.Name,
        _ size: CGSize,
        @ViewBuilder _ content: () -> some View
    ) {
        let file = outputDirectory.appendingPathComponent("\(name)-\(appearanceLabel).png")
        let hosting = NSHostingView(rootView: content().frame(width: size.width, height: size.height))
        hosting.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: 40, y: 40), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: appearanceName)
        window.contentView = hosting
        // Active application AND key window. Either one missing and AppKit
        // draws `List` selection in the inactive grey rather than the user's
        // accent, which would make every selection shot a picture of the wrong
        // colour.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        // A `List` is NSTableView-backed and populates on a later turn of the
        // run loop, so a capture taken immediately renders an empty table.
        for _ in 0..<6 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            return XCTFail("no bitmap rep for \(name)")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            return XCTFail("no png data for \(name)")
        }
        do {
            try data.write(to: file)
        } catch {
            XCTFail("could not write \(file.path): \(error)")
        }
        window.orderOut(nil)
    }
}

// MARK: - Gallery hosts
//
// Each of these is the real `LibraryLayout` wired to the same pure functions
// the real screen uses, with the repository replaced by a fixed array. The
// bindings are `@State` so the layout behaves exactly as it does in the app.

private struct HistoryGallery: View {
    let items: [HistoryItem]
    @State var selection: Set<UUID>
    var presentation: LibraryPresentation = .page
    @State var search: String = ""
    @State var scopeID: String = HistoryScopeKind.all.id
    var isLoading: Bool = false

    private var matching: [HistoryItem] {
        let base = search.isEmpty
            ? items
            : items.filter {
                $0.title.localizedCaseInsensitiveContains(search)
                    || $0.url.absoluteString.localizedCaseInsensitiveContains(search)
            }
        return HistoryLibrary.items(base, in: HistoryScopeKind(rawValue: scopeID) ?? .all)
    }

    var body: some View {
        LibraryLayout(
            title: "History",
            searchPrompt: "Search history",
            presentation: presentation,
            scopes: HistoryLibrary.scopes(for: items),
            scopeID: $scopeID,
            searchText: $search,
            sections: HistoryLibrary.sections(
                matching, scope: HistoryScopeKind(rawValue: scopeID) ?? .all, searchQuery: search
            ),
            selection: $selection,
            emptyState: LibraryEmptyState(
                icon: "clock",
                headline: "No history yet",
                detail: "Pages you visit are listed here, newest first, until you clear them.",
                isUntouched: true
            ),
            noResultsState: LibraryEmptyState(
                icon: "magnifyingglass",
                headline: "No pages match that search",
                detail: "Search matches page titles and addresses. Try a shorter word, or pick a wider range on the left."
            ),
            isLoading: isLoading,
            loadingLabel: "Reading your history",
            destructive: LibraryDestructiveAction(
                title: "Clear History", icon: "trash", isEnabled: !items.isEmpty, action: {}
            ),
            onClose: presentation == .sidebar ? {} : nil,
            onOpen: { _ in },
            onRemove: { _ in },
            rowMenu: { _ in [] },
            row: { item, density in HistoryRow(item: item, density: density) }
        )
    }
}

private struct BookmarkGallery: View {
    let items: [Bookmark]
    @State var selection: Set<UUID>
    var presentation: LibraryPresentation = .page
    @State var search: String = ""
    @State var scopeID: String = BookmarkLibrary.allScopeID

    private var matching: [Bookmark] {
        let base = search.isEmpty
            ? items
            : items.filter {
                $0.title.localizedCaseInsensitiveContains(search)
                    || $0.url.absoluteString.localizedCaseInsensitiveContains(search)
            }
        return BookmarkLibrary.items(base, in: scopeID)
    }

    var body: some View {
        LibraryLayout(
            title: "Bookmarks",
            searchPrompt: "Search bookmarks",
            presentation: presentation,
            scopes: BookmarkLibrary.scopes(for: items),
            scopeID: $scopeID,
            searchText: $search,
            sections: BookmarkLibrary.sections(matching, scopeID: scopeID, searchQuery: search),
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
                title: "Remove All Bookmarks", icon: "trash", isEnabled: !items.isEmpty, action: {}
            ),
            onClose: presentation == .sidebar ? {} : nil,
            onOpen: { _ in },
            onRemove: { _ in },
            rowMenu: { _ in [] },
            row: { item, density in BookmarkRow(bookmark: item, density: density) }
        )
    }
}

private struct DownloadGallery: View {
    let items: [DownloadItem]
    @State var selection: Set<UUID>
    var presentation: LibraryPresentation = .page
    @State var search: String = ""
    @State var scopeID: String = DownloadLibrary.allScopeID

    private var matching: [DownloadItem] {
        let base = search.isEmpty
            ? items
            : items.filter { $0.filename.localizedCaseInsensitiveContains(search) }
        return DownloadLibrary.items(base, in: scopeID)
    }

    var body: some View {
        LibraryLayout(
            title: "Downloads",
            searchPrompt: "Search downloads",
            presentation: presentation,
            scopes: DownloadLibrary.scopes(for: items),
            scopeID: $scopeID,
            searchText: $search,
            sections: DownloadLibrary.sections(matching, scopeID: scopeID, searchQuery: search),
            selection: $selection,
            emptyState: LibraryEmptyState(
                icon: "arrow.down.circle",
                headline: "Nothing downloaded yet",
                detail: "Files you download are listed here with where they came from and where Cherry put them.",
                isUntouched: true
            ),
            noResultsState: LibraryEmptyState(
                icon: "magnifyingglass",
                headline: "No downloads match that search",
                detail: "Search matches file names. Try a shorter word, or pick a different state on the left."
            ),
            destructive: LibraryDestructiveAction(
                title: "Clear Downloads", icon: "trash", isEnabled: !items.isEmpty, action: {}
            ),
            onClose: presentation == .sidebar ? {} : nil,
            onOpen: { _ in },
            onRemove: { _ in },
            rowMenu: { _ in [] },
            row: { item, density in
                DownloadRow(
                    item: item, density: density,
                    progress: item.isActive
                        ? (downloaded: item.downloadedBytes, total: item.totalBytes)
                        : nil,
                    speedText: item.status == .downloading ? "2.4 MB/s" : nil,
                    etaText: item.status == .downloading ? "12 seconds left" : nil,
                    isUnquarantined: false,
                    onCancel: {}, onRetry: {}
                )
            }
        )
    }
}

// MARK: - Fixtures

private enum LibraryFixtures {

    private static func ago(_ hours: Int) -> Date {
        Calendar.current.date(byAdding: .hour, value: -hours, to: Date()) ?? Date()
    }

    static let history: [HistoryItem] = [
        item("Swift Forums: actor isolation in Swift 6", "https://forums.swift.org/t/actor-isolation", 1, 14),
        item("SwiftUI List selection on macOS", "https://developer.apple.com/documentation/swiftui/list", 2, 3),
        item("Hacker News", "https://news.ycombinator.com", 3, 41),
        item("GitHub: apple/swift-nio", "https://github.com/apple/swift-nio", 4, 6),
        item("WCAG 2.2 contrast minimum", "https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum", 5, 1),
        item("Core Data batch delete performance", "https://developer.apple.com/documentation/coredata", 7, 2),
        item("Google", "https://www.google.com", 9, 87),
        item("Erkek Spor Ayakkabı Modelleri ve Fiyatları", "https://www.superstep.com.tr/erkek", 26, 4),
        item("DuckDuckGo: Privacy, simplified.", "https://duckduckgo.com", 27, 12),
        item("Make your donation now: Wikimedia Foundation", "https://donate.wikimedia.org", 29, 1),
        item("React", "https://react.dev", 30, 5),
        item("Türk Anime TV | Türkçe Altyazılı Anime İzle", "https://www.turkanime.net", 52, 23),
        item("Internet Assigned Numbers Authority", "https://www.iana.org", 74, 1),
    ]

    private static func item(_ title: String, _ url: String, _ hoursAgo: Int, _ visits: Int) -> HistoryItem {
        HistoryItem(
            url: URL(string: url)!, title: title,
            visitDate: ago(hoursAgo), visitCount: visits
        )
    }

    static let bookmarks: [Bookmark] = [
        bookmark("Gmail", "https://accounts.google.com/mail", nil, true, 200),
        bookmark("YouTube", "https://youtube.com", nil, true, 640),
        bookmark("Türk Anime TV | Türkçe Altyazılı Anime İzle", "https://www.turkanime.net", nil, true, 900),
        bookmark("Swift Evolution proposals", "https://github.com/apple/swift-evolution", "Work", false, 120),
        bookmark("Cherry issue tracker", "https://github.com/cherry/browser/issues", "Work", true, 40),
        bookmark("Human Interface Guidelines", "https://developer.apple.com/design/human-interface-guidelines", "Work", false, 300),
        bookmark("Computer Science Past Exam Papers", "https://canvas.bham.ac.uk/papers", "University", false, 1500),
        bookmark("Train YOLO to detect a custom object (online with free GPU)", "https://pysource.com/yolo-custom-object", "Reading", false, 2200),
        bookmark("1 adet yüksek kalite Mini mikro SD SDHC TF Memory Stick MS Pro Duo adaptörü dönüştürücü kartı", "https://tr.aliexpress.com/item/1005001", "Reading", false, 2600),
    ]

    private static func bookmark(
        _ title: String, _ url: String, _ folder: String?, _ onBar: Bool, _ hoursAgo: Int
    ) -> Bookmark {
        Bookmark(
            url: URL(string: url)!, title: title, folder: folder,
            createdAt: ago(hoursAgo), isInBookmarkBar: onBar
        )
    }

    static let downloads: [DownloadItem] = [
        DownloadItem(
            url: URL(string: "https://addons.mozilla.org/firefox/ublock_origin-1.72.2.xpi")!,
            filename: "ublock_origin-1.72.2.xpi",
            filePath: "/Users/you/Downloads/ublock_origin-1.72.2.xpi",
            totalBytes: 4_823_449, downloadedBytes: 4_823_449,
            startDate: ago(3), completionDate: ago(3), status: .completed
        ),
        DownloadItem(
            url: URL(string: "https://cdn.jsdelivr.net/releases/Xcode_26.2.xip")!,
            filename: "Xcode_26.2.xip",
            filePath: "/Users/you/Downloads/Xcode_26.2.xip",
            totalBytes: 8_142_000_000, downloadedBytes: 3_140_000_000,
            startDate: ago(0), status: .downloading
        ),
        DownloadItem(
            url: URL(string: "https://releases.example.org/quarterly-report.pdf")!,
            filename: "annual-accounts-2025.pdf",
            totalBytes: 0, downloadedBytes: 0,
            startDate: ago(0), status: .pending
        ),
        DownloadItem(
            url: URL(string: "https://mirror.example.net/ubuntu-26.04-desktop.iso")!,
            filename: "ubuntu-26.04-desktop.iso",
            totalBytes: 5_400_000_000, downloadedBytes: 1_204_000_000,
            startDate: ago(2), status: .failed,
            errorMessage: "The network connection was lost"
        ),
        DownloadItem(
            url: URL(string: "https://videos.example.com/keynote-2026.mp4")!,
            filename: "keynote-2026.mp4",
            totalBytes: 1_900_000_000, downloadedBytes: 220_000_000,
            startDate: ago(20), status: .cancelled
        ),
        DownloadItem(
            url: URL(string: "https://github.com/apple/swift/archive/main.zip")!,
            filename: "swift-main.zip",
            filePath: "/Users/you/Downloads/swift-main.zip",
            totalBytes: 214_500_000, downloadedBytes: 214_500_000,
            startDate: ago(27), completionDate: ago(27), status: .completed
        ),
        DownloadItem(
            url: URL(string: "https://addons.mozilla.org/firefox/nyan_cat_animated-1.0.xpi")!,
            filename: "nyan_cat_animated-1.0.xpi",
            filePath: "/Users/you/Downloads/nyan_cat_animated-1.0.xpi",
            totalBytes: 100_352, downloadedBytes: 100_352,
            startDate: ago(29), completionDate: ago(29), status: .completed
        ),
        DownloadItem(
            url: URL(string: "https://steamdb.info/steam_database-4.35.xpi")!,
            filename: "steam_database-4.35.xpi",
            filePath: "/Users/you/Downloads/steam_database-4.35.xpi",
            totalBytes: 392_192, downloadedBytes: 392_192,
            startDate: ago(51), completionDate: ago(51), status: .completed
        ),
    ]
}
