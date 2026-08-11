//
//  ExtensionPageRoutingTests.swift
//  Internet BrowserTests
//
//  The policy that decides which web view can serve which URL, without a live
//  controller. The live half is `ExtensionOptionsPageTests`.
//

import XCTest
@testable import Cherry

final class ExtensionPageRoutingTests: XCTestCase {

    private let servedHost = "9af7eb6d-1234-4000-8000-007d29e738ce"

    private func url(_ string: String) throws -> URL {
        try XCTUnwrap(URL(string: string))
    }

    /// The one loaded extension in these tests serves only its own host.
    private func servingHost(_ url: URL) -> String? {
        url.host == servedHost ? servedHost : nil
    }

    // MARK: - Which kind of web view a URL needs

    /// Dies on: `servingIdentity` returning `.ordinary` for extension URLs —
    /// which is what the browser effectively believed, and why the tab was
    /// built with a configuration that could not serve the page.
    func testAnExtensionPageNeedsThatExtensionsOwnWebView() throws {
        let identity = ExtensionPageRouting.servingIdentity(
            for: try url("webkit-extension://\(servedHost)/options/index.html#information?action=updated"),
            servingHost: servingHost
        )
        XCTAssertEqual(identity, .extensionPage(host: servedHost))
    }

    /// Dies on: treating any non-http scheme as an extension page.
    func testOrdinaryPagesNeedAnOrdinaryWebView() throws {
        for address in ["https://example.com", "http://example.com", "about:blank",
                        "file:///tmp/page.html", "data:text/html,<b>hi</b>"] {
            XCTAssertEqual(
                ExtensionPageRouting.servingIdentity(for: try url(address), servingHost: servingHost),
                .ordinary,
                "\(address) is ordinary web content"
            )
        }
    }

    /// A tab with no URL yet is an ordinary tab, not an unservable one.
    ///
    /// Dies on: returning `nil` for a nil URL, which would make every
    /// brand-new empty tab refuse to build a web view at all.
    func testATabWithNoURLIsOrdinary() {
        XCTAssertEqual(
            ExtensionPageRouting.servingIdentity(for: nil, servingHost: servingHost),
            .ordinary
        )
    }

    /// Dies on: returning `.ordinary` instead of `nil` when no loaded
    /// extension owns the URL — the tab would then be built as an ordinary web
    /// view and fail the load with −1008, which is the reported bug.
    func testAnExtensionPageNothingServesIsUnservable() throws {
        XCTAssertNil(
            ExtensionPageRouting.servingIdentity(
                for: try url("webkit-extension://11111111-2222-3333-4444-555555555555/options/index.html"),
                servingHost: servingHost
            )
        )
    }

    /// Dies on: comparing schemes case-sensitively.
    func testTheSchemeIsMatchedCaseInsensitively() throws {
        XCTAssertTrue(ExtensionPageRouting.isExtensionURL(try url("WEBKIT-EXTENSION://\(servedHost)/x.html")))
        XCTAssertFalse(ExtensionPageRouting.isExtensionURL(try url("https://example.com")))
        XCTAssertFalse(ExtensionPageRouting.isExtensionURL(nil))
    }

    // MARK: - When a web view has to be replaced

    /// Both directions across the boundary need a new web view. WebKit binds
    /// the kind at creation and refuses the crossing either way.
    ///
    /// Dies on: `requiresNewWebView` returning false for differing identities.
    func testCrossingBetweenOrdinaryAndExtensionPagesNeedsANewWebView() {
        XCTAssertTrue(ExtensionPageRouting.requiresNewWebView(
            current: .ordinary, target: .extensionPage(host: servedHost)))
        XCTAssertTrue(ExtensionPageRouting.requiresNewWebView(
            current: .extensionPage(host: servedHost), target: .ordinary))
    }

    /// Two different extensions are two different web views — an extension's
    /// configuration serves only its OWN base URL.
    ///
    /// Dies on: identifying extension web views by scheme alone rather than by
    /// host, which would let one extension's web view try to load another's
    /// pages and fail exactly as before.
    func testOneExtensionsWebViewCannotServeAnothersPages() {
        XCTAssertTrue(ExtensionPageRouting.requiresNewWebView(
            current: .extensionPage(host: servedHost),
            target: .extensionPage(host: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        ))
    }

    /// Dies on: replacing the web view on every navigation, which would throw
    /// away the back/forward list and the page on ordinary browsing.
    func testStayingOnTheSameSideKeepsTheWebView() {
        XCTAssertFalse(ExtensionPageRouting.requiresNewWebView(current: .ordinary, target: .ordinary))
        XCTAssertFalse(ExtensionPageRouting.requiresNewWebView(
            current: .extensionPage(host: servedHost),
            target: .extensionPage(host: servedHost)
        ))
    }

    /// An unservable target is not a swap: there is no web view to swap TO, so
    /// the caller must refuse it instead of opening a fresh tab that fails.
    ///
    /// Dies on: `requiresNewWebView` returning true for a `nil` target, which
    /// would put Cherry in a loop opening tabs that cannot load.
    func testAnUnservableTargetIsNotASwap() {
        XCTAssertFalse(ExtensionPageRouting.requiresNewWebView(current: .ordinary, target: nil))
        XCTAssertFalse(ExtensionPageRouting.requiresNewWebView(
            current: .extensionPage(host: servedHost), target: nil))
    }

    /// The scheme is still the one Cherry renders itself — the previous
    /// round's fix was necessary, just not sufficient.
    func testCherryStillRendersTheExtensionSchemeItself() {
        XCTAssertFalse(NavigationSchemePolicy.opensInAnotherApp(ExtensionPageRouting.scheme))
    }
}
