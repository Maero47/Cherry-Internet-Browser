//
//  AdBlockRuleBuilderTests.swift
//  Internet BrowserTests
//
//  WebKit's `url-filter` is an unanchored regex over the WHOLE URL. The
//  exception rules used to be bare substrings (`onetrust\.com`, `/cdn-cgi/`),
//  so any request whose path or query merely CONTAINED one of those strings
//  fired `ignore-previous-rules` and switched the entire blocklist off for
//  itself. These tests pin the anchoring that closes that door.
//

import XCTest
@testable import Cherry

final class AdBlockRuleBuilderTests: XCTestCase {

    private func trigger(of rule: [String: Any]) -> [String: Any] {
        rule["trigger"] as? [String: Any] ?? [:]
    }

    private func urlFilter(of rule: [String: Any]) -> String {
        trigger(of: rule)["url-filter"] as? String ?? ""
    }

    private func actionType(of rule: [String: Any]) -> String {
        (rule["action"] as? [String: Any])?["type"] as? String ?? ""
    }

    // MARK: - Host patterns

    func testHostPatternIsAnchoredToTheStartOfTheURL() {
        let pattern = AdBlockRuleBuilder.hostPattern(for: "onetrust.com")
        XCTAssertTrue(pattern.hasPrefix("^https?://"), pattern)
        XCTAssertTrue(pattern.hasSuffix("[/:]"), pattern)
        // Dots are escaped, so they can't match an arbitrary character.
        XCTAssertTrue(pattern.contains("onetrust\\.com"), pattern)
    }

    func testHostPatternMatchesTheHostAndItsSubdomains() {
        let pattern = AdBlockRuleBuilder.hostPattern(for: "onetrust.com")
        XCTAssertTrue(AdBlockRuleBuilder.pattern(pattern, matches: "https://onetrust.com/sdk.js"))
        XCTAssertTrue(AdBlockRuleBuilder.pattern(pattern, matches: "https://cdn.onetrust.com/scripttemplates/otSDKStub.js"))
        XCTAssertTrue(AdBlockRuleBuilder.pattern(pattern, matches: "http://onetrust.com:8443/x"))
        XCTAssertTrue(AdBlockRuleBuilder.pattern(pattern, matches: "https://ONETRUST.COM/sdk.js"))
    }

    /// The exploit: a tracker naming an excepted domain in its own URL.
    func testHostPatternIgnoresTheDomainAppearingInAPathOrQuery() {
        let pattern = AdBlockRuleBuilder.hostPattern(for: "onetrust.com")
        XCTAssertFalse(AdBlockRuleBuilder.pattern(
            pattern, matches: "https://tracker.example/px?r=https://onetrust.com/"))
        XCTAssertFalse(AdBlockRuleBuilder.pattern(
            pattern, matches: "https://tracker.example/onetrust.com/beacon.gif"))
        XCTAssertFalse(AdBlockRuleBuilder.pattern(
            pattern, matches: "https://evil.example/#https://cdn.onetrust.com/"))
    }

    func testHostPatternDoesNotMatchALookalikeDomain() {
        let pattern = AdBlockRuleBuilder.hostPattern(for: "jsdelivr.net")
        XCTAssertFalse(AdBlockRuleBuilder.pattern(pattern, matches: "https://notjsdelivr.net/x.js"))
        XCTAssertFalse(AdBlockRuleBuilder.pattern(pattern, matches: "https://jsdelivr.net.evil.example/x.js"))
    }

    // MARK: - Emitted rules

    func testEveryExceptionRuleIsHostAnchored() {
        for domain in AdBlockRuleBuilder.alwaysAllowedDomains {
            let rule = AdBlockRuleBuilder.exceptionRule(for: domain)
            XCTAssertEqual(actionType(of: rule), "ignore-previous-rules", domain)
            let filter = urlFilter(of: rule)
            XCTAssertTrue(filter.hasPrefix("^https?://"), "unanchored exception for \(domain): \(filter)")
            XCTAssertFalse(
                AdBlockRuleBuilder.pattern(filter, matches: "https://tracker.example/px?r=https://\(domain)/"),
                "exception for \(domain) is claimable from a query string"
            )
        }
    }

    func testBlockRulesAreHostAnchoredAndThirdPartyOnly() {
        let rule = AdBlockRuleBuilder.blockRule(for: "doubleclick.net")
        XCTAssertEqual(actionType(of: rule), "block")
        XCTAssertEqual(trigger(of: rule)["load-type"] as? [String], ["third-party"])
        let filter = urlFilter(of: rule)
        XCTAssertTrue(AdBlockRuleBuilder.pattern(filter, matches: "https://ad.doubleclick.net/ad"))
        XCTAssertFalse(AdBlockRuleBuilder.pattern(filter, matches: "https://example.com/?utm=doubleclick.net"))
    }

    // MARK: - /cdn-cgi/

    func testCDNCGIExceptionOnlyCoversTheSitesOwnPath() {
        let rule = AdBlockRuleBuilder.cdnCGIExceptionRule()
        XCTAssertEqual(actionType(of: rule), "ignore-previous-rules")
        // Scoped to the site's own requests, as the comment always claimed.
        XCTAssertEqual(trigger(of: rule)["load-type"] as? [String], ["first-party"])

        let filter = urlFilter(of: rule)
        XCTAssertTrue(AdBlockRuleBuilder.pattern(
            filter, matches: "https://example.com/cdn-cgi/challenge-platform/scripts/jsd/main.js"))
        // The old bare `/cdn-cgi/` matched every one of these.
        XCTAssertFalse(AdBlockRuleBuilder.pattern(
            filter, matches: "https://tracker.example/px?path=/cdn-cgi/"))
        XCTAssertFalse(AdBlockRuleBuilder.pattern(
            filter, matches: "https://tracker.example/beacon/cdn-cgi/x.gif"))
    }

    // MARK: - First-party ad scripts

    func testScriptBlockRuleMatchesThePathNotTheQuery() {
        let rule = AdBlockRuleBuilder.scriptPathBlockRule(for: "ads.js")
        XCTAssertEqual(trigger(of: rule)["resource-type"] as? [String], ["script"])
        let filter = urlFilter(of: rule)
        XCTAssertTrue(AdBlockRuleBuilder.pattern(filter, matches: "https://example.com/ads.js"))
        XCTAssertTrue(AdBlockRuleBuilder.pattern(filter, matches: "https://example.com/static/js/ads.js?v=3"))
        XCTAssertFalse(AdBlockRuleBuilder.pattern(filter, matches: "https://example.com/app.js?from=/ads.js"))
    }

    // MARK: - The list as a whole

    func testEveryAllowedDomainIsANormalisedHost() {
        for domain in AdBlockRuleBuilder.alwaysAllowedDomains {
            XCTAssertEqual(domain, HostNormalizer.normalizedHost(domain),
                           "never-block entry is not a bare host: \(domain)")
        }
    }
}
