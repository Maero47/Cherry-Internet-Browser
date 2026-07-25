//
//  SearchSuggestionsTests.swift
//  Internet BrowserTests
//
//  The privacy-critical half of `SearchSuggestService`: which host a keystroke
//  is sent to, and how each engine's payload is read. Both are pure, so they're
//  testable without a network round trip.
//

import XCTest
@testable import Cherry

final class SearchSuggestionsTests: XCTestCase {

    // MARK: - Endpoint selection

    func testGoogleQueriesGoogle() {
        let url = SearchSuggestService.suggestionsRequestURL(for: "swift", engine: .google)
        XCTAssertEqual(url?.host, "suggestqueries.google.com")
        XCTAssertTrue(url?.absoluteString.hasSuffix("q=swift") == true)
    }

    func testDuckDuckGoQueriesDuckDuckGoNotGoogle() {
        let url = SearchSuggestService.suggestionsRequestURL(for: "swift", engine: .duckDuckGo)
        XCTAssertEqual(url?.host, "duckduckgo.com")
    }

    /// The bug this task exists to fix: picking a non-Google engine used to
    /// still send every keystroke to Google.
    func testNoEngineEverFallsBackToGoogle() {
        for engine in SearchEngine.allCases where engine != .google {
            let url = SearchSuggestService.suggestionsRequestURL(for: "private query", engine: engine)
            guard let host = url?.host else { continue }  // nil == history only, fine
            XCTAssertFalse(
                host.contains("google"),
                "\(engine.rawValue) suggestions must not go to Google (got \(host))"
            )
        }
    }

    func testEnginesWithoutAnEndpointMakeNoRequest() {
        for engine in SearchEngine.allCases where engine.suggestionsURL == nil {
            XCTAssertNil(
                SearchSuggestService.suggestionsRequestURL(for: "swift", engine: engine),
                "\(engine.rawValue) has no suggestions endpoint, so no request may be built"
            )
        }
    }

    func testQueryIsPercentEncoded() {
        let url = SearchSuggestService.suggestionsRequestURL(for: "a b&c=d", engine: .google)
        let string = try? XCTUnwrap(url?.absoluteString)
        XCTAssertNotNil(string)
        XCTAssertFalse(string!.hasSuffix("a b&c=d"))
        XCTAssertTrue(string!.contains("%20") || string!.contains("+"))
        XCTAssertTrue(string!.contains("%26"), "the & in the query must not start a new parameter")
    }

    func testEmptyQueryStillProducesAWellFormedURL() {
        let url = SearchSuggestService.suggestionsRequestURL(for: "", engine: .google)
        XCTAssertNotNil(url)
    }

    // MARK: - Payload parsing

    func testParsesOpenSearchArray() {
        // Google's `client=firefox` shape.
        let json = #"["swi", ["swift", "swiftui", "swift package manager"], [], {}]"#
        let results = SearchSuggestService.parseSuggestions(from: Data(json.utf8))
        XCTAssertEqual(results, ["swift", "swiftui", "swift package manager"])
    }

    func testParsesDuckDuckGoPhraseObjects() {
        let json = #"[{"phrase":"swift"},{"phrase":"swiftui"}]"#
        let results = SearchSuggestService.parseSuggestions(from: Data(json.utf8))
        XCTAssertEqual(results, ["swift", "swiftui"])
    }

    func testUnknownPayloadYieldsNoSuggestionsInsteadOfCrashing() {
        for payload in [#"{"suggestions": ["a"]}"#, "not json at all", "[]", #"["query"]"#] {
            XCTAssertEqual(
                SearchSuggestService.parseSuggestions(from: Data(payload.utf8)),
                [],
                "payload \(payload) should degrade to no suggestions"
            )
        }
    }

    func testSkipsPhraseObjectsMissingTheirPhrase() {
        let json = #"[{"phrase":"swift"},{"nope":"x"},{"phrase":"swiftui"}]"#
        let results = SearchSuggestService.parseSuggestions(from: Data(json.utf8))
        XCTAssertEqual(results, ["swift", "swiftui"])
    }
}
