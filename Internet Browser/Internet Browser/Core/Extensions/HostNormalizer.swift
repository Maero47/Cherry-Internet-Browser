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

        // Cloud tenancy roots hand out subdomains in shapes we cannot enumerate
        // — `bucket.s3.eu-west-1.amazonaws.com`,
        // `bucket.s3-website-us-east-1.amazonaws.com`,
        // `api.execute-api.us-east-1.amazonaws.com`,
        // `account.blob.core.windows.net`. Rather than chase every regional
        // form, treat anything under them as its own site: the full host. Too
        // narrow costs the user one extra click; too short is the `co.uk` hole.
        if opaqueTenancyRoots.contains(where: { host.hasSuffix("." + $0) }) {
            return host
        }

        // Longest suffix wins. `foo.s3.amazonaws.com` must resolve against
        // `s3.amazonaws.com`, not `amazonaws.com` — checking shortest-first
        // would hand back a base domain shared by every S3 bucket.
        let longest = min(labels.count - 1, maxPublicSuffixLabels)
        for suffixLength in stride(from: longest, through: 2, by: -1) {
            let candidate = labels.suffix(suffixLength).joined(separator: ".")
            if isPublicSuffix(candidate) {
                return labels.suffix(suffixLength + 1).joined(separator: ".")
            }
        }
        return labels.suffix(2).joined(separator: ".")
    }

    /// True when `host` is a public suffix — something nobody can register
    /// directly, and therefore something that must never end up in a
    /// whitelist on its own (`com`, `co.uk`, `github.io`).
    ///
    /// Includes the shared-hosting ("private") suffixes, which the registry
    /// heuristic below cannot see: without `github.io` in the table, pausing
    /// the ad blocker on `attacker.github.io` would store `github.io` and
    /// cover every GitHub Pages site — the `co.uk` bug at a different suffix.
    static func isPublicSuffix(_ host: String) -> Bool {
        let host = normalizedHost(host)
        guard !isIPLiteral(host) else { return false }

        let labels = host.split(separator: ".").map(String.init)
        if labels.count < 2 { return true }          // "" or a bare TLD
        if registrySuffixes.contains(host) || privateHostingSuffixes.contains(host) { return true }
        guard labels.count == 2 else { return false }

        // Heuristic: <generic-second-level>.<two-letter ccTLD> — co.uk, com.au,
        // ne.jp, gov.tr … Registries that don't work that way (com.de is a
        // real registrable domain) get a *narrower* base domain, never a
        // wider one, so a false positive here cannot widen a whitelist.
        return labels[1].count == 2 && genericSecondLevelLabels.contains(labels[0])
    }

    /// The strictest reading: bare TLDs and unambiguous **registry** suffixes
    /// only — no heuristic, and no shared-hosting suffixes.
    ///
    /// Used where a false positive *destroys user data* rather than narrowing
    /// a lookup: the whitelist purge in `SettingsManager`. The two uses really
    /// are different. For deriving a base domain, `medium.com` and `github.io`
    /// belong in the suffix set (one tenant is not another). For deciding
    /// whether to delete an entry the user deliberately created, they do not —
    /// `medium.com` is a site people browse and pause, and purging it would
    /// silently undo that on every launch. Likewise the `<generic>.<ccTLD>`
    /// heuristic, which misreads real sites like `web.de` and `in.gr`.
    static func isKnownPublicSuffix(_ host: String) -> Bool {
        let host = normalizedHost(host)
        guard !isIPLiteral(host) else { return false }
        let labels = host.split(separator: ".")
        if labels.count < 2 { return true }
        return registrySuffixes.contains(host)
    }

    /// Both tables, still no heuristic: every suffix Cherry knows about,
    /// registry and shared-hosting alike.
    ///
    /// Used by the ONE-TIME whitelist migration, not by the per-launch purge.
    /// Data written by a pre-fix build can contain `github.io` — that build
    /// derived entries with "last two labels", so pausing on
    /// `attacker.github.io` stored the suffix and left ad-blocking off for
    /// every GitHub Pages site. Cleaning that up needs the wide table; doing
    /// it on every launch would instead keep deleting pauses users set on
    /// sites that are themselves suffixes (`medium.com`).
    static func isAnyKnownPublicSuffix(_ host: String) -> Bool {
        let host = normalizedHost(host)
        guard !isIPLiteral(host) else { return false }
        let labels = host.split(separator: ".")
        if labels.count < 2 { return true }
        return registrySuffixes.contains(host) || privateHostingSuffixes.contains(host)
    }

    /// True when `host` is something a person can actually own — used to
    /// reject junk before it reaches a whitelist.
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

    /// Longest suffix in `knownPublicSuffixes`, in labels. Bounds the search
    /// in `baseDomain`.
    private static let maxPublicSuffixLabels = 3

    /// The Public Suffix List's **ICANN** section: registry-operated suffixes
    /// nobody can register directly. Spelled out (rather than left to the
    /// heuristic) so the whitelist purge has a table it can trust absolutely.
    private static let registrySuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "net.uk", "ltd.uk", "plc.uk",
        "sch.uk", "police.uk", "nhs.uk", "mod.uk", "parliament.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au", "asn.au", "id.au",
        "conf.au", "csiro.au",
        "co.nz", "net.nz", "org.nz", "ac.nz", "govt.nz", "school.nz", "geek.nz",
        "kiwi.nz", "health.nz", "cri.nz",
        "co.jp", "or.jp", "ne.jp", "ac.jp", "go.jp", "ad.jp", "ed.jp", "gr.jp", "lg.jp",
        "co.kr", "or.kr", "ne.kr", "go.kr", "re.kr", "pe.kr",
        "co.za", "org.za", "net.za", "gov.za", "ac.za", "web.za",
        "co.in", "net.in", "org.in", "gen.in", "firm.in", "ind.in", "gov.in",
        "ac.in", "edu.in", "res.in",
        "com.br", "net.br", "org.br", "gov.br", "edu.br", "jus.br", "leg.br",
        "mil.br", "tur.br", "blog.br",
        "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn", "ac.cn",
        "com.tr", "net.tr", "org.tr", "gov.tr", "edu.tr", "bel.tr", "av.tr",
        "k12.tr", "tsk.tr", "kep.tr", "bbs.tr", "gen.tr",
        "com.mx", "com.ar", "com.sg", "com.hk", "com.tw", "com.my", "com.ph",
        "com.vn", "com.pk", "com.ua", "com.co", "com.pe", "com.ve", "com.ec",
        "com.uy", "com.py", "com.bo", "com.do", "com.gt", "com.pa", "com.sv",
        "com.ng", "com.gh", "com.eg", "com.sa", "com.qa", "com.kw", "com.bh",
        "com.om", "com.jo", "com.lb", "com.cy", "com.mt",
        "net.ua", "org.ua", "gov.ua", "edu.ua", "in.ua", "kiev.ua", "lviv.ua", "dp.ua",
        "com.pl", "net.pl", "org.pl", "gov.pl", "edu.pl",
        "waw.pl", "krakow.pl", "wroc.pl", "poznan.pl", "gda.pl",
        "co.il", "org.il", "net.il", "ac.il", "gov.il",
        "co.id", "or.id", "web.id", "ac.id", "go.id", "my.id",
        "co.th", "in.th", "ac.th", "go.th", "or.th",
        "co.ke", "co.ug", "co.tz", "co.zw", "co.mz", "co.ao",
        "co.cr", "go.cr", "ac.cr", "or.cr",
        "com.pt", "org.pt", "edu.pt", "gov.pt",
        "com.gr", "net.gr", "org.gr", "edu.gr", "gov.gr",
        "com.ro", "org.ro", "com.ru", "net.ru", "org.ru",
        "co.at", "or.at", "ac.at", "gv.at",
        "co.hu", "co.rs", "co.me", "co.ma", "co.im", "co.ls", "co.bw",
    ]

    /// The Public Suffix List's **private** section: shared hosting, where
    /// each customer gets a subdomain. One tenant must never be able to make a
    /// per-site decision that covers every other tenant — the `co.uk` hazard
    /// at a different suffix.
    ///
    /// Kept apart from `registrySuffixes` because these are also *sites*. A
    /// user browses `medium.com` and may pause ad-blocking on it; deriving a
    /// base domain must treat `a.medium.com` and `b.medium.com` as different
    /// sites, but the whitelist purge must never delete a `medium.com` entry.
    private static let privateHostingSuffixes: Set<String> = [
        "github.io", "githubusercontent.com", "gitlab.io", "bitbucket.io",
        "blogspot.com", "wordpress.com", "tumblr.com", "medium.com",
        "vercel.app", "netlify.app", "netlify.com", "pages.dev", "workers.dev",
        "r2.dev", "herokuapp.com", "herokudns.com", "onrender.com", "fly.dev",
        "firebaseapp.com", "web.app", "appspot.com", "run.app", "cloudfunctions.net",
        "azurewebsites.net", "azurestaticapps.net", "cloudapp.azure.com",
        "s3.amazonaws.com", "s3-website.amazonaws.com", "elasticbeanstalk.com",
        "cloudfront.net", "amplifyapp.com", "awsapprunner.com",
        "glitch.me", "surge.sh", "now.sh", "repl.co", "replit.dev",
        "ngrok.io", "ngrok-free.app", "trycloudflare.com", "loca.lt",
        "readthedocs.io", "gitbook.io", "notion.site", "webflow.io",
        "myshopify.com", "squarespace.com", "wixsite.com", "weebly.com",
        "sharepoint.com", "zendesk.com", "freshdesk.com", "statuspage.io",
        "translate.goog", "codeberg.page", "neocities.org", "hashnode.dev",
        "vercel.sh", "supabase.co", "railway.app", "deno.dev", "val.run",
    ]

    /// Cloud tenancy roots whose per-tenant subdomain shape is regional and
    /// open-ended (`s3.<region>.amazonaws.com`,
    /// `s3-website-<region>.amazonaws.com`, `execute-api.<region>.amazonaws.com`,
    /// `<account>.blob.core.windows.net`). Enumerating every form is a losing
    /// game, and getting it wrong yields a base domain shared by every
    /// customer of the platform — so anything under these is treated as its
    /// own site.
    private static let opaqueTenancyRoots: Set<String> = [
        "amazonaws.com", "amazonaws.com.cn",
        "windows.net", "core.windows.net", "azure.com", "azurecontainer.io",
        "googleapis.com", "googleusercontent.com", "cloudfunctions.net",
        "digitaloceanspaces.com", "linodeobjects.com", "backblazeb2.com",
    ]
}
