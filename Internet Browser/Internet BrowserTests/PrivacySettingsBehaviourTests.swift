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
