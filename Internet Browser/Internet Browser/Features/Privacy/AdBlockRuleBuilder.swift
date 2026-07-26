//
//  AdBlockRuleBuilder.swift
//  Cherry Browser
//

import Foundation

/// Builds the individual `WKContentRuleList` entries `AdBlockManager` emits.
///
/// This exists as its own pure type because the trigger patterns are security
/// relevant and were wrong: WebKit's `url-filter` is an **unanchored regex
/// over the whole URL**, so an exception written as the bare substring
/// `onetrust\.com` (or `/cdn-cgi/`) matched
/// `https://tracker.example/px?r=https://onetrust.com/` and fired
/// `ignore-previous-rules`, switching the entire blocklist off for that
/// request. Any tracker could opt itself out by putting one of those strings
/// anywhere in its path or query. Every pattern here is anchored to the
/// structural part of the URL it is meant to describe.
enum AdBlockRuleBuilder {

    // MARK: - Patterns

    /// Matches only the **host** of a URL: the domain itself or any subdomain
    /// of it, and nothing in a path or query string.
    ///
    /// `example.com` → `^https?://([^/]+\.)?example\.com[/:]`
    static func hostPattern(for domain: String) -> String {
        let escaped = HostNormalizer.normalizedHost(domain)
            .replacingOccurrences(of: ".", with: "\\.")
        return "^https?://([^/]+\\.)?" + escaped + "[/:]"
    }

    /// Matches Cloudflare's reserved `/cdn-cgi/` path — challenge scripts,
    /// Turnstile, email decoding — served from whatever host the page itself
    /// is on. Anchored so the path must *start* with `/cdn-cgi/`; a tracker
    /// URL that merely mentions the string later cannot claim the exception.
    static let cdnCGIPathPattern = "^https?://[^/]+/cdn-cgi/"

    // MARK: - Rules

    /// Blocks `domain` (and its subdomains) but only when it is embedded in
    /// someone else's page — navigating to the site directly still works.
    static func blockRule(for domain: String) -> [String: Any] {
        [
            "trigger": [
                "url-filter": hostPattern(for: domain),
                "url-filter-is-case-insensitive": true,
                // CRITICAL: Only block these domains as third-party requests.
                // When the user navigates directly to a site, all its own
                // resources (CSS, JS, images) must load normally. We only want
                // to block these domains when they appear as embedded trackers
                // on OTHER sites.
                "load-type": ["third-party"],
            ],
            "action": ["type": "block"],
        ]
    }

    /// Cancels every preceding block rule for requests **to** `domain`.
    /// Host-anchored: an exception for `cloudflare.com` must not be claimable
    /// by `https://tracker.example/?ref=cloudflare.com`.
    static func exceptionRule(for domain: String) -> [String: Any] {
        [
            "trigger": [
                "url-filter": hostPattern(for: domain),
                "url-filter-is-case-insensitive": true,
            ],
            "action": ["type": "ignore-previous-rules"],
        ]
    }

    /// The `/cdn-cgi/` exception, scoped to a first-party path so it only
    /// covers the site's own Cloudflare endpoints.
    static func cdnCGIExceptionRule() -> [String: Any] {
        [
            "trigger": [
                "url-filter": cdnCGIPathPattern,
                "url-filter-is-case-insensitive": true,
                "load-type": ["first-party"],
            ],
            "action": ["type": "ignore-previous-rules"],
        ]
    }

    /// Blocks a first-party script whose *path* ends in a known ad-script
    /// filename (`/ads.js`, `/pagead2.js`, …).
    ///
    /// Two rules rather than one, because the filename has to be the end of
    /// the path — either the URL stops there, or a query/fragment follows.
    /// Expressing that as one pattern needs alternation, which WebKit's
    /// `url-filter` parser rejects, and a rejected pattern takes the entire
    /// rule list down with it (see `AdBlockRuleCompilationTests`). Every
    /// construct used here — `^`, `$`, `[^…]`, `(…)?`, `*` — is verified
    /// against a real `WKContentRuleListStore`.
    ///
    /// Without the end anchor the pattern also matched `/ads.jsonp`,
    /// `/ads.jsx` and `/ads.js2`; JSONP endpoints do load via `<script src>`,
    /// so `resource-type` would not have excluded them.
    static func scriptPathBlockRules(for filename: String) -> [[String: Any]] {
        let escaped = filename.replacingOccurrences(of: ".", with: "\\.")
        // Anchored to a path segment boundary, so the filename cannot be
        // matched from a query parameter that happens to contain it.
        let pathPrefix = "^https?://[^/]+(/[^?#]*)?/" + escaped
        return [pathPrefix + "$", pathPrefix + "[?#]"].map { pattern in
            [
                "trigger": [
                    "url-filter": pattern,
                    "url-filter-is-case-insensitive": true,
                    "resource-type": ["script"],
                ],
                "action": ["type": "block"],
            ]
        }
    }

    // MARK: - Whole rule sets

    /// The EasyList-derived rule set: one third-party block rule per domain,
    /// then the never-block exceptions, which must come last to override them.
    static func domainRulesJSON(for domains: [String], limit: Int = 45_000) -> String {
        var rules: [[String: Any]] = []
        for domain in domains {
            rules.append(blockRule(for: domain))
            if rules.count >= limit { break }
        }
        for domain in alwaysAllowedDomains {
            rules.append(exceptionRule(for: domain))
        }
        rules.append(cdnCGIExceptionRule())
        return json(from: rules)
    }

    static func json(from rules: [[String: Any]]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: rules, options: []),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    // MARK: - Never-block list

    /// Hosts that must never be blocked: consent management platforms
    /// (blocking them leaves an un-dismissable cookie wall), CAPTCHA and
    /// Cloudflare challenge infrastructure, and the big CDNs whose absence
    /// breaks page layout outright.
    static let alwaysAllowedDomains: [String] = [
        // Consent management platforms
        "sp-prod.net", "sourcepoint.com", "privacy-mgmt.com",
        "onetrust.com", "cookielaw.org", "cookiepro.com",
        "optanon.blob.core.windows.net",
        "trustarc.com", "cookiebot.com", "iubenda.com",
        "quantcast.com", "consensu.org", "didomi.io",
        "osano.com", "usercentrics.eu", "consentmanager.net",
        "privacymanager.io", "transcend.io", "termly.io",
        "summerhamster.com", "tagcommander.com",
        "rlcdn.com", "admiral.com", "ketchcdn.com",
        // CAPTCHA
        "recaptcha.net", "hcaptcha.com",
        // Cloudflare — challenges, beacon, insights
        "cloudflare.com", "cloudflareinsights.com",
        "challenges.cloudflare.com",
        // Major CDNs
        "cloudfront.net", "akamaihd.net", "akamaized.net",
        "fastly.net",
        "bootstrapcdn.com", "jsdelivr.net",
    ]

    /// Ad-script filenames blocked even when served first-party.
    static let blockedScriptFilenames = [
        "ads.js", "pagead.js", "pagead2.js",
        "adsbygoogle.js", "show_ads.js",
    ]

    // MARK: - Verification

    /// Evaluates a generated `url-filter` the way WebKit does — an
    /// unanchored, case-insensitive regex search over the entire URL. Used by
    /// the unit tests to prove a pattern matches the host it names and
    /// nothing that merely mentions it.
    static func pattern(_ pattern: String, matches url: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(url.startIndex..., in: url)
        return regex.firstMatch(in: url, options: [], range: range) != nil
    }
}
