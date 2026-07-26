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
    private var savedAdBlockEnabled = true

    override func setUp() {
        super.setUp()
        // These tests read the real singleton, which reads the real
        // UserDefaults — so pin every input they depend on rather than
        // inheriting whatever the last run (or the developer) left behind.
        savedWhitelist = SettingsManager.shared.adBlockWhitelistedDomains
        savedAdBlockEnabled = SettingsManager.shared.adBlockEnabled
        SettingsManager.shared.adBlockWhitelistedDomains = []
        SettingsManager.shared.adBlockEnabled = true
    }

    override func tearDown() {
        SettingsManager.shared.adBlockWhitelistedDomains = savedWhitelist
        SettingsManager.shared.adBlockEnabled = savedAdBlockEnabled
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

    /// `sanitizedWhitelist` is exactly what runs at launch, and its result is
    /// written back to disk — so anything it drops is gone for good.
    func testPausesOnRealSitesSurviveARelaunch() {
        let survivors = SettingsManager.sanitizedWhitelist([
            "medium.com", "wordpress.com", "netlify.com", "squarespace.com",
            "zendesk.com", "supabase.co", "railway.app", "statuspage.io",
            "web.de", "in.gr", "bbc.co.uk", "attacker.github.io",
        ])
        XCTAssertEqual(survivors.count, 12, "a pause the user set was deleted: \(survivors)")
        XCTAssertTrue(survivors.contains("medium.com"))
        XCTAssertTrue(survivors.contains("web.de"))
    }

    /// …while the entries the old base-domain bug wrote are still purged.
    func testPublicSuffixEntriesAreStillPurgedAtLaunch() {
        let survivors = SettingsManager.sanitizedWhitelist([
            "co.uk", "com.au", "com", "", "  ", "bbc.co.uk",
        ])
        XCTAssertEqual(survivors, ["bbc.co.uk"])
    }

    // MARK: - One-time migration of pre-fix data

    /// A pre-fix build stored the "last two labels", so pausing on
    /// `attacker.github.io` left `github.io` behind — ad-blocking off across
    /// every GitHub Pages site. The per-launch purge deliberately can't remove
    /// that; the one-time migration can.
    func testMigrationRemovesLegacySuffixEntriesThePurgeKeeps() {
        let stored: Set<String> = [
            "github.io", "vercel.app", "s3.amazonaws.com",
            // Cloud tenancy roots. A pre-fix build's "last two labels" turned a
            // pause on `mybucket.s3.eu-west-1.amazonaws.com` into
            // `amazonaws.com`, which under today's dot-boundary matching
            // disables blocking for EVERY AWS host — wider than it ever was.
            "amazonaws.com", "googleusercontent.com", "windows.net",
            "bbc.co.uk", "news.example.com", "web.de",
        ]
        // The per-launch purge leaves all of these alone…
        XCTAssertEqual(SettingsManager.sanitizedWhitelist(Array(stored)), stored)
        // …and the one-time migration takes exactly the suffixes out.
        XCTAssertEqual(
            SettingsManager.migratedWhitelist(stored),
            ["bbc.co.uk", "news.example.com", "web.de"]
        )
    }

    /// The tenancy roots are suffixes for the migration, but a host *under*
    /// one is a real site the user may have paused deliberately.
    func testMigrationKeepsHostsUnderATenancyRoot() {
        let stored: Set<String> = [
            "mybucket.s3.eu-west-1.amazonaws.com",
            "account.blob.core.windows.net",
            "lh3.googleusercontent.com",
        ]
        XCTAssertEqual(SettingsManager.migratedWhitelist(stored), stored)
    }

    func testMigrationLeavesOrdinaryHostsAlone() {
        let stored: Set<String> = ["attacker.github.io", "bbc.co.uk", "example.com",
                                   "shop.example.co.uk", "192.168.1.10"]
        XCTAssertEqual(SettingsManager.migratedWhitelist(stored), stored)
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

    // MARK: - The blocking decision follows the page, not the tab's history

    /// `adBlockActive(for:)` is the single expression of "does blocking apply
    /// to this page", shared by web-view creation, navigation commit, and the
    /// settings observer — so those three cannot disagree about the same URL.
    ///
    /// The regression it closes: the set was only ever rebuilt at birth and on
    /// settings changes, so a tab that had been on a paused site kept blocking
    /// OFF for every site it navigated to next, while the shield — which
    /// recomputes from the new URL — showed "active".
    func testBlockingDecisionIsPerPageNotPerTab() {
        let settings = SettingsManager.shared
        settings.toggleAdBlockPause(for: URL(string: "https://news.example.com/story"))

        XCTAssertFalse(WebViewWrapper.adBlockActive(for: URL(string: "https://news.example.com/other")))
        // Navigating on to another site in the same tab must be protected again.
        XCTAssertTrue(WebViewWrapper.adBlockActive(for: URL(string: "https://cnn.com/")))
    }

    /// A URL we don't have must never be read as "the user paused this".
    func testMissingURLIsTreatedAsProtected() {
        XCTAssertTrue(WebViewWrapper.adBlockActive(for: nil))
    }

    /// `didCommit` runs on every navigation, so an unchanged rebuild is
    /// skipped by comparing signatures. The skip is only safe if the signature
    /// changes whenever the installed set would differ — this pins the case
    /// that matters: navigating between a paused and a protected site.
    @MainActor
    func testRuleListSignatureDistinguishesPausedFromProtected() {
        let settings = SettingsManager.shared
        settings.toggleAdBlockPause(for: URL(string: "https://news.example.com/story"))

        let paused = WebViewWrapper.contentRuleListSignature(for: URL(string: "https://news.example.com/x"))
        let protected = WebViewWrapper.contentRuleListSignature(for: URL(string: "https://cnn.com/"))
        XCTAssertNotEqual(paused, protected)

        // Same page, nothing changed → identical signature, so the rebuild is
        // skipped rather than paying two IPC round trips per navigation.
        XCTAssertEqual(
            protected,
            WebViewWrapper.contentRuleListSignature(for: URL(string: "https://cnn.com/other"))
        )
    }

    func testGlobalSwitchStillWins() {
        let settings = SettingsManager.shared   // restored by tearDown
        settings.adBlockEnabled = false
        XCTAssertFalse(WebViewWrapper.adBlockActive(for: URL(string: "https://cnn.com/")))
        XCTAssertFalse(WebViewWrapper.adBlockActive(for: nil))
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
