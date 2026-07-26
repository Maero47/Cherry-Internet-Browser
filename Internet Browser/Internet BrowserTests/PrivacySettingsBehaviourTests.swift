//
//  PrivacySettingsBehaviourTests.swift
//  Internet BrowserTests
//
//  The privacy settings whose logic is testable without a web view: which
//  hosts an ad-block pause actually covers, what the Focus Mode blocklist
//  stores, and what the cookie picker compiles.
//

import XCTest
@testable import Cherry

final class PrivacySettingsBehaviourTests: XCTestCase {

    private var savedWhitelist: Set<String> = []

    override func setUp() {
        super.setUp()
        savedWhitelist = SettingsManager.shared.adBlockWhitelistedDomains
        SettingsManager.shared.adBlockWhitelistedDomains = []
    }

    override func tearDown() {
        SettingsManager.shared.adBlockWhitelistedDomains = savedWhitelist
        super.tearDown()
    }

    // MARK: - Ad-block pause scope

    func testPausingOnAMultiLabelSuffixDoesNotWhitelistTheWholeTLD() {
        let settings = SettingsManager.shared
        settings.toggleAdBlockPause(for: URL(string: "https://www.bbc.co.uk/news"))

        // The entry stored is the registrable domain, never `co.uk`.
        XCTAssertEqual(settings.adBlockWhitelistedDomains, ["bbc.co.uk"])

        XCTAssertTrue(settings.isAdBlockPaused(for: URL(string: "https://www.bbc.co.uk/sport")))
        XCTAssertTrue(settings.isAdBlockPaused(for: URL(string: "https://bbc.co.uk/")))
        // Every other .co.uk site keeps its blocking.
        XCTAssertFalse(settings.isAdBlockPaused(for: URL(string: "https://itv.co.uk/")))
        XCTAssertFalse(settings.isAdBlockPaused(for: URL(string: "https://www.gov.uk/")))
    }

    func testPausingCoversSubdomainsOfTheSameSite() {
        let settings = SettingsManager.shared
        settings.toggleAdBlockPause(for: URL(string: "https://news.example.com/x"))
        XCTAssertEqual(settings.adBlockWhitelistedDomains, ["example.com"])
        XCTAssertTrue(settings.isAdBlockPaused(for: URL(string: "https://shop.example.com/")))
        XCTAssertFalse(settings.isAdBlockPaused(for: URL(string: "https://example.com.evil.net/")))
    }

    func testUnpausingRemovesAnyEntryCoveringTheSite() {
        let settings = SettingsManager.shared
        // A too-broad entry as written by an older build.
        settings.adBlockWhitelistedDomains = ["co.uk", "bbc.co.uk"]
        settings.toggleAdBlockPause(for: URL(string: "https://www.bbc.co.uk/news"))
        XCTAssertTrue(settings.adBlockWhitelistedDomains.isEmpty)
    }

    func testPausingOnSharedHostingCoversOnlyThatTenant() {
        let settings = SettingsManager.shared
        settings.toggleAdBlockPause(for: URL(string: "https://attacker.github.io/page"))
        XCTAssertEqual(settings.adBlockWhitelistedDomains, ["attacker.github.io"])
        XCTAssertTrue(settings.isAdBlockPaused(for: URL(string: "https://attacker.github.io/other")))
        // Every other GitHub Pages site keeps its blocking.
        XCTAssertFalse(settings.isAdBlockPaused(for: URL(string: "https://victim.github.io/")))
        XCTAssertFalse(settings.isAdBlockPaused(for: URL(string: "https://github.io/")))
    }

    func testPauseSticksOnSitesTheSuffixHeuristicMisreads() {
        let settings = SettingsManager.shared
        settings.toggleAdBlockPause(for: URL(string: "https://web.de/mail"))
        XCTAssertEqual(settings.adBlockWhitelistedDomains, ["web.de"])
        // The purge must not eat it: it is a real site, not a public suffix.
        XCTAssertFalse(HostNormalizer.isKnownPublicSuffix("web.de"))
        XCTAssertTrue(settings.isAdBlockPaused(for: URL(string: "https://web.de/")))
    }

    func testPauseIgnoresURLsWithoutAHost() {
        let settings = SettingsManager.shared
        settings.toggleAdBlockPause(for: URL(string: "about:blank"))
        XCTAssertTrue(settings.adBlockWhitelistedDomains.isEmpty)
        XCTAssertFalse(settings.isAdBlockPaused(for: nil))
    }

    // MARK: - Focus Mode

    func testFocusModeCleanDomainUsesTheSharedNormalizer() {
        let focus = FocusModeManager.shared
        XCTAssertEqual(focus.cleanDomain("HTTPS://WWW.Reddit.com/r/swift"), "reddit.com")
        XCTAssertEqual(focus.cleanDomain("  news.ycombinator.com  "), "news.ycombinator.com")
        XCTAssertEqual(focus.cleanDomain("https://WIKI.example.com:8080/"), "wiki.example.com")
    }

    // MARK: - Auto-fill origin guard

    /// `evaluateJavaScript` is async IPC and is not pinned to the document
    /// that was checked on the Swift side, so the origin is re-asserted inside
    /// the script, where it runs at the instant the fields are written.
    func testAutoFillScriptRefusesToRunOnAnotherOrigin() {
        let js = PasswordAutoFillScripts.autoFillScript(
            username: "user@example.com",
            password: "hunter2",
            expectedOrigin: "https://accounts.google.com"
        )
        XCTAssertTrue(
            js.contains("location.protocol + '//' + location.hostname !== 'https://accounts.google.com'"),
            js.prefix(400).description
        )
        // The guard must precede any field write.
        let guardIndex = try? XCTUnwrap(js.range(of: "location.hostname")).lowerBound
        let fillIndex = try? XCTUnwrap(js.range(of: "fillField(pwField")).lowerBound
        if let guardIndex, let fillIndex {
            XCTAssertLessThan(guardIndex, fillIndex)
        }
    }

    /// The generator invents a value rather than replaying a stored one, so it
    /// has no origin to pin — and must still work.
    func testAutoFillScriptWithoutAnExpectedOriginHasNoGuard() {
        let js = PasswordAutoFillScripts.autoFillScript(username: "", password: "generated")
        XCTAssertFalse(js.contains("location.hostname"))
    }

    // MARK: - Cookie policy

    @MainActor
    func testCookiePolicyCompilesRealRulesForEachEnforcedLevel() throws {
        XCTAssertNil(CookiePolicyManager.ruleJSON(for: .none))

        for level in [CookieBlockingLevel.thirdParty, .all] {
            let json = try XCTUnwrap(CookiePolicyManager.ruleJSON(for: level))
            let rules = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
            )
            XCTAssertEqual(rules.count, 1)
            let action = try XCTUnwrap(rules[0]["action"] as? [String: Any])
            XCTAssertEqual(action["type"] as? String, "block-cookies")
        }
    }

    @MainActor
    func testThirdPartyPolicyOnlyTargetsThirdPartyLoads() throws {
        let json = try XCTUnwrap(CookiePolicyManager.ruleJSON(for: .thirdParty))
        let rules = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        )
        let trigger = try XCTUnwrap(rules[0]["trigger"] as? [String: Any])
        XCTAssertEqual(trigger["load-type"] as? [String], ["third-party"])

        let allJSON = try XCTUnwrap(CookiePolicyManager.ruleJSON(for: .all))
        let allRules = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(allJSON.utf8)) as? [[String: Any]]
        )
        let allTrigger = try XCTUnwrap(allRules[0]["trigger"] as? [String: Any])
        XCTAssertNil(allTrigger["load-type"])
    }
}
