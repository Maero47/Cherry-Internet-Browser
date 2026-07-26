//
//  SessionZoomRestoreTests.swift
//  Internet BrowserTests
//
//  Page zoom across process death. `SavedTabEntry.zoomLevel` is Optional so
//  sessions written before zoom was persisted still decode — and that matters
//  more than it looks: `loadSavedTabs` decodes the whole array or returns
//  nothing, so one un-decodable key would silently drop the user's entire
//  restored session.
//

import XCTest
@testable import Cherry

final class SessionZoomRestoreTests: XCTestCase {

    private func roundTrip(_ entries: [SavedTabEntry]) throws -> [SavedTabEntry] {
        let data = try JSONEncoder().encode(entries)
        return try JSONDecoder().decode([SavedTabEntry].self, from: data)
    }

    private func decode(_ json: String) throws -> [SavedTabEntry] {
        try JSONDecoder().decode([SavedTabEntry].self, from: Data(json.utf8))
    }

    // MARK: - Round trip

    func testZoomLevelSurvivesEncodeAndDecode() throws {
        let saved = [
            SavedTabEntry(urlString: "https://swift.org", title: "Swift", groupID: nil, zoomLevel: 1.5),
            SavedTabEntry(urlString: "https://example.com", title: "Example", groupID: nil, zoomLevel: 0.75)
        ]

        let loaded = try roundTrip(saved)

        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(try XCTUnwrap(loaded[0].zoomLevel), 1.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(loaded[1].zoomLevel), 0.75, accuracy: 0.0001)
    }

    /// A tab at 100% writes no key at all, so an un-zoomed session's JSON is
    /// byte-identical to what earlier builds produced.
    func testAnUnzoomedTabWritesNoZoomKey() throws {
        let entry = SavedTabEntry(urlString: "https://swift.org", title: "Swift")
        let data = try JSONEncoder().encode([entry])
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(json.contains("zoomLevel"))
        XCTAssertNil(try roundTrip([entry])[0].zoomLevel)
    }

    // MARK: - Backward compatibility

    /// The mandatory case: a session saved by an earlier build has no
    /// `zoomLevel` key. It must decode, keep its other fields, and read as 100%.
    func testASessionSavedBeforeZoomWasPersistedStillDecodes() throws {
        let legacy = """
        [{"urlString":"https://swift.org","title":"Swift"}]
        """

        let loaded = try decode(legacy)

        XCTAssertEqual(loaded.count, 1, "an old session must not be dropped")
        XCTAssertEqual(loaded[0].urlString, "https://swift.org")
        XCTAssertEqual(loaded[0].title, "Swift")
        XCTAssertNil(loaded[0].zoomLevel)
        XCTAssertNil(loaded[0].groupID)
    }

    /// The other legacy shape: groups were persisted, zoom wasn't.
    func testASessionWithGroupsButNoZoomStillDecodes() throws {
        let id = UUID()
        let legacy = """
        [{"urlString":"https://swift.org","title":"Swift","groupID":"\(id.uuidString)"}]
        """

        let loaded = try decode(legacy)

        XCTAssertEqual(loaded[0].groupID, id)
        XCTAssertNil(loaded[0].zoomLevel)
    }

    /// Mixed entries in one session — some zoomed, some not.
    func testAMixedSessionDecodesEveryEntry() throws {
        let legacy = """
        [{"urlString":"https://a.com","title":"A"},
         {"urlString":"https://b.com","title":"B","zoomLevel":1.25}]
        """

        let loaded = try decode(legacy)

        XCTAssertEqual(loaded.count, 2)
        XCTAssertNil(loaded[0].zoomLevel)
        XCTAssertEqual(try XCTUnwrap(loaded[1].zoomLevel), 1.25, accuracy: 0.0001)
    }

    // MARK: - Restore is defensive about the value

    /// A restored level comes from JSON on disk, so it's untrusted: a corrupt
    /// or hand-edited number must not render a page at 0% or 4000%.
    func testARestoredLevelIsClampedToTheLadder() {
        let min = PageZoom.levels.first!
        let max = PageZoom.levels.last!

        XCTAssertEqual(PageZoom.clamped(9_999), max, accuracy: 0.0001)
        XCTAssertEqual(PageZoom.clamped(0), min, accuracy: 0.0001)
        XCTAssertEqual(PageZoom.clamped(-3), min, accuracy: 0.0001)
        XCTAssertEqual(PageZoom.clamped(1.25), 1.25, accuracy: 0.0001, "a valid level passes through")
    }

    func testClampingRejectsNonFiniteValues() {
        XCTAssertEqual(PageZoom.clamped(.nan), PageZoom.defaultLevel, accuracy: 0.0001)
        XCTAssertEqual(PageZoom.clamped(.infinity), PageZoom.defaultLevel, accuracy: 0.0001)
    }

    /// End to end through the real Tab: the level a tab carries is what a
    /// restored entry would put back on it.
    @MainActor
    func testARestoredEntrysLevelLandsOnTheTab() throws {
        let tab = Tab(url: URL(string: "https://swift.org"))
        let entry = SavedTabEntry(
            urlString: "https://swift.org",
            title: "Swift",
            groupID: nil,
            zoomLevel: 1.5
        )

        if let zoomLevel = entry.zoomLevel {
            tab.zoomLevel = PageZoom.clamped(zoomLevel)
        }

        XCTAssertEqual(tab.zoomLevel, 1.5, accuracy: 0.0001)
        tab.applyZoomLevel()  // no web view yet — must be a safe no-op
        XCTAssertEqual(tab.zoomLevel, 1.5, accuracy: 0.0001)
    }
}
