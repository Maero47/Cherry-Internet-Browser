//
//  LibraryScreenTests.swift
//  Internet BrowserTests
//
//  History, Bookmarks and Downloads are one screen with different rows. The
//  parts that decide what a row says and which scope it lands in are pure
//  functions on `HistoryLibrary`, `BookmarkLibrary` and `DownloadLibrary`
//  precisely so they can be checked here rather than by squinting at a window.
//

import AppKit
import XCTest
@testable import Cherry

@MainActor
final class LibraryScreenTests: XCTestCase {

    /// A fixed "now" so "Today" and "Last 7 Days" mean the same thing on every
    /// machine and at every hour of the day.
    private let now = Date(timeIntervalSince1970: 1_770_000_000) // 2026-02-02, 03:20 UTC
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func daysAgo(_ days: Int) -> Date {
        calendar.date(byAdding: .day, value: -days, to: now)!
    }

    // MARK: - History scopes

    private func historyFixture() -> [HistoryItem] {
        [
            HistoryItem(url: URL(string: "https://a.example/1")!, title: "Today once",
                        visitDate: now, visitCount: 1),
            HistoryItem(url: URL(string: "https://a.example/2")!, title: "Today often",
                        visitDate: now, visitCount: 12),
            HistoryItem(url: URL(string: "https://b.example/1")!, title: "Yesterday",
                        visitDate: daysAgo(1), visitCount: 2),
            HistoryItem(url: URL(string: "https://c.example/1")!, title: "Four days ago",
                        visitDate: daysAgo(4), visitCount: 7),
            HistoryItem(url: URL(string: "https://d.example/1")!, title: "Two months ago",
                        visitDate: daysAgo(60), visitCount: 1),
        ]
    }

    func testEachHistoryScopeSelectsTheRightRows() {
        let items = historyFixture()
        func count(_ kind: HistoryScopeKind) -> Int {
            HistoryLibrary.items(items, in: kind, now: now, calendar: calendar).count
        }

        XCTAssertEqual(count(.all), 5)
        XCTAssertEqual(count(.today), 2)
        XCTAssertEqual(count(.yesterday), 1)
        XCTAssertEqual(count(.lastSevenDays), 4, "today, today, yesterday and four days ago")
        XCTAssertEqual(count(.lastThirtyDays), 4, "the two-month-old row falls outside")
        XCTAssertEqual(count(.frequent), 2, "12 and 7 visits clear the threshold, 2 does not")
    }

    /// The rail's counts have to be the counts the list will show, or the rail
    /// is lying about what clicking it will do.
    func testTheRailCountsMatchWhatEachScopeActuallyContains() {
        let items = historyFixture()
        let scopes = HistoryLibrary.scopes(for: items, now: now, calendar: calendar)

        XCTAssertEqual(scopes.count, HistoryScopeKind.allCases.count)
        for scope in scopes {
            let kind = HistoryScopeKind(rawValue: scope.id)!
            XCTAssertEqual(
                scope.count,
                HistoryLibrary.items(items, in: kind, now: now, calendar: calendar).count,
                "\(scope.title) rail count disagrees with its list"
            )
        }
    }

    /// Every scope stays in the rail even at zero, so the rail does not
    /// reshuffle under the pointer as history is cleared.
    func testEmptyScopesStayInTheRail() {
        let scopes = HistoryLibrary.scopes(for: [], now: now, calendar: calendar)
        XCTAssertEqual(scopes.count, HistoryScopeKind.allCases.count)
        XCTAssertTrue(scopes.allSatisfy { $0.count == 0 })
    }

    // MARK: - History grouping

    func testHistorySectionsAreDayHeadingsNewestFirst() {
        let sections = HistoryLibrary.sections(
            historyFixture(), scope: .all, searchQuery: "", now: now, calendar: calendar
        )
        XCTAssertEqual(sections.first?.title, "Today")
        XCTAssertEqual(sections.first?.items.count, 2)
        XCTAssertEqual(sections.dropFirst().first?.title, "Yesterday")
        XCTAssertEqual(
            sections.map(\.title).count, Set(sections.map(\.title)).count,
            "a day must not appear as two headings"
        )
    }

    func testSearchingCollapsesTheDayHeadingsIntoOneMatchesGroup() {
        let sections = HistoryLibrary.sections(
            historyFixture(), scope: .all, searchQuery: "example", now: now, calendar: calendar
        )
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections.first?.title, "Matches")
    }

    func testTheFrequentScopeIsOrderedByVisitsNotByTime() {
        let items = HistoryLibrary.items(historyFixture(), in: .frequent, now: now, calendar: calendar)
        let sections = HistoryLibrary.sections(
            items, scope: .frequent, searchQuery: "", now: now, calendar: calendar
        )
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections.first?.items.map(\.visitCount), [12, 7])
    }

    /// A page seen once says nothing in the visits column; a page seen many
    /// times is the whole reason that column exists.
    func testTheVisitColumnIsBlankForASinglevisit() {
        XCTAssertNil(HistoryLibrary.visitText(
            HistoryItem(url: URL(string: "https://x.example")!, title: "x", visitCount: 1)
        ))
        XCTAssertEqual(HistoryLibrary.visitText(
            HistoryItem(url: URL(string: "https://x.example")!, title: "x", visitCount: 40)
        ), "×40")
    }

    func testEmptySectionsForEmptyInput() {
        XCTAssertTrue(HistoryLibrary.sections([], scope: .all, searchQuery: "", now: now, calendar: calendar).isEmpty)
        XCTAssertTrue(HistoryLibrary.sections([], scope: .all, searchQuery: "q", now: now, calendar: calendar).isEmpty)
    }

    // MARK: - Bookmarks

    private func bookmarkFixture() -> [Bookmark] {
        [
            Bookmark(url: URL(string: "https://a.example")!, title: "Bar one",
                     folder: nil, createdAt: now, isInBookmarkBar: true),
            Bookmark(url: URL(string: "https://b.example")!, title: "Bar two",
                     folder: "Work", createdAt: now, isInBookmarkBar: true),
            Bookmark(url: URL(string: "https://c.example")!, title: "Filed",
                     folder: "Work", createdAt: now),
            Bookmark(url: URL(string: "https://d.example")!, title: "Also filed",
                     folder: "Reading", createdAt: now),
            Bookmark(url: URL(string: "https://e.example")!, title: "Loose",
                     folder: nil, createdAt: now),
        ]
    }

    /// `folder` and `isInBookmarkBar` were in the store and on no screen. The
    /// rail is built out of both.
    func testTheBookmarkRailIsBuiltFromFoldersAndTheBar() {
        let scopes = BookmarkLibrary.scopes(for: bookmarkFixture())
        XCTAssertEqual(
            scopes.map(\.title),
            ["All Bookmarks", "Bookmark Bar", "Reading", "Work", "Unfiled"]
        )
        XCTAssertEqual(scopes.first { $0.id == BookmarkLibrary.barScopeID }?.count, 2)
        XCTAssertEqual(scopes.first { $0.title == "Work" }?.count, 2)
        XCTAssertEqual(scopes.first { $0.id == BookmarkLibrary.unfiledScopeID }?.count, 2)
    }

    /// With no folders at all, "Unfiled" would just be a second name for
    /// "All", so it is not offered.
    func testUnfiledIsNotOfferedWhenThereAreNoFolders() {
        let flat = [
            Bookmark(url: URL(string: "https://a.example")!, title: "a", createdAt: now),
            Bookmark(url: URL(string: "https://b.example")!, title: "b", createdAt: now),
        ]
        let scopes = BookmarkLibrary.scopes(for: flat)
        XCTAssertFalse(scopes.contains { $0.id == BookmarkLibrary.unfiledScopeID })
    }

    func testBookmarkScopesSelectTheRightRows() {
        let items = bookmarkFixture()
        XCTAssertEqual(BookmarkLibrary.items(items, in: BookmarkLibrary.allScopeID).count, 5)
        XCTAssertEqual(BookmarkLibrary.items(items, in: BookmarkLibrary.barScopeID).count, 2)
        XCTAssertEqual(BookmarkLibrary.items(items, in: BookmarkLibrary.unfiledScopeID).count, 2)
        XCTAssertEqual(
            BookmarkLibrary.items(items, in: BookmarkLibrary.folderScopePrefix + "Work")
                .map(\.title).sorted(),
            ["Bar two", "Filed"]
        )
    }

    func testTheBookmarkRailCountsMatchWhatEachScopeContains() {
        let items = bookmarkFixture()
        for scope in BookmarkLibrary.scopes(for: items) {
            XCTAssertEqual(
                scope.count, BookmarkLibrary.items(items, in: scope.id).count,
                "\(scope.title) rail count disagrees with its list"
            )
        }
    }

    /// In "All", the folders are the headings. That is the structure the data
    /// always had and the old flat list never showed.
    func testAllBookmarksIsSectionedByFolder() {
        let sections = BookmarkLibrary.sections(
            bookmarkFixture(), scopeID: BookmarkLibrary.allScopeID, searchQuery: ""
        )
        XCTAssertEqual(sections.map(\.title), ["Unfiled", "Reading", "Work"])
        XCTAssertEqual(sections.map(\.items.count).reduce(0, +), 5, "no bookmark is lost or doubled")
    }

    func testASingleFolderScopeIsOneSection() {
        let scope = BookmarkLibrary.folderScopePrefix + "Work"
        let sections = BookmarkLibrary.sections(
            BookmarkLibrary.items(bookmarkFixture(), in: scope), scopeID: scope, searchQuery: ""
        )
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections.first?.items.count, 2)
    }

    // MARK: - Downloads

    private func download(
        _ name: String,
        from source: String = "https://files.example/x",
        path: String? = nil,
        total: Int64 = 0,
        downloaded: Int64 = 0,
        status: DownloadStatus = .completed,
        error: String? = nil,
        completed: Date? = nil
    ) -> DownloadItem {
        DownloadItem(
            url: URL(string: source)!,
            filename: name,
            filePath: path,
            totalBytes: total,
            downloadedBytes: downloaded,
            startDate: now,
            completionDate: completed ?? (status == .completed ? now : nil),
            status: status,
            errorMessage: error
        )
    }

    private func downloadFixture() -> [DownloadItem] {
        [
            download("small.xpi", total: 79 * 1024),
            download("big.dmg", total: 400 * 1024 * 1024),
            download("running.zip", total: 1_000_000, downloaded: 250_000, status: .downloading),
            download("waiting.pkg", status: .pending),
            download("broken.pdf", status: .failed, error: "The network connection was lost"),
            download("stopped.mp4", status: .cancelled),
        ]
    }

    func testDownloadScopesSeparateRunningFinishedAndBroken() {
        let items = downloadFixture()
        func count(_ id: String) -> Int { DownloadLibrary.items(items, in: id).count }

        XCTAssertEqual(count(DownloadLibrary.allScopeID), 6)
        XCTAssertEqual(count(DownloadLibrary.inProgressScopeID), 2, "downloading and pending")
        XCTAssertEqual(count(DownloadLibrary.completedScopeID), 2)
        XCTAssertEqual(count(DownloadLibrary.unfinishedScopeID), 2, "failed and cancelled")
    }

    func testTheDownloadRailCountsMatchWhatEachScopeContains() {
        let items = downloadFixture()
        for scope in DownloadLibrary.scopes(for: items) {
            XCTAssertEqual(
                scope.count, DownloadLibrary.items(items, in: scope.id).count,
                "\(scope.title) rail count disagrees with its list"
            )
        }
    }

    /// Every download lands in exactly one of the three state scopes, so
    /// nothing can go missing from the rail.
    func testEveryDownloadLandsInExactlyOneStateScope() {
        let items = downloadFixture()
        let stateScopes = [
            DownloadLibrary.inProgressScopeID,
            DownloadLibrary.completedScopeID,
            DownloadLibrary.unfinishedScopeID,
        ]
        for item in items {
            let hits = stateScopes.count { DownloadLibrary.items([item], in: $0).count == 1 }
            XCTAssertEqual(hits, 1, "\(item.filename) is in \(hits) state scopes")
        }
    }

    /// The kind column is the extension, upcased. It is the fact the old
    /// generic `doc` glyph threw away for every file it did not recognise.
    func testTheKindColumnNamesTheFileType() {
        XCTAssertEqual(DownloadLibrary.kindText(download("ublock_origin-1.72.2.xpi")), "XPI")
        XCTAssertEqual(DownloadLibrary.kindText(download("report.PDF")), "PDF")
        XCTAssertEqual(DownloadLibrary.kindText(download("Makefile")), "File")
    }

    /// Where it came from and where it went, in one line, because those are
    /// the two questions a downloads list is asked.
    func testTheOriginLineCarriesBothSourceAndDestination() {
        XCTAssertEqual(
            DownloadLibrary.originText(download(
                "a.zip", from: "https://github.com/x/y", path: "/Users/x/Downloads/a.zip"
            )),
            "github.com · Downloads"
        )
    }

    func testTheOriginLineFallsBackToTheSourceWhenThereIsNoFileYet() {
        XCTAssertEqual(
            DownloadLibrary.originText(download("a.zip", from: "https://github.com/x/y")),
            "github.com"
        )
    }

    /// 4.6 MB must not read like 79 KB. The size column carries the real
    /// magnitude, and the large ones carry weight as well.
    func testSizesAreRealAndLargeOnesAreMarkedAsLarge() {
        let small = download("small.xpi", total: 79 * 1024)
        let large = download("big.dmg", total: 400 * 1024 * 1024)

        XCTAssertNotEqual(
            DownloadLibrary.sizeText(small, downloaded: nil, total: nil),
            DownloadLibrary.sizeText(large, downloaded: nil, total: nil)
        )
        XCTAssertFalse(DownloadLibrary.isLarge(small))
        XCTAssertTrue(DownloadLibrary.isLarge(large))
    }

    func testAnUnknownSizeSaysSoRatherThanShowingZero() {
        XCTAssertEqual(
            DownloadLibrary.sizeText(download("x.bin", status: .pending), downloaded: nil, total: nil),
            "Unknown"
        )
    }

    // MARK: - Download status line

    func testACompletedDownloadHasNoStatusLine() {
        XCTAssertNil(DownloadLibrary.statusText(
            download("a.xpi", total: 1024), downloaded: nil, total: nil, speed: nil, eta: nil
        ))
    }

    func testAFailedDownloadSaysWhatWentWrong() {
        let text = DownloadLibrary.statusText(
            download("a.xpi", status: .failed, error: "The network connection was lost"),
            downloaded: nil, total: nil, speed: nil, eta: nil
        )
        XCTAssertEqual(text, "Failed: The network connection was lost")
    }

    func testAFailedDownloadWithNoReasonStillSaysItFailed() {
        let text = DownloadLibrary.statusText(
            download("a.xpi", status: .failed), downloaded: nil, total: nil, speed: nil, eta: nil
        )
        XCTAssertEqual(text, "Failed to download")
    }

    func testACancelledDownloadSaysItWasStopped() {
        let text = DownloadLibrary.statusText(
            download("a.xpi", status: .cancelled), downloaded: nil, total: nil, speed: nil, eta: nil
        )
        XCTAssertEqual(text, "Cancelled before it finished")
    }

    func testARunningDownloadReportsProgressSpeedAndETA() {
        let text = DownloadLibrary.statusText(
            download("a.zip", total: 1_000_000, downloaded: 250_000, status: .downloading),
            downloaded: 250_000, total: 1_000_000, speed: "1.2 MB/s", eta: "3 seconds left"
        )
        XCTAssertEqual(text, "250 KB of 1 MB · 1.2 MB/s · 3 seconds left")
    }

    /// A download that was in flight when the app quit has no live progress in
    /// the manager. The row must fall back to the bytes the item recorded
    /// rather than drawing an empty bar over a real transfer.
    func testProgressFallsBackToTheItemsOwnBytesWithoutLiveProgress() {
        let text = DownloadLibrary.statusText(
            download("a.zip", total: 1_000_000, downloaded: 250_000, status: .downloading),
            downloaded: nil, total: nil, speed: nil, eta: nil
        )
        XCTAssertEqual(text, "250 KB of 1 MB")
    }

    func testAPendingDownloadSaysItIsWaiting() {
        let text = DownloadLibrary.statusText(
            download("a.zip", status: .pending), downloaded: nil, total: nil, speed: nil, eta: nil
        )
        XCTAssertEqual(text, "Waiting to start")
    }

    // MARK: - Filing

    /// A finished download is filed by when it finished; an unfinished one by
    /// when it started, because that is the date the user remembers.
    func testDownloadsAreFiledByTheDateTheUserWouldRemember() {
        let finished = download("a.zip", completed: daysAgo(3))
        XCTAssertEqual(DownloadLibrary.date(of: finished), daysAgo(3))

        let running = download("b.zip", status: .downloading)
        XCTAssertEqual(DownloadLibrary.date(of: running), now)
    }

    func testInProgressIsOneGroupRatherThanDayHeadings() {
        let sections = DownloadLibrary.sections(
            DownloadLibrary.items(downloadFixture(), in: DownloadLibrary.inProgressScopeID),
            scopeID: DownloadLibrary.inProgressScopeID, searchQuery: "",
            now: now, calendar: calendar
        )
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections.first?.title, "Downloading now")
    }

    // MARK: - Using the window

    /// The single biggest defect these screens had was a 760pt column in a
    /// 1500pt window. Width now buys structure, and the tiers are pinned here
    /// so a future tweak to a column width cannot quietly move a breakpoint.
    func testWidthBuysColumnsRatherThanMargin() {
        // The 300pt browser sidebar, and anything near it: two-line rows.
        XCTAssertEqual(LibraryDensity.forListWidth(300), .compact)
        XCTAssertEqual(LibraryDensity.forListWidth(619), .compact)

        // Enough for columns, not for all of them.
        XCTAssertEqual(LibraryDensity.forListWidth(620), .regular)
        XCTAssertEqual(LibraryDensity.forListWidth(899), .regular)

        // Everything a row knows.
        XCTAssertEqual(LibraryDensity.forListWidth(900), .full)
        XCTAssertEqual(LibraryDensity.forListWidth(1500), .full)
    }

    /// The tiers have to actually differ, or the breakpoints are decoration.
    func testEachDensityTierDrawsSomethingDifferent() {
        XCTAssertTrue(LibraryDensity.full.isColumnar)
        XCTAssertTrue(LibraryDensity.regular.isColumnar)
        XCTAssertFalse(LibraryDensity.compact.isColumnar)

        XCTAssertTrue(LibraryDensity.full.showsSecondaryColumns)
        XCTAssertFalse(LibraryDensity.regular.showsSecondaryColumns)
        XCTAssertFalse(LibraryDensity.compact.showsSecondaryColumns)

        // A two-line row is taller than a one-line row, or it is not two lines.
        XCTAssertGreaterThan(LibraryDensity.compact.rowHeight, LibraryDensity.full.rowHeight)
    }

    // MARK: - Shared vocabulary

    /// All three screens head their groups the same way. If they drift, the
    /// screens stop reading as one thing, which is the failure this redesign
    /// exists to undo.
    func testAllThreeScreensUseTheSameDayHeadings() {
        XCTAssertEqual(HistoryLibrary.dayHeading(for: now, now: now, calendar: calendar), "Today")
        XCTAssertEqual(
            HistoryLibrary.dayHeading(for: daysAgo(1), now: now, calendar: calendar), "Yesterday"
        )
        // Downloads route through the same function rather than a copy of it.
        let yesterdaysDownload = download("a.zip", completed: daysAgo(1))
        let sections = DownloadLibrary.sections(
            [yesterdaysDownload], scopeID: DownloadLibrary.allScopeID, searchQuery: "",
            now: now, calendar: calendar
        )
        XCTAssertEqual(sections.first?.title, "Yesterday")
    }
}
