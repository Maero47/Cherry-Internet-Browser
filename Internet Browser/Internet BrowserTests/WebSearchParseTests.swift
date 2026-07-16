//
//  WebSearchParseTests.swift
//  Internet BrowserTests
//
//  Unit tests for the PURE half of `WebSearchService`: the anchor-list →
//  results parsing (redirect decode, ad filtering, de-dupe, cap). The
//  webview/network half deliberately has no headless test — it drives a
//  live WKWebView against DuckDuckGo.
//

import XCTest
@testable import Cherry

final class WebSearchParseTests: XCTestCase {

    // A realistic slice of what the extraction JS returns for a DDG HTML
    // SERP: absolutized redirect links for organic results, a y.js ad, and
    // assorted internal links.
    private let sampleAnchors: [WebSearchAnchor] = [
        WebSearchAnchor(
            href: "https://duckduckgo.com/y.js?ad_domain=ads.example.com&ad_provider=bingv7aa&u3=https%3A%2F%2Fwww.bing.com%2Faclick",
            text: "Sponsored — Buy Widgets Online",
            isAd: true
        ),
        WebSearchAnchor(
            href: "https://duckduckgo.com/l/?uddg=https%3A%2F%2Fen.wikipedia.org%2Fwiki%2FWidget&rut=abc123",
            text: "Widget - Wikipedia"
        ),
        WebSearchAnchor(
            href: "https://duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.example.com%2Fwidgets%2Fguide&rut=def456",
            text: "The Complete Widget Guide"
        ),
        WebSearchAnchor(href: "https://duckduckgo.com/html/?q=widgets&s=30", text: "Next"),
    ]

    func testParsesOrganicResultsAndDecodesRedirects() {
        let results = WebSearchService.parseResults(from: sampleAnchors)
        XCTAssertEqual(results, [
            WebSearchResult(url: URL(string: "https://en.wikipedia.org/wiki/Widget")!, title: "Widget - Wikipedia"),
            WebSearchResult(url: URL(string: "https://www.example.com/widgets/guide")!, title: "The Complete Widget Guide"),
        ])
    }

    func testDropsDOMTaggedAds() {
        let anchors = [
            WebSearchAnchor(href: "https://real-result.example.com/page", text: "Looks organic but sat in an ad container", isAd: true),
            WebSearchAnchor(href: "https://organic.example.com/", text: "Organic"),
        ]
        let results = WebSearchService.parseResults(from: anchors)
        XCTAssertEqual(results.map(\.title), ["Organic"])
    }

    /// Ad clicks route through duckduckgo.com/y.js — even without the DOM
    /// tag, no non-/l/ DDG link may survive as a result.
    func testDropsYJSAdLinksEvenWithoutDOMTag() {
        let anchors = [
            WebSearchAnchor(href: "https://duckduckgo.com/y.js?ad_provider=bingv7aa&u3=https%3A%2F%2Fbing.com%2Faclick", text: "Sneaky ad"),
        ]
        XCTAssertEqual(WebSearchService.parseResults(from: anchors), [])
    }

    func testDropsOtherInternalDuckDuckGoLinks() {
        let anchors = [
            WebSearchAnchor(href: "https://duckduckgo.com/html/?q=widgets&s=30", text: "Next"),
            WebSearchAnchor(href: "https://duckduckgo.com/feedback", text: "Feedback"),
            // A redirect whose decoded target is STILL DuckDuckGo must not
            // slip through as an "external" result either.
            WebSearchAnchor(href: "https://duckduckgo.com/l/?uddg=https%3A%2F%2Fduckduckgo.com%2Fabout", text: "About"),
        ]
        XCTAssertEqual(WebSearchService.parseResults(from: anchors), [])
    }

    func testDropsNonHTTPSchemes() {
        let anchors = [
            WebSearchAnchor(href: "javascript:void(0)", text: "Click me"),
            WebSearchAnchor(href: "mailto:someone@example.com", text: "Mail"),
            WebSearchAnchor(href: "ftp://files.example.com/thing", text: "FTP"),
            WebSearchAnchor(href: "", text: "Empty"),
        ]
        XCTAssertEqual(WebSearchService.parseResults(from: anchors), [])
    }

    func testAcceptsSchemeRelativeAndSiteRelativeRedirectHrefs() {
        let anchors = [
            WebSearchAnchor(href: "//duckduckgo.com/l/?uddg=https%3A%2F%2Fa.example.com%2F", text: "Scheme-relative"),
            WebSearchAnchor(href: "/l/?uddg=https%3A%2F%2Fb.example.com%2F", text: "Site-relative"),
        ]
        let results = WebSearchService.parseResults(from: anchors)
        XCTAssertEqual(results.map(\.url.absoluteString), ["https://a.example.com/", "https://b.example.com/"])
    }

    /// The same target linked twice (title link + snippet link under the
    /// href fallback, or slash/fragment variants) must collapse to ONE
    /// result, keeping the first anchor's text — the title.
    func testDeduplicatesByTargetURL() {
        let anchors = [
            WebSearchAnchor(href: "https://duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fpage%2F", text: "Title Link"),
            WebSearchAnchor(href: "https://duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fpage", text: "Snippet text for the same page"),
            WebSearchAnchor(href: "https://example.com/page#section", text: "Fragment variant"),
        ]
        let results = WebSearchService.parseResults(from: anchors)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.title, "Title Link")
    }

    func testCapsAtMaxResults() {
        let anchors = (1...9).map { index in
            WebSearchAnchor(href: "https://site\(index).example.com/", text: "Result \(index)")
        }
        let results = WebSearchService.parseResults(from: anchors)
        XCTAssertEqual(results.count, WebSearchService.maxResults)
        XCTAssertEqual(results.map(\.title), ["Result 1", "Result 2", "Result 3", "Result 4", "Result 5"])
    }

    func testCustomCapIsRespected() {
        let anchors = (1...4).map { index in
            WebSearchAnchor(href: "https://site\(index).example.com/", text: "Result \(index)")
        }
        XCTAssertEqual(WebSearchService.parseResults(from: anchors, maxResults: 2).count, 2)
    }

    func testEmptyInputYieldsEmptyResults() {
        XCTAssertEqual(WebSearchService.parseResults(from: []), [])
    }

    func testEmptyAnchorTextFallsBackToHost() {
        let anchors = [
            WebSearchAnchor(href: "https://duckduckgo.com/l/?uddg=https%3A%2F%2Fdocs.example.org%2Fguide", text: "   "),
        ]
        let results = WebSearchService.parseResults(from: anchors)
        XCTAssertEqual(results.map(\.title), ["docs.example.org"])
    }

    /// The redirect decode must percent-decode exactly once: a target with
    /// its own query string survives intact.
    func testRedirectTargetKeepsItsOwnQueryString() {
        let anchors = [
            WebSearchAnchor(
                href: "https://duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fsearch%3Fq%3Dwidgets%26page%3D2&rut=zz",
                text: "Deep link"
            ),
        ]
        let results = WebSearchService.parseResults(from: anchors)
        XCTAssertEqual(results.first?.url.absoluteString, "https://example.com/search?q=widgets&page=2")
    }
}
