//
//  ExtensionShortlistTests.swift
//  Internet BrowserTests
//
//  Invariants over the first-run wizard's verified extension shortlist.
//  The table is Swift, so "it parses" is the compiler's job; these assert
//  everything the wizard is entitled to assume about each entry. They run
//  unconditionally — an entry violating them should fail the suite, because
//  the wizard will render whatever is in this table without re-checking.
//

import XCTest
@testable import Cherry

final class ExtensionShortlistTests: XCTestCase {

    func testIDsAreUniqueAndSlugShaped() {
        let ids = ExtensionShortlist.entries.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate shortlist ids")
        for id in ids {
            XCTAssertFalse(id.isEmpty)
            XCTAssertEqual(id, id.lowercased(), "ids are lowercase slugs: \(id)")
            XCTAssertNil(id.rangeOfCharacter(from: .whitespaces), "no spaces in ids: \(id)")
        }
    }

    func testEveryEntryHasRequiredUserFacingFields() {
        for entry in ExtensionShortlist.entries {
            XCTAssertFalse(entry.displayName.isEmpty, "\(entry.id): empty display name")
            XCTAssertFalse(entry.summary.isEmpty, "\(entry.id): empty summary")
            XCTAssertLessThanOrEqual(entry.summary.count, 120,
                                     "\(entry.id): summary must stay one wizard line")
        }
    }

    func testNothingShipsWithoutAVerifiedVersion() {
        for entry in ExtensionShortlist.entries {
            XCTAssertFalse(entry.verifiedVersion.isEmpty,
                           "\(entry.id): listed without a verified version — it did not run, it does not ship")
        }
    }

    func testSourceURLsAreHTTPSAndDistinct() {
        let urls = ExtensionShortlist.entries.map(\.sourceURL)
        XCTAssertEqual(urls.count, Set(urls).count, "two entries share a download URL")
        for url in urls {
            XCTAssertEqual(url.scheme, "https", "wizard downloads must be https: \(url)")
        }
    }

    func testCaveatsAreRealSentencesNotPlaceholders() {
        for entry in ExtensionShortlist.entries {
            if let caveat = entry.caveat {
                XCTAssertGreaterThanOrEqual(caveat.count, 10,
                                            "\(entry.id): caveat too short to mean anything")
            }
        }
    }
}
