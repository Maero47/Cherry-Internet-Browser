//
//  ReaderModeBaseURLTests.swift
//  Internet BrowserTests
//
//  Reader mode's base URL, and the containment that had to come with it.
//
//  `ReaderWebView` used to call `loadHTMLString(html, baseURL: nil)`. Extracted
//  articles are full of relative `src` and `href`, and with no base URL those
//  resolve against nothing — so every relative image silently failed to load
//  and every relative link went nowhere. That is the defect.
//
//  It is also, accidentally, what stopped the reader document from reaching
//  anything: with nothing to resolve against, nothing could load. Passing the
//  article's URL fixes the images and removes that accident at the same time,
//  so the tests below come in two halves: the images resolve now (they didn't),
//  and the document still cannot execute or fetch anything it shouldn't.
//
//  These load real `WKWebView`s, because every claim here is a claim about what
//  WebKit does with this markup — asserting on the strings alone would be
//  asserting on the file, not on the behaviour.
//

import WebKit
import XCTest
@testable import Cherry

@MainActor
final class ReaderModeBaseURLTests: XCTestCase {

    private let articleURL = URL(string: "https://example.com/blog/2026/the-post")!

    /// A page in the shape reader mode has to survive: a semantic `<article>`
    /// with relative images and links, plus the script-carrying markup the
    /// extractor is supposed to strip.
    private var articlePage: String {
        """
        <!DOCTYPE html><html><head><title>Ignored</title>
        <meta property="og:title" content="The Post">
        <meta name="author" content="A Writer">
        </head><body>
        <article>
          <p>\(String(repeating: "Body text that is comfortably past the extractor's 200 character floor. ", count: 6))</p>
          <img src="../images/hero.png" alt="hero">
          <img src="/static/figure.png" alt="figure">
          <img src="https://cdn.example.org/absolute.png" alt="absolute">
          <a href="../other-post">a relative link</a>
          <a href="javascript:alert(1)">a script link</a>
          <p onclick="alert(2)" onerror="alert(3)">handlers</p>
          <img src="x" onerror="window.__pwned = true">
          <script>window.__pwned = true;</script>
          <base href="https://attacker.example/">
          <iframe src="https://attacker.example/frame"></iframe>
          <object data="https://attacker.example/o"></object>
          <link rel="stylesheet" href="https://attacker.example/s.css">
          <noscript><img src="https://attacker.example/ns.png"></noscript>
        </article>
        </body></html>
        """
    }

    // MARK: - Harness

    /// A web view with JavaScript ON — used to ASK a loaded document questions.
    /// The reader's own web view runs with script disabled (that is one of the
    /// things under test); this one is the instrument, not the subject.
    private func inspectorWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        return WKWebView(frame: .init(x: 0, y: 0, width: 800, height: 600), configuration: config)
    }

    private func load(
        _ html: String, baseURL: URL?, into webView: WKWebView
    ) async throws {
        let delegate = LoadWaiter()
        webView.navigationDelegate = delegate
        webView.loadHTMLString(html, baseURL: baseURL)
        try await delegate.wait()
        // `didFinish` fires before subresources have necessarily settled.
        try await Task.sleep(nanoseconds: 250_000_000)
    }

    private func extractedArticle() async throws -> ReaderContent {
        let webView = inspectorWebView()
        try await load(articlePage, baseURL: articleURL, into: webView)
        let extracted = await ReaderModeExtractor.extract(from: webView)
        return try XCTUnwrap(extracted, "the fixture stopped being extractable")
    }

    // MARK: - The defect

    func testTheExtractedContentCarriesThePagesURL() async throws {
        let content = try await extractedArticle()
        XCTAssertEqual(content.sourceURL, articleURL)
    }

    /// The bug, stated as a test: with no base URL a relative image resolves to
    /// nothing usable, so it can never load.
    func testWithoutABaseURLRelativeImagesResolveToNothing() async throws {
        let content = try await extractedArticle()
        let document = ReaderModeView.document(for: content, fontSize: 18, useSerif: true)

        let webView = inspectorWebView()
        try await load(document, baseURL: nil, into: webView)

        let sources = try await imageSources(in: webView)
        XCTAssertFalse(
            sources.contains { $0.hasPrefix("https://example.com/blog/images/hero.png") },
            "with baseURL nil the relative image cannot have resolved to the article's host"
        )
    }

    /// The fix: the same document, given the article's URL, resolves both
    /// relative forms — `../` against the article's directory and `/` against
    /// its root — and leaves absolute ones alone.
    func testWithTheArticlesBaseURLRelativeImagesResolveAgainstIt() async throws {
        let content = try await extractedArticle()
        let document = ReaderModeView.document(for: content, fontSize: 18, useSerif: true)

        let webView = inspectorWebView()
        try await load(document, baseURL: content.sourceURL, into: webView)

        let sources = try await imageSources(in: webView)
        XCTAssertTrue(sources.contains("https://example.com/blog/images/hero.png"),
                      "relative ../ did not resolve; got \(sources)")
        XCTAssertTrue(sources.contains("https://example.com/static/figure.png"),
                      "root-relative did not resolve; got \(sources)")
        XCTAssertTrue(sources.contains("https://cdn.example.org/absolute.png"),
                      "an absolute src must be left alone; got \(sources)")
    }

    func testRelativeLinksResolveAgainstTheArticleToo() async throws {
        let content = try await extractedArticle()
        let document = ReaderModeView.document(for: content, fontSize: 18, useSerif: true)

        let webView = inspectorWebView()
        try await load(document, baseURL: content.sourceURL, into: webView)

        let hrefs = try await strings(
            from: "Array.from(document.querySelectorAll('a')).map(function(a){return a.href})",
            in: webView
        )
        XCTAssertTrue(hrefs.contains("https://example.com/blog/other-post"),
                      "the relative link did not resolve; got \(hrefs)")
    }

    // MARK: - What the base URL turned on, and what bounds it

    /// Layer one: the extractor strips script before it ever reaches a
    /// document — `<script>`, inline handlers, and `javascript:` URLs.
    func testTheExtractedMarkupCarriesNoScript() async throws {
        let markup = try await extractedArticle().content.lowercased()
        for forbidden in ["<script", "javascript:", "onclick", "onerror", "onload",
                          "<iframe", "<object", "<embed", "<base", "<link", "<noscript"] {
            XCTAssertFalse(markup.contains(forbidden),
                           "extracted markup still carries \(forbidden)")
        }
    }

    /// Layer two: the document says so itself, so even markup that slipped past
    /// the extractor cannot execute or fetch.
    func testTheReaderDocumentDeclaresARestrictivePolicy() async throws {
        let content = try await extractedArticle()
        let document = ReaderModeView.document(for: content, fontSize: 18, useSerif: true)
        XCTAssertTrue(document.contains("Content-Security-Policy"))
        XCTAssertTrue(document.contains(ReaderModeView.contentSecurityPolicy))
        XCTAssertTrue(ReaderModeView.contentSecurityPolicy.contains("default-src 'none'"))
        XCTAssertTrue(ReaderModeView.contentSecurityPolicy.contains("base-uri 'none'"))
        XCTAssertTrue(ReaderModeView.contentSecurityPolicy.contains("form-action 'none'"))
    }

    /// The policy, proved by loading a document that *does* carry a script and
    /// checking it did not run. This is the layer that does not depend on the
    /// extractor's regexes being exhaustive.
    func testThePolicyStopsScriptTheExtractorMissed() async throws {
        let hostile = ReaderModeView.document(
            for: ReaderContent(
                title: "Hostile",
                byline: nil,
                content: "<script>window.__pwned = true;</script>"
                    + "<img src='data:image/gif;base64,R0lGODlhAQABAAAAACw=' onerror='window.__pwned = true'>",
                sourceURL: articleURL
            ),
            fontSize: 18, useSerif: true
        )

        let webView = inspectorWebView()   // script ENABLED, so only the CSP can stop it
        try await load(hostile, baseURL: articleURL, into: webView)

        let pwned = try await webView.evaluateJavaScript("window.__pwned === true") as? Bool
        XCTAssertEqual(pwned, false, "the CSP did not stop an inline script")
    }

    /// Layer three: the reader's web view runs with script disabled outright,
    /// so none of the above has to be perfect.
    func testTheReaderWebViewRunsWithScriptDisabled() {
        XCTAssertFalse(
            ReaderWebView.makeConfiguration().defaultWebpagePreferences.allowsContentJavaScript
        )
    }

    /// And the reader's data store is ephemeral, so the requests the base URL
    /// enabled cannot leave cookies behind — in a private window or a normal
    /// one, since this view is built without knowing which it came from.
    func testTheReaderWebViewStoresNothing() {
        XCTAssertFalse(ReaderWebView.makeConfiguration().websiteDataStore.isPersistent)
    }

    /// Reader mode passes `pageURL: nil` to `applyContentRuleLists`, and this
    /// is what that choice means: nil is the PROTECTED answer, so reader mode
    /// is always at least as blocked as the page it came from and a per-site
    /// ad-block pause cannot follow the user into it.
    func testReaderModesNilPageURLMeansProtectedRatherThanUnknown() {
        let settings = SettingsManager.shared
        let wasEnabled = settings.adBlockEnabled
        defer { settings.adBlockEnabled = wasEnabled }

        settings.adBlockEnabled = true
        XCTAssertTrue(WebViewWrapper.adBlockActive(for: nil),
                      "nil must mean protected, or reader mode would be a hole")

        settings.adBlockEnabled = false
        XCTAssertFalse(WebViewWrapper.adBlockActive(for: nil),
                       "and it must still respect the global switch")
    }

    /// Following a link leaves reader mode rather than navigating the reader's
    /// own chrome-less, script-less web view to a live site.
    func testALinkClickIsHandedOutRatherThanNavigatedInPlace() {
        var opened: [URL] = []
        let coordinator = ReaderWebView.Coordinator { opened.append($0) }
        let target = URL(string: "https://example.com/blog/other-post")!

        var decision: WKNavigationActionPolicy?
        coordinator.webView(
            WKWebView(),
            decidePolicyFor: LinkActivation(url: target),
            decisionHandler: { decision = $0 }
        )

        XCTAssertEqual(decision, .cancel, "the reader view must not navigate itself")
        XCTAssertEqual(opened, [target])
    }

    /// A non-web scheme is cancelled and dropped rather than handed to the
    /// browser — `mailto:`, `tel:` and anything more exotic an article carries.
    func testANonWebSchemeIsDroppedRatherThanOpened() {
        var opened: [URL] = []
        let coordinator = ReaderWebView.Coordinator { opened.append($0) }

        var decision: WKNavigationActionPolicy?
        coordinator.webView(
            WKWebView(),
            decidePolicyFor: LinkActivation(url: URL(string: "mailto:someone@example.com")!),
            decisionHandler: { decision = $0 }
        )

        XCTAssertEqual(decision, .cancel)
        XCTAssertTrue(opened.isEmpty)
    }

    /// The reader's own `loadHTMLString` must still be allowed through, or the
    /// article would never render at all.
    func testTheReadersOwnLoadIsAllowed() {
        let coordinator = ReaderWebView.Coordinator { _ in }
        var decision: WKNavigationActionPolicy?
        coordinator.webView(
            WKWebView(),
            decidePolicyFor: OwnLoad(url: articleURL),
            decisionHandler: { decision = $0 }
        )
        XCTAssertEqual(decision, .allow)
    }

    // MARK: - Helpers

    private func imageSources(in webView: WKWebView) async throws -> [String] {
        try await strings(
            from: "Array.from(document.images).map(function(i){return i.src})", in: webView
        )
    }

    private func strings(from js: String, in webView: WKWebView) async throws -> [String] {
        let raw = try await webView.evaluateJavaScript(js)
        return (raw as? [String]) ?? []
    }
}

// MARK: - Navigation action doubles

/// A user activating a link.
private final class LinkActivation: WKNavigationAction {
    private let target: URL
    init(url: URL) { self.target = url }
    override var request: URLRequest { URLRequest(url: target) }
    override var navigationType: WKNavigationType { .linkActivated }
}

/// The reader's own `loadHTMLString`, which WebKit reports as `.other`.
private final class OwnLoad: WKNavigationAction {
    private let target: URL
    init(url: URL) { self.target = url }
    override var request: URLRequest { URLRequest(url: target) }
    override var navigationType: WKNavigationType { .other }
}

/// Resumes once a load finishes or fails.
private final class LoadWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var finished = false

    func wait() async throws {
        if finished { return }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    private func resume() {
        finished = true
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { resume() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { resume() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { resume() }
}
