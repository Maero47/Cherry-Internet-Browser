//
//  NavigationSchemePolicyTests.swift
//  Internet BrowserTests
//
//  What Cherry renders itself versus what it hands to macOS. The case that
//  brought this under test: an extension's own page (`webkit-extension://`)
//  was being handed to `NSWorkspace`, so installing uBO Lite — which opens
//  its options page on first run — put a system "There is no application set
//  to open the URL webkit-extension://…" alert in front of the user instead
//  of showing the page.
//

import XCTest
@testable import Cherry

final class NavigationSchemePolicyTests: XCTestCase {

    func testExtensionPagesAreRenderedByCherryNotHandedToMacOS() {
        XCTAssertFalse(NavigationSchemePolicy.opensInAnotherApp("webkit-extension"),
                       "an extension's own page is served by this process; macOS has no app for it")
    }

    func testWebPageSchemesStayInternal() {
        for scheme in ["http", "https", "about", "file", "blob", "data"] {
            XCTAssertFalse(NavigationSchemePolicy.opensInAnotherApp(scheme), "\(scheme) is loaded in a tab")
        }
    }

    func testSchemesBelongingToOtherAppsStillLeave() {
        for scheme in ["mailto", "tel", "facetime", "zoommtg", "slack"] {
            XCTAssertTrue(NavigationSchemePolicy.opensInAnotherApp(scheme), "\(scheme) belongs to another app")
        }
    }

    func testSchemeMatchingIgnoresCase() {
        XCTAssertFalse(NavigationSchemePolicy.opensInAnotherApp("HTTPS"))
        XCTAssertFalse(NavigationSchemePolicy.opensInAnotherApp("WebKit-Extension"))
    }

    func testAMissingSchemeIsNotSentToAnotherApp() {
        // `URL.scheme` is optional; a nil scheme is not another app's URL, and
        // must not become one by default.
        XCTAssertTrue(NavigationSchemePolicy.opensInAnotherApp(nil),
                      "a schemeless main-frame navigation is not something Cherry claims to render")
    }
}
