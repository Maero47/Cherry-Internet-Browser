//
//  HostNormalizerTests.swift
//  Internet BrowserTests
//
//  The host logic three features share. Two of them used to get it wrong in
//  ways a user could feel: pausing the ad blocker on `bbc.co.uk` stored
//  `co.uk` and switched blocking off for every UK site, and locale-sensitive
//  case folding broke host matching outright under a Turkish locale.
//

import XCTest
@testable import Cherry

final class HostNormalizerTests: XCTestCase {

    // MARK: - Case folding (the Turkish-locale bug)

    func testFoldedASCIIIsImmuneToTheTurkishDotlessI() {
        let turkish = Locale(identifier: "tr_TR")
        // What `.lowercased()` does for a user whose locale is Turkish: an
        // uppercase I becomes a DOTLESS ı, so the host stops matching itself.
        XCTAssertEqual("WIKI.ORG".lowercased(with: turkish), "wıkı.org")
        // What the shared normalizer does, for every user.
        XCTAssertEqual(HostNormalizer.foldedASCII("WIKI.ORG"), "wiki.org")
    }

    func testNormalizedHostFoldsCaseIndependentlyOfLocale() {
        XCTAssertEqual(HostNormalizer.normalizedHost("WIKIPEDIA.ORG"), "wikipedia.org")
        XCTAssertEqual(HostNormalizer.normalizedHost("Mail.Ionos.CO.UK"), "mail.ionos.co.uk")
    }

    // MARK: - normalizedHost

    func testNormalizedHostStripsSchemePathPortAndWWW() {
        XCTAssertEqual(
            HostNormalizer.normalizedHost("HTTPS://WWW.Example.CO.UK:8443/path?q=1#frag"),
            "example.co.uk"
        )
    }

    func testNormalizedHostStripsUserInfoAndTrailingRootDot() {
        XCTAssertEqual(HostNormalizer.normalizedHost("http://user:pw@example.com."), "example.com")
    }

    func testNormalizedHostCutsAtQueryEvenWithoutAPath() {
        XCTAssertEqual(HostNormalizer.normalizedHost("example.com?next=evil.com"), "example.com")
    }

    func testNormalizedHostKeepsIPv6Literal() {
        XCTAssertEqual(HostNormalizer.normalizedHost("http://[::1]:8080/x"), "[::1]")
    }

    func testNormalizedHostOfEmptyInputIsEmpty() {
        XCTAssertEqual(HostNormalizer.normalizedHost("   "), "")
    }

    // MARK: - baseDomain

    func testBaseDomainOfMultiLabelPublicSuffixKeepsTheRegistrableLabel() {
        // The regression: "last two labels" gave `co.uk` here.
        XCTAssertEqual(HostNormalizer.baseDomain("bbc.co.uk"), "bbc.co.uk")
        XCTAssertEqual(HostNormalizer.baseDomain("www.bbc.co.uk"), "bbc.co.uk")
        XCTAssertEqual(HostNormalizer.baseDomain("a.b.example.co.uk"), "example.co.uk")
    }

    func testBaseDomainOfPlainTLD() {
        XCTAssertEqual(HostNormalizer.baseDomain("example.com"), "example.com")
        XCTAssertEqual(HostNormalizer.baseDomain("www.example.com"), "example.com")
        XCTAssertEqual(HostNormalizer.baseDomain("a.b.c.example.com"), "example.com")
    }

    func testBaseDomainAcrossOtherMultiLabelRegistries() {
        XCTAssertEqual(HostNormalizer.baseDomain("shop.example.com.au"), "example.com.au")
        XCTAssertEqual(HostNormalizer.baseDomain("news.example.co.jp"), "example.co.jp")
        XCTAssertEqual(HostNormalizer.baseDomain("mail.example.gov.tr"), "example.gov.tr")
        XCTAssertEqual(HostNormalizer.baseDomain("www.example.govt.nz"), "example.govt.nz")
    }

    /// The Public Suffix List's *private* section: shared hosting where every
    /// customer is a subdomain. Missing these produces a base domain shared by
    /// every tenant — the `co.uk` hole at a different suffix.
    func testBaseDomainOfSharedHostingSuffixesKeepsTheTenantLabel() {
        let cases = [
            "attacker.github.io": "attacker.github.io",
            "someone.blogspot.com": "someone.blogspot.com",
            "app.vercel.app": "app.vercel.app",
            "site.netlify.app": "site.netlify.app",
            "docs.pages.dev": "docs.pages.dev",
            "api.workers.dev": "api.workers.dev",
            "thing.herokuapp.com": "thing.herokuapp.com",
            "proj.firebaseapp.com": "proj.firebaseapp.com",
            "svc.azurewebsites.net": "svc.azurewebsites.net",
            "bucket.s3.amazonaws.com": "bucket.s3.amazonaws.com",
            "dist.cloudfront.net": "dist.cloudfront.net",
        ]
        for (host, expected) in cases {
            XCTAssertEqual(HostNormalizer.baseDomain(host), expected, host)
        }
    }

    func testSharedHostingSuffixesCannotEnterAWhitelistAlone() {
        for suffix in ["github.io", "vercel.app", "pages.dev", "s3.amazonaws.com"] {
            XCTAssertTrue(HostNormalizer.isPublicSuffix(suffix), suffix)
            XCTAssertFalse(HostNormalizer.isRegistrable(suffix), suffix)
        }
    }

    func testLongestSuffixWins() {
        // `github.io` is the suffix, not `io` — so the tenant label is kept
        // and the deeper labels below it are dropped.
        XCTAssertEqual(HostNormalizer.baseDomain("a.b.tenant.github.io"), "tenant.github.io")
        XCTAssertEqual(HostNormalizer.baseDomain("a.b.site.co.uk"), "site.co.uk")
    }

    /// Regional cloud forms are open-ended — `s3.<region>`, `s3-website-<region>`,
    /// `execute-api.<region>`, `<account>.blob.core.windows.net`. Enumerating
    /// them is a losing game, so anything under a tenancy root is its own site.
    /// Collapsing these to `amazonaws.com` would be the `co.uk` hole again.
    func testRegionalCloudHostsAreTreatedAsTheirOwnSite() {
        let hosts = [
            "bucket.s3.eu-west-1.amazonaws.com",
            "bucket.s3-website-us-east-1.amazonaws.com",
            "api.execute-api.us-east-1.amazonaws.com",
            "account.blob.core.windows.net",
            "project.firebasestorage.googleapis.com",
        ]
        for host in hosts {
            XCTAssertEqual(HostNormalizer.baseDomain(host), host, host)
        }
    }

    func testBaseDomainLeavesIPLiteralsAlone() {
        XCTAssertEqual(HostNormalizer.baseDomain("192.168.1.10"), "192.168.1.10")
        XCTAssertEqual(HostNormalizer.baseDomain("[::1]"), "[::1]")
    }

    // MARK: - Public suffixes / registrability

    func testPublicSuffixesAreRecognised() {
        XCTAssertTrue(HostNormalizer.isPublicSuffix("com"))
        XCTAssertTrue(HostNormalizer.isPublicSuffix("co.uk"))
        XCTAssertTrue(HostNormalizer.isPublicSuffix("com.au"))
        XCTAssertTrue(HostNormalizer.isPublicSuffix("gov.uk"))
        XCTAssertFalse(HostNormalizer.isPublicSuffix("bbc.co.uk"))
        XCTAssertFalse(HostNormalizer.isPublicSuffix("example.com"))
    }

    /// The purge in `SettingsManager` uses the TABLE only. The
    /// `<generic>.<ccTLD>` heuristic reads real, registrable sites as
    /// suffixes; deleting a pause the user deliberately set on one of those
    /// would be a worse bug than keeping a narrow entry.
    func testKnownPublicSuffixIsTableDrivenAndSpareTheseRealSites() {
        XCTAssertTrue(HostNormalizer.isKnownPublicSuffix("co.uk"))
        XCTAssertTrue(HostNormalizer.isKnownPublicSuffix("com.au"))
        XCTAssertTrue(HostNormalizer.isKnownPublicSuffix("com"))
        // Registry suffixes only. `github.io` IS a public suffix for deriving
        // a base domain, but it is not purgeable — see
        // testSharedHostingSuffixesAreNotPurgeable.
        XCTAssertFalse(HostNormalizer.isKnownPublicSuffix("github.io"))
        // Registrable sites the heuristic misreads — must survive the purge.
        XCTAssertFalse(HostNormalizer.isKnownPublicSuffix("web.de"))
        XCTAssertFalse(HostNormalizer.isKnownPublicSuffix("in.gr"))
        XCTAssertFalse(HostNormalizer.isKnownPublicSuffix("bbc.co.uk"))
    }

    /// Shared-hosting suffixes are *also* sites people browse. They belong in
    /// the suffix set for base-domain derivation (one tenant is not another),
    /// and must stay OUT of the purge table (deleting a pause the user set on
    /// medium.com every launch is worse than any hole it would close).
    func testSharedHostingSuffixesAreNotPurgeable() {
        for host in ["medium.com", "wordpress.com", "tumblr.com", "netlify.com",
                     "squarespace.com", "zendesk.com", "statuspage.io",
                     "supabase.co", "railway.app", "github.io"] {
            XCTAssertTrue(HostNormalizer.isPublicSuffix(host), "\(host) should be a suffix for derivation")
            XCTAssertFalse(HostNormalizer.isKnownPublicSuffix(host), "\(host) must never be purged")
        }
    }

    func testOnlyRegistrableHostsCanEnterAWhitelist() {
        XCTAssertTrue(HostNormalizer.isRegistrable("bbc.co.uk"))
        XCTAssertTrue(HostNormalizer.isRegistrable("example.com"))
        XCTAssertFalse(HostNormalizer.isRegistrable("co.uk"))
        XCTAssertFalse(HostNormalizer.isRegistrable("com"))
        XCTAssertFalse(HostNormalizer.isRegistrable(""))
    }

    // MARK: - Matching

    func testRuleCoversItselfAndItsSubdomainsOnly() {
        XCTAssertTrue(HostNormalizer.hostMatches("example.com", rule: "example.com"))
        XCTAssertTrue(HostNormalizer.hostMatches("www.example.com", rule: "example.com"))
        XCTAssertTrue(HostNormalizer.hostMatches("a.b.example.com", rule: "example.com"))
        // A rule for a subdomain must not cover the whole site.
        XCTAssertFalse(HostNormalizer.hostMatches("example.com", rule: "www.example.com"))
    }

    func testMatchingIsOnDotBoundariesNotSubstrings() {
        XCTAssertFalse(HostNormalizer.hostMatches("notexample.com", rule: "example.com"))
        XCTAssertFalse(HostNormalizer.hostMatches("example.com.evil.net", rule: "example.com"))
        // The whole point of item 3: a `.co.uk` entry must not blanket the TLD.
        XCTAssertFalse(HostNormalizer.hostMatches("bbc.co.uk", rule: "itv.co.uk"))
    }

    func testRelatedHostsAreSymmetric() {
        XCTAssertTrue(HostNormalizer.hostsAreRelated("www.example.com", "example.com"))
        XCTAssertTrue(HostNormalizer.hostsAreRelated("example.com", "www.example.com"))
        XCTAssertFalse(HostNormalizer.hostsAreRelated("bbc.co.uk", "itv.co.uk"))
    }
}
