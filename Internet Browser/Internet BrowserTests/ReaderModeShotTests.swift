//
//  ReaderModeShotTests.swift
//  Internet BrowserTests
//
//  Reader mode on an article whose images are relative, before and after.
//
//  The two shots differ in exactly one thing — the `baseURL` handed to
//  `loadHTMLString` — because that is exactly what the defect was. Everything
//  else, the extraction and the document, is the real code.
//
//  The article is served by an in-process `WKURLSchemeHandler` rather than
//  fetched, so the shots need no network and no local web server, and the
//  images are generated here so what appears in the "after" shot is
//  unmistakably the image the relative `src` pointed at.
//
//  Skipped unless `CHERRY_SHOT_DIR` is set:
//
//      TEST_RUNNER_CHERRY_SHOT_DIR=/tmp/shots xcodebuild test \
//        -scheme "Internet Browser" -destination 'platform=macOS' \
//        -only-testing:"Internet BrowserTests/ReaderModeShotTests"
//

import AppKit
import WebKit
import XCTest
@testable import Cherry

@MainActor
final class ReaderModeShotTests: XCTestCase {

    private static let scheme = "cherryarticle"
    private let articleURL = URL(string: "cherryarticle://example.com/blog/2026/the-post")!
    private let size = CGSize(width: 900, height: 700)

    private var outputDirectory: URL!

    override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        let path = environment["CHERRY_SHOT_DIR"] ?? environment["TEST_RUNNER_CHERRY_SHOT_DIR"]
        try XCTSkipIf(path == nil, "screenshot rendering is opt-in")
        outputDirectory = URL(fileURLWithPath: path!)
        try FileManager.default.createDirectory(
            at: outputDirectory, withIntermediateDirectories: true
        )
    }

    func testRenderReaderModeBeforeAndAfter() async throws {
        let content = try await extractedArticle()
        XCTAssertEqual(content.sourceURL, articleURL)

        let document = ReaderModeView.document(for: content, fontSize: 18, useSerif: true)

        // Before: `loadHTMLString(html, baseURL: nil)` — every relative src
        // resolves against nothing, so the images are simply absent.
        try await shoot(document, baseURL: nil, to: "before-reader-relative-images.png")
        // After: the article's own URL.
        try await shoot(document, baseURL: content.sourceURL, to: "after-reader-relative-images.png")
    }

    // MARK: - The article

    /// Two relative forms and one absolute, which is what a real article mixes.
    private var articleHTML: String {
        """
        <!DOCTYPE html><html><head>
        <meta charset="utf-8">
        <meta property="og:title" content="The tide tables of Morecambe Bay">
        <meta name="author" content="A. Writer">
        </head><body>
        <article>
          <p>The bay empties faster than a person can walk. Twice a day the water
          withdraws over a hundred and twenty square miles of sand, and twice a day
          it comes back across the same ground at the speed of a brisk horse. The
          tables below are the only reason anyone crosses it on foot, and they have
          been kept, in one form or another, since the fourteenth century.</p>
          <figure><img src="../images/hero.png" alt="the sands at low water">
          <figcaption>Relative to the article: ../images/hero.png</figcaption></figure>
          <p>What the tables cannot tell you is where the channels have moved to
          since the last crossing. That is a separate profession, and there has been
          someone holding it continuously for five hundred years.</p>
          <figure><img src="/static/figure.png" alt="channel survey">
          <figcaption>Relative to the site root: /static/figure.png</figcaption></figure>
          <p>Everything after this point is ordinary prose, included so the
          extractor's content heuristic has enough text to be confident that this is
          the article and not the furniture around it.</p>
        </article>
        </body></html>
        """
    }

    private func extractedArticle() async throws -> ReaderContent {
        let webView = webView(withHandler: true, javaScript: true)
        let waiter = LoadWaiter()
        webView.navigationDelegate = waiter
        webView.load(URLRequest(url: articleURL))
        try await waiter.wait()
        try await Task.sleep(nanoseconds: 400_000_000)
        let extracted = await ReaderModeExtractor.extract(from: webView)
        return try XCTUnwrap(extracted, "the fixture stopped being extractable")
    }

    // MARK: - Rendering

    private func shoot(_ html: String, baseURL: URL?, to name: String) async throws {
        // Script stays disabled, as it is in the real reader view; the images
        // are the whole point and they need no script.
        let webView = webView(withHandler: true, javaScript: false)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = webView
        window.appearance = NSAppearance(named: .aqua)

        let waiter = LoadWaiter()
        webView.navigationDelegate = waiter
        webView.loadHTMLString(html, baseURL: baseURL)
        try await waiter.wait()
        // Subresources are still in flight when `didFinish` lands.
        try await Task.sleep(nanoseconds: 900_000_000)

        let image = try await webView.takeSnapshot(configuration: nil)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: image.tiffRepresentation ?? Data()))
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: outputDirectory.appendingPathComponent(name))
        print("[reader] wrote \(name) (baseURL: \(baseURL?.absoluteString ?? "nil"))")
    }

    private func webView(withHandler: Bool, javaScript: Bool) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = javaScript
        if withHandler {
            config.setURLSchemeHandler(
                ArticleSchemeHandler(html: articleHTML), forURLScheme: Self.scheme
            )
        }
        return WKWebView(frame: CGRect(origin: .zero, size: size), configuration: config)
    }
}

// MARK: - In-process origin

/// Serves the article and its two images, so the shots need neither the network
/// nor a local server. Any path ending in `.png` gets a generated image with its
/// own filename drawn on it, which is what makes the "after" shot legible as
/// evidence: you can see WHICH relative reference resolved.
private final class ArticleSchemeHandler: NSObject, WKURLSchemeHandler {
    private let html: String

    init(html: String) { self.html = html }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let (data, mimeType) = payload(for: url)
        let response = URLResponse(
            url: url, mimeType: mimeType,
            expectedContentLength: data.count, textEncodingName: "utf-8"
        )
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private func payload(for url: URL) -> (Data, String) {
        if url.pathExtension.lowercased() == "png" {
            return (Self.image(labelled: url.path), "image/png")
        }
        return (Data(html.utf8), "text/html")
    }

    private static func image(labelled label: String) -> Data {
        let size = CGSize(width: 760, height: 220)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedRed: 0.13, green: 0.45, blue: 0.62, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 22, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let text = "loaded \(label)" as NSString
        let bounds = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: (size.width - bounds.width) / 2, y: (size.height - bounds.height) / 2),
            withAttributes: attributes
        )
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return Data() }
        return png
    }
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
