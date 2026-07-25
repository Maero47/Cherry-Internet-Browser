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
}
