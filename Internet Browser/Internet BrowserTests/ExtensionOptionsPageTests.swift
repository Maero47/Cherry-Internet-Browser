//
//  ExtensionOptionsPageTests.swift
//  Internet BrowserTests
//
//  An extension's own options page, at the level that actually failed.
//
//  The previous round's test asserted that `webkit-extension` was in
//  `NavigationSchemePolicy.internallyHandled`. That was true, it shipped, and
//  the page still did not load — because whether a web view can serve an
//  extension page was never a question of the scheme. So the test here does
//  what the browser does: it builds a web view the way `WebViewWrapper` builds
//  one for a tab, points it at a real loaded extension's real options page,
//  and waits for the page to actually render.
//
//  ## Nothing here touches the user's extensions directory
//
//  These tests run inside the hosted `Cherry.app`, where
//  `ExtensionManager.shared` installs into `Application Support/com.cherry.browser/Extensions`
//  — the user's real one. Earlier rounds drove `shared` and left enabled copies
//  of uBO Lite behind in it. Every test below uses
//  `ExtensionManager.isolatedForTesting(directory:)` against a temp directory
//  instead, and `testTheIsolatedManagerIsNotPointedAtTheUsersDirectory` pins
//  that.
//

import XCTest
import WebKit
@testable import Cherry

@MainActor
final class ExtensionOptionsPageTests: XCTestCase {

    // MARK: - The failure, reproduced and ended

    /// The one that matters: a tab created for a `webkit-extension://` URL is
    /// configured to SERVE it, not merely allowed to keep it.
    ///
    /// Dies on: building the tab's web view from a plain `WKWebViewConfiguration`
    /// (with or without `webExtensionController` set) instead of the serving
    /// context's `webViewConfiguration` — i.e. exactly the code that shipped.
    /// The load then fails with `NSURLErrorDomain −1008`, which is the error
    /// the user reported.
    func testATabForAnExtensionsOptionsPageActuallyRendersThatPage() async throws {
        let harness = try await InstalledProbeExtension.make(in: self)
        let optionsPageURL = try XCTUnwrap(
            harness.context.optionsPageURL,
            "the probe extension declares an options page; if this is nil the fixture is wrong, not the browser"
        )

        let built = try XCTUnwrap(
            WebViewWrapper.baseConfiguration(
                forTabAt: optionsPageURL,
                isPrivate: false,
                manager: harness.manager
            ),
            "a loaded extension's own options page must be servable"
        )
        XCTAssertEqual(
            built.identity,
            .extensionPage(host: try XCTUnwrap(harness.context.baseURL.host)),
            "the tab must be built as that extension's web view"
        )

        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 480, height: 360), configuration: built.configuration)
        let outcome = await LoadOutcome.of(loading: optionsPageURL, in: webView, test: self)

        switch outcome {
        case let .failed(domain, code, description):
            XCTFail("""
                the options page did not load: \(domain) \(code) \(description)
                This is the reported bug: −1008 is NSURLErrorResourceUnavailable.
                """)
        case .loaded:
            let marker = try await webView.evaluateJavaScript("document.getElementById('probe')?.textContent ?? ''")
            XCTAssertEqual(marker as? String, "PROBE OPTIONS PAGE",
                           "the extension's own page must be what rendered")
        }
    }

    /// The other half of the same WebKit rule, and the reason the fix is a
    /// choice between two kinds of web view rather than "give every tab the
    /// extension configuration": an extension's web view cannot load ordinary
    /// web content. Measured — WebKit drops the navigation silently, with no
    /// error and no `didFail`, so a tab that tried it would just stop.
    ///
    /// Dies on: `ExtensionPageRouting.requiresNewWebView` returning false when
    /// the identities differ (the swap being dropped), because then nothing
    /// would notice this boundary at all.
    func testAnExtensionWebViewCannotServeOrdinaryWebContent() async throws {
        let harness = try await InstalledProbeExtension.make(in: self)
        let optionsPageURL = try XCTUnwrap(harness.context.optionsPageURL)
        let extensionConfiguration = try XCTUnwrap(harness.context.webViewConfiguration)

        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 480, height: 360), configuration: extensionConfiguration)
        _ = await LoadOutcome.of(loading: optionsPageURL, in: webView, test: self)

        let ordinary = try XCTUnwrap(URL(string: "data:text/html,<h1 id='probe'>ORDINARY</h1>"))
        let outcome = await LoadOutcome.of(loading: ordinary, in: webView, test: self, timeout: 5, expectSilence: true)
        XCTAssertEqual(outcome, .failed(domain: "CherryTestHarness", code: -1, description: "no callback"),
                       "an extension web view must not be able to load ordinary content")

        // And Cherry must therefore treat that crossing as needing a new web view.
        XCTAssertTrue(
            ExtensionPageRouting.requiresNewWebView(
                current: .extensionPage(host: try XCTUnwrap(harness.context.baseURL.host)),
                target: .ordinary
            ),
            "leaving an extension page has to go to a different web view"
        )
    }

    /// Overcorrection guard: ordinary tabs must still be ordinary tabs.
    ///
    /// Dies on: handing every tab the extension configuration, or returning
    /// `nil` (unservable) for ordinary URLs.
    func testAnOrdinaryTabStillGetsAnOrdinaryWebViewThatLoadsAPage() async throws {
        let harness = try await InstalledProbeExtension.make(in: self)

        let built = try XCTUnwrap(
            WebViewWrapper.baseConfiguration(
                forTabAt: URL(string: "https://example.com"),
                isPrivate: false,
                manager: harness.manager
            )
        )
        XCTAssertEqual(built.identity, .ordinary)
        XCTAssertTrue(built.configuration.webExtensionController === harness.manager.controller,
                      "an ordinary tab still hosts content scripts, so it keeps the controller")

        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 480, height: 360), configuration: built.configuration)
        let ordinary = try XCTUnwrap(URL(string: "data:text/html,<h1 id='probe'>ORDINARY PAGE</h1>"))
        let outcome = await LoadOutcome.of(loading: ordinary, in: webView, test: self)
        XCTAssertEqual(outcome, .loaded, "an ordinary tab must still load ordinary content")
    }

    // MARK: - Pages nothing can serve

    /// A `webkit-extension://` URL from an extension that is gone (removed,
    /// disabled, or restored from an older session) has no web view that could
    /// show it. Cherry must say so rather than open a tab that is guaranteed
    /// to fail.
    ///
    /// Dies on: `ExtensionPageRouting.servingIdentity` returning `.ordinary`
    /// instead of `nil` for an unowned extension URL.
    func testAnExtensionPageNothingServesIsNotConfigurable() async throws {
        let harness = try await InstalledProbeExtension.make(in: self)
        let orphan = try XCTUnwrap(URL(string: "webkit-extension://9af7eb6d-1234-4000-8000-007d29e738ce/options/index.html"))

        XCTAssertNil(
            WebViewWrapper.baseConfiguration(forTabAt: orphan, isPrivate: false, manager: harness.manager),
            "no configuration can load a page belonging to no loaded extension"
        )
    }

    /// Extensions never run in private tabs, so an extension page in one is
    /// unservable rather than quietly served by the wrong kind of web view.
    ///
    /// Dies on: dropping the `isPrivate` branch in `baseConfiguration`.
    func testAnExtensionPageIsUnservableInAPrivateTab() async throws {
        let harness = try await InstalledProbeExtension.make(in: self)
        let optionsPageURL = try XCTUnwrap(harness.context.optionsPageURL)

        XCTAssertNil(
            WebViewWrapper.baseConfiguration(forTabAt: optionsPageURL, isPrivate: true, manager: harness.manager),
            "a private tab has no extension controller, so it can never serve an extension page"
        )
    }

    /// The bare −1008 the user was shown must never be rendered as a network
    /// failure of a host called `9af7eb6d-…`.
    ///
    /// Dies on: removing the `NSURLErrorResourceUnavailable` branch in
    /// `NavigationFailure.make(from:requestedURL:)`.
    func testABare1008OnAnExtensionURLIsNotReportedAsASiteThatDidNotLoad() throws {
        let url = try XCTUnwrap(URL(string: "webkit-extension://9af7eb6d-1234-4000-8000-007d29e738ce/options/index.html"))
        let error = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorResourceUnavailable,
            userInfo: [NSURLErrorFailingURLErrorKey: url]
        )

        let failure = try XCTUnwrap(NavigationFailure.make(from: error, requestedURL: url))
        XCTAssertEqual(failure.family, .extensionPageUnavailable)
        XCTAssertFalse(failure.title.contains("9af7eb6d"),
                       "the browser's own internal host is not a site name to show the user")
        XCTAssertEqual(failure.title, "That extension is no longer installed")
        XCTAssertNotNil(failure.nextStep, "there is a real next step here, so it must be offered")
    }

    /// An ordinary −1008 (a genuinely unavailable resource on the web) keeps
    /// its honest fallback rendering.
    ///
    /// Dies on: mapping every −1008 to the extension family.
    func testABare1008OnAWebURLIsStillTheHonestFallback() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/gone"))
        let error = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorResourceUnavailable,
            userInfo: [NSURLErrorFailingURLErrorKey: url]
        )
        let failure = try XCTUnwrap(NavigationFailure.make(from: error, requestedURL: url))
        XCTAssertEqual(failure.family, .unrecognised)
    }

    // MARK: - The isolation these tests depend on

    /// Pins that the test-only manager really is isolated. If this ever fails,
    /// every install below is landing in the user's real extensions directory.
    func testTheIsolatedManagerIsNotPointedAtTheUsersDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cherry-isolation-\(UUID().uuidString)", isDirectory: true)
        let manager = ExtensionManager.isolatedForTesting(directory: directory)

        XCTAssertEqual(manager.managedDirectory, directory)
        XCTAssertNotEqual(manager.managedDirectory, ExtensionManager.extensionsDirectory)
        XCTAssertFalse(
            manager.managedDirectory.path.hasPrefix(ExtensionManager.extensionsDirectory.path),
            "an isolated manager must not write anywhere inside the user's extensions directory"
        )
    }
}

// MARK: - Harness

/// One real extension, really loaded, in a manager that owns its own temp
/// directory and a non-persistent controller.
@MainActor
struct InstalledProbeExtension {
    let manager: ExtensionManager
    let context: WKWebExtensionContext

    static func make(in test: XCTestCase, manifest: String? = nil) async throws -> InstalledProbeExtension {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cherry-ext-managed-\(UUID().uuidString)", isDirectory: true)
        let manager = ExtensionManager.isolatedForTesting(directory: directory)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let package = try ProbeExtensionPackage.write(manifest: manifest, in: test)
        let loaded = try await manager.loadExtension(from: package)
        return InstalledProbeExtension(manager: manager, context: loaded.context)
    }
}

/// A minimal but REAL unpacked WebExtension with an options page.
enum ProbeExtensionPackage {

    static let defaultManifest = """
        {
          "manifest_version": 3,
          "name": "Cherry Options Probe",
          "version": "1.0",
          "browser_specific_settings": { "gecko": { "id": "options-probe@cherry.test" } },
          "options_ui": { "page": "options/index.html", "open_in_tab": true }
        }
        """

    static func write(manifest: String? = nil, in test: XCTestCase) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cherry-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("options", isDirectory: true),
            withIntermediateDirectories: true
        )
        try (manifest ?? defaultManifest)
            .write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "<html><body><h1 id=\"probe\">PROBE OPTIONS PAGE</h1></body></html>"
            .write(to: directory.appendingPathComponent("options/index.html"), atomically: true, encoding: .utf8)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}

/// What a real load did.
enum LoadOutcome: Equatable {
    case loaded
    case failed(domain: String, code: Int, description: String)

    /// Loads `url` and waits. `expectSilence` covers the case WebKit answers
    /// with nothing at all — no `didFinish`, no `didFail` — which is how it
    /// refuses a non-extension URL in an extension web view; that is reported
    /// as a distinct harness failure rather than a hang.
    @MainActor
    static func of(
        loading url: URL,
        in webView: WKWebView,
        test: XCTestCase,
        timeout: TimeInterval = 20,
        expectSilence: Bool = false
    ) async -> LoadOutcome {
        let recorder = Recorder()
        let expectation = test.expectation(description: "load \(url.absoluteString)")
        expectation.assertForOverFulfill = false
        recorder.finished = expectation
        webView.navigationDelegate = recorder
        webView.load(URLRequest(url: url))

        let waiter = XCTWaiter()
        let result = await waiter.fulfillment(of: [expectation], timeout: timeout)
        guard result == .completed else {
            XCTAssertTrue(expectSilence, "WebKit answered the load with nothing at all within \(timeout)s")
            return .failed(domain: "CherryTestHarness", code: -1, description: "no callback")
        }
        if let error = recorder.failure as NSError? {
            return .failed(domain: error.domain, code: error.code, description: error.localizedDescription)
        }
        return .loaded
    }

    private final class Recorder: NSObject, WKNavigationDelegate {
        var finished: XCTestExpectation?
        var failure: Error?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            finished?.fulfill()
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            failure = error
            finished?.fulfill()
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            failure = error
            finished?.fulfill()
        }
    }
}
