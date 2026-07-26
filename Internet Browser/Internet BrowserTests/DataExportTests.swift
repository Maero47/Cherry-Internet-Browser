//
//  DataExportTests.swift
//  Internet BrowserTests
//
//  Serialization for the Settings ▸ Export Your Data buttons. The Netscape
//  bookmark file is what Chrome/Firefox/Safari read on import, so its escaping
//  and structure are the contract.
//

import XCTest
@testable import Cherry

final class DataExportTests: XCTestCase {

    // MARK: - HTML escaping

    func testEscapesTheCharactersThatWouldBreakTheDocument() {
        XCTAssertEqual(
            BookmarkRepository.escapingHTML(#"Fish & <Chips> "Deluxe""#),
            "Fish &amp; &lt;Chips&gt; &quot;Deluxe&quot;"
        )
    }

    /// `&` has to be replaced before the entities that contain it, or every
    /// escape gets escaped again and the importer shows `&amp;lt;`.
    func testDoesNotDoubleEscape() {
        XCTAssertEqual(BookmarkRepository.escapingHTML("a<b"), "a&lt;b")
        XCTAssertEqual(BookmarkRepository.escapingHTML("&"), "&amp;")
        XCTAssertEqual(BookmarkRepository.escapingHTML("&amp;"), "&amp;amp;")
    }

    func testLeavesOrdinaryTextAlone() {
        let text = "Swift Package Index — 100% ünïcode, emoji 🍒"
        XCTAssertEqual(BookmarkRepository.escapingHTML(text), text)
    }

    // MARK: - Document shape
    //
    // Asserted against whatever the store happens to hold: the structural
    // invariants below have to hold for any content, including none.

    func testHeaderAndTerminatorMatchTheNetscapeFormat() {
        let html = BookmarkRepository.shared.exportToHTML()
        XCTAssertTrue(html.hasPrefix("<!DOCTYPE NETSCAPE-Bookmark-file-1>"))
        XCTAssertTrue(html.contains(#"<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">"#))
        XCTAssertTrue(html.contains("<DL><p>"))
        XCTAssertTrue(html.hasSuffix("</DL><p>\n"))
    }

    /// Every `<DL><p>` opened (root plus one per folder) must be closed, or
    /// Chrome swallows the tail of the file.
    func testEveryListIsClosed() {
        let html = BookmarkRepository.shared.exportToHTML()
        let opens = html.components(separatedBy: "<DL><p>").count - 1
        let closes = html.components(separatedBy: "</DL><p>").count - 1
        XCTAssertEqual(opens, closes, "unbalanced <DL> nesting in the export")
    }

    // MARK: - History

    func testHistoryExportsAsAJSONArrayOfObjects() throws {
        let data = try XCTUnwrap(HistoryRepository.shared.exportToJSON())
        let json = try JSONSerialization.jsonObject(with: data)
        let items = try XCTUnwrap(json as? [[String: Any]])

        for item in items {
            XCTAssertNotNil(item["url"] as? String)
            XCTAssertNotNil(item["title"] as? String)
            XCTAssertNotNil(item["visitDate"] as? String)
            XCTAssertNotNil(item["visitCount"])
        }
    }

    /// `encodeToJSON` is `nonisolated` and takes a snapshot by value so
    /// `DataExportService` can run it off the main actor — a long history froze
    /// the window before the save panel appeared. Encoding a known snapshot
    /// also pins the field names and the ISO-8601 date format, which used to
    /// come from a formatter allocated once PER ROW.
    func testEncodesAKnownSnapshotWithISO8601Dates() throws {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot: [(url: URL, title: String, visitDate: Date, visitCount: Int)] = [
            (URL(string: "https://swift.org")!, "Swift", when, 3),
            (URL(string: "https://example.com/a?b=c")!, "Ünïcode & <tags>", when, 1)
        ]

        let data = try XCTUnwrap(HistoryRepository.encodeToJSON(snapshot))
        let items = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0]["url"] as? String, "https://swift.org")
        XCTAssertEqual(items[0]["title"] as? String, "Swift")
        XCTAssertEqual(items[0]["visitCount"] as? Int, 3)
        // JSON carries text verbatim — no HTML escaping here, unlike the
        // bookmark export.
        XCTAssertEqual(items[1]["title"] as? String, "Ünïcode & <tags>")

        let stamp = try XCTUnwrap(items[0]["visitDate"] as? String)
        XCTAssertEqual(ISO8601DateFormatter().date(from: stamp), when)
        // Every row shares one formatter, so every row shares one format.
        XCTAssertEqual(items[1]["visitDate"] as? String, stamp)
    }

    func testEncodingAnEmptyHistoryYieldsAnEmptyArray() throws {
        let data = try XCTUnwrap(HistoryRepository.encodeToJSON([]))
        let items = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertTrue(items.isEmpty)
    }
}
