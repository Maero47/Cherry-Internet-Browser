//
//  HostNormalizer.swift
//  Cherry Browser
//

import Foundation

/// The one place host names are cleaned, case-folded, reduced to a
/// registrable ("base") domain, and compared.
///
/// Three call sites used to carry their own copy of this logic and two of
/// them were wrong:
///
/// * `SettingsManager` took the last two labels as the base domain, so
///   pausing the ad blocker on `bbc.co.uk` stored **`co.uk`** and disabled
///   blocking on every `.co.uk` site. `PasswordRepository` had already solved
///   the same problem correctly (dot-boundary matching); the fix never
///   reached the ad-block or Focus Mode paths.
/// * Both folded case with `.lowercased()`, which is locale-sensitive: under
///   a Turkish locale `"I".lowercased()` is `"ı"` (dotless i), so every host
///   containing an uppercase I stopped matching its own whitelist entry.
enum HostNormalizer {

    // MARK: - Case folding

    /// Case-folds an ASCII identifier — a host, a scheme, a hex string — the
    /// same way for every user. `.lowercased()` follows the current locale
    /// and mangles I/i under Turkish and Azeri locales; identifiers are not
    /// prose and must never be folded that way.
    static func foldedASCII(_ value: String) -> String {
        value.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    // MARK: - Normalization

    /// Reduces anything a user or a URL can supply to a bare, comparable
    /// host: `"HTTPS://WWW.Example.CO.UK:8443/path?q=1"` → `"example.co.uk"`.
    /// Strips the scheme, any userinfo, the path/query/fragment, the port, a
    /// trailing root dot, and a leading `www.`.
    static func normalizedHost(_ input: String) -> String {
        var host = foldedASCII(input.trimmingCharacters(in: .whitespacesAndNewlines))

        if let schemeRange = host.range(of: "://") {
            host = String(host[schemeRange.upperBound...])
        }
        // Cut at the first path / query / fragment delimiter.
        if let end = host.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            host = String(host[..<end])
        }
        // user:password@host
        if let at = host.lastIndex(of: "@") {
            host = String(host[host.index(after: at)...])
        }
        // An IPv6 literal keeps its brackets and its inner colons; anything
        // else loses a :port suffix.
        if host.hasPrefix("[") {
            if let close = host.firstIndex(of: "]") {
                host = String(host[...close])
            }
        } else if let colon = host.firstIndex(of: ":") {
            host = String(host[..<colon])
        }
        while host.hasSuffix(".") {
            host = String(host.dropLast())
        }
        if host.hasPrefix("www.") {
            host = String(host.dropFirst(4))
        }
        return host
    }

    // MARK: - Base domain

    /// The registrable domain: the public suffix plus one label.
    /// `bbc.co.uk` → `bbc.co.uk`, `a.b.example.co.uk` → `example.co.uk`,
    /// `www.example.com` → `example.com`. IP literals are returned unchanged.
    ///
    /// Cherry does not ship the full Public Suffix List; it uses an explicit
    /// table of the multi-label suffixes that matter plus a conservative
    /// heuristic (see `isPublicSuffix`). Both err toward treating a suffix as
    /// *longer* than it really is, which yields a narrower base domain — the
    /// safe direction for a whitelist, since a too-short base is exactly the
    /// `co.uk` bug.
    static func baseDomain(_ host: String) -> String {
        let host = normalizedHost(host)
        guard !isIPLiteral(host) else { return host }

        let labels = host.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return host }

        let lastTwo = labels.suffix(2).joined(separator: ".")
        if isPublicSuffix(lastTwo) {
            return labels.suffix(3).joined(separator: ".")
        }
        return lastTwo
    }

    /// True when `host` is a public suffix — something nobody can register
    /// directly, and therefore something that must never end up in a
    /// whitelist on its own (`com`, `co.uk`, `com.au`).
    static func isPublicSuffix(_ host: String) -> Bool {
        let host = normalizedHost(host)
        guard !isIPLiteral(host) else { return false }

        let labels = host.split(separator: ".").map(String.init)
        switch labels.count {
        case 0: return true
        case 1: return true          // a bare TLD: "com", "uk"
        case 2: break
        default: return false
        }

        if knownMultiLabelSuffixes.contains(host) { return true }
        // Heuristic: <generic-second-level>.<two-letter ccTLD> — co.uk, com.au,
        // ne.jp, gov.tr … Registries that don't work that way (com.de is a
        // real registrable domain) get a *narrower* base domain, never a
        // wider one, so a false positive here cannot widen a whitelist.
        return labels[1].count == 2 && genericSecondLevelLabels.contains(labels[0])
    }

    /// True when `host` is something a person can actually own — used to
    /// reject junk (and to purge previously-stored public suffixes such as
    /// the `co.uk` the old base-domain code wrote) before it reaches a
    /// whitelist.
    static func isRegistrable(_ host: String) -> Bool {
        let host = normalizedHost(host)
        guard !host.isEmpty else { return false }
        if isIPLiteral(host) { return true }
        guard host.contains(".") else { return false }
        return !isPublicSuffix(host)
    }

    // MARK: - Matching

    /// True when `host` is `rule` itself or a subdomain of it, matched on a
    /// dot boundary. Directional: a rule covers its subdomains, never its
    /// parents — `example.com` matches `www.example.com`, but a rule for
    /// `www.example.com` does not cover the whole of `example.com`.
    static func hostMatches(_ host: String, rule: String) -> Bool {
        let host = foldedASCII(host)
        let rule = foldedASCII(rule)
        guard !host.isEmpty, !rule.isEmpty else { return false }
        return host == rule || host.hasSuffix("." + rule)
    }

    /// True when two hosts are the same site in either direction
    /// (`www.example.com` ↔ `example.com`). This is the rule
    /// `PasswordRepository.credentials(for:)` has always used to decide which
    /// saved credential belongs to a page; it is deliberately symmetric so a
    /// credential saved on the apex is offered on `www.`, and vice versa.
    static func hostsAreRelated(_ lhs: String, _ rhs: String) -> Bool {
        hostMatches(lhs, rule: rhs) || hostMatches(rhs, rule: lhs)
    }

    // MARK: - Internals

    static func isIPLiteral(_ host: String) -> Bool {
        if host.hasPrefix("[") || host.contains(":") { return true }   // IPv6
        let labels = host.split(separator: ".")
        guard labels.count == 4 else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.allSatisfy(\.isNumber)
        }
    }

    /// Second-level labels that are registry-operated under a two-letter
    /// ccTLD nearly everywhere they appear.
    private static let genericSecondLevelLabels: Set<String> = [
        "ac", "ad", "asn", "av", "bel", "biz", "co", "com", "ed", "edu", "gen",
        "go", "gob", "gouv", "gov", "gr", "id", "in", "ind", "info", "lg",
        "ltd", "me", "mil", "ne", "net", "nom", "or", "org", "pe", "plc",
        "pol", "pp", "pro", "re", "res", "sch", "web",
    ]

    /// Multi-label public suffixes the heuristic above would miss — either
    /// the second-level label is not generic (`police.uk`, `govt.nz`) or the
    /// TLD is longer than two letters (`com.krd`).
    private static let knownMultiLabelSuffixes: Set<String> = [
        "police.uk", "nhs.uk", "mod.uk", "parliament.uk",
        "govt.nz", "school.nz", "geek.nz", "kiwi.nz", "health.nz", "cri.nz",
        "k12.tr", "tsk.tr", "kep.tr", "bbs.tr", "gen.tr",
        "jus.br", "leg.br", "mil.br", "tur.br", "blog.br",
        "waw.pl", "krakow.pl", "wroc.pl", "poznan.pl", "gda.pl",
        "kiev.ua", "lviv.ua", "dp.ua",
        "conf.au", "csiro.au",
    ]
}
