//
//  AdBlockManager.swift
//  Cherry Browser
//

import WebKit
import Foundation

@MainActor
final class AdBlockManager {
    static let shared = AdBlockManager()

    /// Multiple compiled rule lists — all get added to each webview
    private var compiledLists: [String: WKContentRuleList] = [:]
    private var isCompiling = false

    /// Whether any ad blocker rules are ready to use
    var rulesReady: Bool { !compiledLists.isEmpty }

    /// Continuations waiting for rules to be ready
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// For backward compatibility
    var compiledRuleList: WKContentRuleList? { compiledLists.values.first }
    var compiledSupplementaryList: WKContentRuleList? { compiledLists["supplementary"] }

    /// EasyList download URLs
    nonisolated private static let filterListURLs: [(String, String)] = [
        ("EasyList", "https://easylist.to/easylist/easylist.txt"),
        ("EasyPrivacy", "https://easylist.to/easylist/easyprivacy.txt"),
    ]

    /// Cache directory
    private nonisolated static var cacheDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("CherryBrowser", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    nonisolated private static let lastUpdateKey = "adblock_lastFilterUpdate_v13"

    private init() {
        compileRulesFromScratch()
    }

    // MARK: - Apply Rules

    func applyRules(to configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        for (name, ruleList) in compiledLists {
            controller.add(ruleList)
            print("[AdBlocker] ✅ Applied rule list: \(name)")
        }
        if compiledLists.isEmpty {
            print("[AdBlocker] ⚠️ No rules ready when applyRules called")
        }
    }

    /// Await until at least one rule list is compiled
    func ensureRulesCompiled() async {
        if !compiledLists.isEmpty { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    // MARK: - Compile Rules

    private func compileRulesFromScratch() {
        guard !isCompiling else { return }
        isCompiling = true

        // Remove old identifiers from previous versions
        for id in ["CherryAdBlocker", "CherryAdBlockerV2", "CherryAdBlockerV3",
                    "CherryAdBlockerV4", "CherryAdBlockerV5", "CherrySupplementaryV1",
                    "CherrySupp_V2", "CherrySupp_V4", "CherrySupp_V5", "CherrySupp_V6",
                    "CherrySupp_V7",
                    "CherryEasyDomains_V6", "CherryEasyDomains_V7",
                    "CherryEasyDomains_V9", "CherryEasyDomains_V10", "CherryEasyDomains_V11",
                    "CherryEasyDomains_V12",
                    "CherryEasyCSS_V6", "CherryEasyCSS_V7", "CherryEasyCSS_V8",
                    "CherryEasyCSS_V9", "CherryEasyCSS_V10"] {
            WKContentRuleListStore.default().removeContentRuleList(forIdentifier: id) { _ in }
        }
        // Also remove old cached JSON
        try? FileManager.default.removeItem(at: Self.cacheDir.appendingPathComponent("easylist_domains_v9.json"))
        try? FileManager.default.removeItem(at: Self.cacheDir.appendingPathComponent("easylist_domains_v10.json"))
        try? FileManager.default.removeItem(at: Self.cacheDir.appendingPathComponent("easylist_domains_v11.json"))
        try? FileManager.default.removeItem(at: Self.cacheDir.appendingPathComponent("easylist_domains_v12.json"))

        // 1) Compile supplementary rules (hardcoded, guaranteed to work)
        compileList(name: "supplementary", identifier: "CherrySupp_V8", json: Self.buildSupplementaryJSON())

        // 2) Try loading cached EasyList domain rules
        let domainCacheURL = Self.cacheDir.appendingPathComponent("easylist_domains_v13.json")

        WKContentRuleListStore.default().lookUpContentRuleList(forIdentifier: "CherryEasyDomains_V13") { [weak self] cached, _ in
            Task { @MainActor in
                guard let self else { return }
                if let cached {
                    self.compiledLists["easyDomains"] = cached
                    print("[AdBlocker] ✅ Loaded cached EasyList domain rules")
                    self.isCompiling = false
                    self.notifyWaiters()
                    self.updateFilterListsIfNeeded()
                } else if FileManager.default.fileExists(atPath: domainCacheURL.path),
                          let json = try? String(contentsOf: domainCacheURL, encoding: .utf8), json.count > 100 {
                    print("[AdBlocker] Compiling EasyList domains from local cache...")
                    self.compileList(name: "easyDomains", identifier: "CherryEasyDomains_V13", json: json)
                    self.isCompiling = false
                    self.notifyWaiters()
                } else {
                    print("[AdBlocker] No cache, downloading filter lists...")
                    self.downloadAndCompile()
                }
            }
        }
    }

    private func updateFilterListsIfNeeded() {
        let lastUpdate = UserDefaults.standard.double(forKey: Self.lastUpdateKey)
        let hoursSinceUpdate = (Date().timeIntervalSince1970 - lastUpdate) / 3600
        if hoursSinceUpdate > 24 {
            Task { await self.downloadAndCompileInBackground() }
        }
    }

    private func downloadAndCompile() {
        Task {
            let result = await Self.downloadAndExtract()
            await MainActor.run {
                if let result {
                    self.compileList(name: "easyDomains", identifier: "CherryEasyDomains_V13", json: result.domainJSON)
                } else {
                    print("[AdBlocker] ⚠️ Download failed, supplementary rules only")
                }
                self.isCompiling = false
                self.notifyWaiters()
            }
        }
    }

    private func downloadAndCompileInBackground() async {
        let result = await Self.downloadAndExtract()
        if let result {
            await MainActor.run {
                self.compileList(name: "easyDomains", identifier: "CherryEasyDomains_V13", json: result.domainJSON)
            }
        }
    }

    /// Compile a rule list and store it
    private func compileList(name: String, identifier: String, json: String) {
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: identifier,
            encodedContentRuleList: json
        ) { [weak self] ruleList, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    print("[AdBlocker] ❌ Compile error for \(name): \(error.localizedDescription)")
                    return
                }
                self.compiledLists[name] = ruleList
                print("[AdBlocker] ✅ Compiled \(name) successfully")
                self.notifyWaiters()
            }
        }
    }

    private func notifyWaiters() {
        let pending = waiters
        waiters.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }

    func invalidate() {
        compiledLists.removeAll()
        for id in ["CherryAdBlocker", "CherryAdBlockerV2", "CherryAdBlockerV3",
                    "CherryAdBlockerV4", "CherryAdBlockerV5", "CherrySupplementaryV1",
                    "CherrySupp_V2", "CherrySupp_V4", "CherrySupp_V6", "CherrySupp_V7",
                    "CherrySupp_V8",
                    "CherryEasyDomains_V6", "CherryEasyDomains_V7",
                    "CherryEasyDomains_V9", "CherryEasyDomains_V11", "CherryEasyDomains_V12",
                    "CherryEasyDomains_V13",
                    "CherryEasyCSS_V6", "CherryEasyCSS_V7", "CherryEasyCSS_V8",
                    "CherryEasyCSS_V9", "CherryEasyCSS_V10"] {
            WKContentRuleListStore.default().removeContentRuleList(forIdentifier: id) { _ in }
        }
        // Clean up all cached JSON files
        for name in ["easylist_domains_v9.json", "easylist_domains_v10.json",
                     "easylist_domains_v11.json", "easylist_domains_v12.json",
                     "easylist_domains_v13.json"] {
            try? FileManager.default.removeItem(at: Self.cacheDir.appendingPathComponent(name))
        }
        UserDefaults.standard.removeObject(forKey: Self.lastUpdateKey)
    }

    func forceUpdate() {
        invalidate()
        isCompiling = false
        compileRulesFromScratch()
    }

    // MARK: - Download & Extract

    private struct ExtractedLists: Sendable {
        let domainJSON: String
    }

    /// Download EasyList + EasyPrivacy and extract ONLY domain-block patterns.
    /// No CSS rules, no complex regex — just simple domain matches that WebKit handles reliably.
    private nonisolated static func downloadAndExtract() async -> ExtractedLists? {
        var combinedText = ""

        for (name, urlString) in filterListURLs {
            guard let url = URL(string: urlString) else { continue }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let text = String(data: data, encoding: .utf8) {
                    print("[AdBlocker] Downloaded \(name): \(text.count) chars")
                    combinedText += text + "\n"
                }
            } catch {
                print("[AdBlocker] ⚠️ Failed to download \(name): \(error.localizedDescription)")
            }
        }

        guard !combinedText.isEmpty else { return nil }

        let lines = combinedText.components(separatedBy: .newlines)
        var domains = Set<String>()

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("!") || trimmed.hasPrefix("[") { continue }
            if trimmed.hasPrefix("@@") { continue }
            // Skip CSS rules entirely
            if trimmed.contains("##") || trimmed.contains("#@#") { continue }

            // Domain blocking rules: ||domain.com^ or ||domain.com^$options
            if trimmed.hasPrefix("||") {
                var pattern = String(trimmed.dropFirst(2))

                if let dollarIdx = pattern.lastIndex(of: "$") {
                    let optStr = String(pattern[pattern.index(after: dollarIdx)...]).lowercased()
                    pattern = String(pattern[..<dollarIdx])

                    let skipOpts = ["popup", "csp", "rewrite", "redirect", "removeparam",
                                    "header", "badfilter", "document", "all"]
                    if skipOpts.contains(where: { optStr.contains($0) }) { continue }
                }

                while pattern.hasSuffix("^") || pattern.hasSuffix("*") {
                    pattern = String(pattern.dropLast())
                }

                if pattern.contains("/") || pattern.contains("*") || pattern.contains("=") { continue }
                if pattern.isEmpty || pattern.count < 3 { continue }
                if !pattern.contains(".") { continue }

                let validChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
                if pattern.unicodeScalars.contains(where: { !validChars.contains($0) }) { continue }

                domains.insert(pattern.lowercased())
            }
        }

        // Whitelist: consent management platforms, CDNs, and essential services
        let whitelist: Set<String> = [
            // Consent management
            "onetrust.com", "cookielaw.org", "cookiepro.com",
            "cdn.cookielaw.org", "optanon.blob.core.windows.net",
            "geolocation.onetrust.com", "privacyportal.onetrust.com",
            "trustarc.com", "consent.trustarc.com", "choices.trustarc.com",
            "cookiebot.com", "consent.cookiebot.com", "consentcdn.cookiebot.com",
            "iubenda.com", "cdn.iubenda.com",
            "quantcast.com", "quantcast.mgr.consensu.org",
            "consensu.org", "cmp.quantcast.com",
            "didomi.io", "sdk.privacy-center.org",
            "osano.com",
            "usercentrics.eu", "app.usercentrics.eu",
            "sourcepoint.com", "sp-prod.net",
            "consentmanager.net", "cdn.consentmanager.net",
            "privacy-mgmt.com", "cdn.privacy-mgmt.com",
            "privacymanager.io",
            "transcend.io", "cdn.transcend.io",
            "termly.io", "app.termly.io",
            // Additional Sourcepoint / IGN consent domains
            "sp-prod.net", "summerhamster.com",
            "mgr.consensu.org", "tcfapiLocator",
            "cmp-cdn.p.sourcepoint.com", "sourcepoint.mgr.consensu.org",
            "wrapper-api.sp-prod.net", "cdn.sp-prod.net",
            // Commanders Act / TagCommander
            "cdn.tagcommander.com", "tagcommander.com",
            // LiveRamp consent
            "ats.rlcdn.com", "rlcdn.com",
            // Admiral (anti-adblock + consent)
            "admiral.com", "cdn.admiral.com",
            // Ketch consent
            "global.ketchcdn.com", "ketchcdn.com",
            // CAPTCHA and security
            "recaptcha.net", "www.recaptcha.net",
            "hcaptcha.com", "assets.hcaptcha.com",
            "challenges.cloudflare.com",
            // Cloudflare services (challenge verification, beacon, insights)
            "cloudflareinsights.com", "static.cloudflareinsights.com",
            "cloudflare.com", "cdn.cloudflare.com",
            "cloudflare-dns.com", "one.one.one.one",
            "ajax.cloudflare.com", "cdnjs.cloudflare.com",
            // Google services
            "google.com", "www.google.com", "apis.google.com",
            "gstatic.com", "www.gstatic.com",
            "accounts.google.com",
            // Auth providers
            "login.microsoftonline.com",
            "appleid.apple.com", "appleid.cdn-apple.com",
            // Payment
            "stripe.com", "js.stripe.com",
            "paypal.com", "www.paypal.com",
            // Common CDNs (critical — blocking these breaks site layouts)
            "ajax.googleapis.com", "fonts.googleapis.com", "fonts.gstatic.com",
            "cdnjs.cloudflare.com", "cdn.jsdelivr.net", "unpkg.com",
            "code.jquery.com", "stackpath.bootstrapcdn.com",
            "maxcdn.bootstrapcdn.com", "cdn.bootcdn.net",
            "cdn.statically.io", "rawcdn.githack.com",
            "raw.githubusercontent.com",
            "cdn.cloudflare.com", "cloudflare.com",
            "akamaihd.net", "akamaized.net", "edgecastcdn.net",
            "fastly.net", "fastlylb.net",
            "cloudfront.net",
            "jsdelivr.net", "bootstrapcdn.com",
        ]

        for wl in whitelist { domains.remove(wl) }
        domains = domains.filter { domain in
            !whitelist.contains(where: { domain.hasSuffix("." + $0) })
        }

        print("[AdBlocker] Extracted \(domains.count) unique domains from EasyList")

        var domainRules: [[String: Any]] = []
        for domain in domains.sorted() {
            domainRules.append(AdBlockRuleBuilder.blockRule(for: domain))
            if domainRules.count >= 45000 { break }
        }

        // Consent platform + Cloudflare + CDN exceptions (ignore-previous-rules).
        // Host-anchored — see AdBlockRuleBuilder: an unanchored substring here
        // let any tracker cancel the whole blocklist for its own request.
        for domain in AdBlockRuleBuilder.alwaysAllowedDomains {
            domainRules.append(AdBlockRuleBuilder.exceptionRule(for: domain))
        }

        // Never block Cloudflare internal paths (/cdn-cgi/) — these serve challenge
        // scripts, turnstile captchas, and other essential Cloudflare functionality
        // from the SITE'S OWN domain
        domainRules.append(AdBlockRuleBuilder.cdnCGIExceptionRule())

        print("[AdBlocker] Domain rules: \(domainRules.count)")

        let domainJSON: String
        if let data = try? JSONSerialization.data(withJSONObject: domainRules, options: []),
           let json = String(data: data, encoding: .utf8) {
            domainJSON = json
        } else {
            domainJSON = "[]"
        }

        try? domainJSON.write(to: cacheDir.appendingPathComponent("easylist_domains_v13.json"), atomically: true, encoding: .utf8)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastUpdateKey)

        return ExtractedLists(domainJSON: domainJSON)
    }

    // MARK: - Cosmetic Filtering (CSS + JS injection)

    /// Inject cosmetic ad-hiding scripts into a WKWebViewConfiguration.
    /// CSS runs at document-start (hides ads before render), JS runs at document-end (catches dynamic ads).
    /// Scripts check `window.__cherryAdBlockEnabled` so they can be toggled at runtime.
    func applyCosmeticRules(to configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController

        let cssScript = WKUserScript(
            source: Self.buildCosmeticCSS(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        controller.addUserScript(cssScript)

        let jsScript = WKUserScript(
            source: Self.buildDynamicAdHidingJS(),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        controller.addUserScript(jsScript)

        print("[AdBlocker] ✅ Applied cosmetic filtering rules")
    }

    /// JS to disable cosmetic filtering on a live page (removes style tag, disconnects observer, unhides elements).
    static func cosmeticDisableJS() -> String {
        return """
        (function() {
            'use strict';
            window.__cherryAdBlockEnabled = false;
            var style = document.getElementById('cherry-cosmetic-adblock');
            if (style) style.remove();
            if (window.__cherryAdBlockObserver) {
                window.__cherryAdBlockObserver.disconnect();
                window.__cherryAdBlockObserver = null;
            }
            // Unhide elements that were hidden by the dynamic JS
            var hidden = document.querySelectorAll('[data-cherry-ad-hidden]');
            for (var i = 0; i < hidden.length; i++) {
                hidden[i].style.removeProperty('display');
                hidden[i].style.removeProperty('visibility');
                hidden[i].style.removeProperty('height');
                hidden[i].style.removeProperty('min-height');
                hidden[i].style.removeProperty('overflow');
                hidden[i].removeAttribute('data-cherry-ad-hidden');
            }
        })();
        """
    }

    /// JS to re-enable cosmetic filtering on a live page (re-injects style tag, restarts observer).
    static func cosmeticEnableJS() -> String {
        // Combine the CSS injection + dynamic observer JS into one evaluatable snippet
        return buildCosmeticCSS() + "\n" + buildDynamicAdHidingJS()
    }

    /// Returns JS that injects a <style> tag hiding common ad selectors at document start.
    private static func buildCosmeticCSS() -> String {
        let selectors = [
            // Google AdSense
            "ins.adsbygoogle",
            "div[id^=\"google_ads\"]",
            "div[id^=\"div-gpt-ad\"]",
            "[data-ad-slot]",
            "[data-ad-client]",
            "[data-google-query-id]",
            "iframe[id^=\"google_ads\"]",
            "iframe[src*=\"googlesyndication\"]",
            "iframe[src*=\"doubleclick\"]",

            // Taboola
            ".trc_related_container",
            "#taboola-below-article-thumbnails",
            "[id^=\"taboola-\"]",
            ".taboola-widget",
            ".tbl-feed-container",

            // Outbrain
            ".OUTBRAIN",
            "[data-widget-id^=\"AR_\"]",
            ".ob-widget",
            ".ob-smartfeed-wrapper",

            // Criteo
            "[data-criteo]",
            "[id^=\"criteo-\"]",

            // MGID
            "[id^=\"mgid-\"]",
            ".mgbox",
            ".mgline",

            // RevContent
            ".rc-widget",
            "[id^=\"rc-widget-\"]",

            // Generic ad containers
            ".ad-container",
            ".ad-wrapper",
            ".ad-banner",
            ".ad-slot",
            ".ad-unit",
            ".ad-placement",
            ".ad-leaderboard",
            ".ad-sidebar",
            ".ad-footer",
            ".ad-header",
            ".advertisement",
            ".advertisment",
            ".ad-block",
            ".advert",
            ".ads-banner",
            ".adsbox",

            // Class/ID patterns
            "[class*=\"ad-banner\"]",
            "[class*=\"ad-container\"]",
            "[class*=\"ad-wrapper\"]",
            "[id*=\"ad-banner\"]",
            "[id*=\"ad-container\"]",
            "[id*=\"ad-wrapper\"]",
            "[class*=\"GoogleAd\"]",
            "[class*=\"google-ad\"]",

            // Sidebar & in-article ads
            ".sidebar-ad",
            ".article-ad",
            ".in-article-ad",
            ".mid-article-ad",
            ".inline-ad",

            // Sticky / floating ads
            ".sticky-ad",
            ".floating-ad",
            "[class*=\"sticky-ad\"]",
            "[class*=\"stickyAd\"]",

            // Video ad overlays
            ".video-ad",
            ".video-ad-overlay",
            "[class*=\"video-ad\"]",
            ".preroll-ad",

            // Sponsored content
            ".sponsored-content",
            ".sponsored-post",
            "[class*=\"sponsored\"]",

            // Tracking pixels
            "img[width=\"1\"][height=\"1\"]",
            "img[width=\"0\"][height=\"0\"]",
            "img[style*=\"display:none\"]",

            // Common ad iframes
            "iframe[src*=\"ads\"]",
            "iframe[src*=\"banner\"]",
            "iframe[width=\"728\"][height=\"90\"]",
            "iframe[width=\"300\"][height=\"250\"]",
            "iframe[width=\"160\"][height=\"600\"]",

            // Amazon ads
            "[id^=\"amzn-assoc-ad\"]",
            ".amzn-native-ad",

            // Media.net
            "[id^=\"_medianet_\"]",
            "[data-medianet]",

            // AdThrive / Mediavine
            ".adthrive-ad",
            "[data-adthrive-ad]",
            ".mv-ad-box",

            // Zergnet
            ".zergnet-widget",
            "[id^=\"zergnet-widget\"]",
        ]

        let cssRules = selectors.joined(separator: ",\n") + " { display: none !important; visibility: hidden !important; height: 0 !important; min-height: 0 !important; overflow: hidden !important; }"

        // Escape backticks and backslashes for JS template literal
        let escapedCSS = cssRules
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")

        return """
        (function() {
            'use strict';
            try {
                if (document.getElementById('cherry-cosmetic-adblock')) return;
                var style = document.createElement('style');
                style.id = 'cherry-cosmetic-adblock';
                style.type = 'text/css';
                style.textContent = `\(escapedCSS)`;
                (document.head || document.documentElement).appendChild(style);
            } catch(e) {}
        })();
        """
    }

    /// Returns JS that uses MutationObserver to hide dynamically inserted ad elements.
    /// Stores observer on `window.__cherryAdBlockObserver` and marks hidden elements with
    /// `data-cherry-ad-hidden` so they can be restored when ad blocking is disabled.
    private static func buildDynamicAdHidingJS() -> String {
        return """
        (function() {
            'use strict';
            // Disconnect any previous observer before creating a new one
            if (window.__cherryAdBlockObserver) {
                window.__cherryAdBlockObserver.disconnect();
                window.__cherryAdBlockObserver = null;
            }
            try {
                var adSelectors = [
                    'ins.adsbygoogle',
                    'div[id^="google_ads"]',
                    'div[id^="div-gpt-ad"]',
                    '[data-ad-slot]',
                    '[data-ad-client]',
                    '[data-google-query-id]',
                    '[id^="taboola-"]',
                    '.taboola-widget',
                    '.trc_related_container',
                    '.tbl-feed-container',
                    '.OUTBRAIN',
                    '.ob-widget',
                    '.ob-smartfeed-wrapper',
                    '[data-criteo]',
                    '[id^="criteo-"]',
                    '[id^="mgid-"]',
                    '.mgbox',
                    '.rc-widget',
                    '.ad-container',
                    '.ad-wrapper',
                    '.ad-banner',
                    '.ad-slot',
                    '.ad-unit',
                    '.ad-placement',
                    '.advertisement',
                    '.advert',
                    '.adsbox',
                    '[class*="ad-banner"]',
                    '[class*="ad-container"]',
                    '[class*="ad-wrapper"]',
                    '[class*="GoogleAd"]',
                    '.sidebar-ad',
                    '.article-ad',
                    '.in-article-ad',
                    '.inline-ad',
                    '.sticky-ad',
                    '.floating-ad',
                    '.video-ad',
                    '.video-ad-overlay',
                    '.sponsored-content',
                    '.sponsored-post',
                    'iframe[src*="googlesyndication"]',
                    'iframe[src*="doubleclick"]',
                    '[id^="amzn-assoc-ad"]',
                    '.adthrive-ad',
                    '[data-adthrive-ad]',
                    '.mv-ad-box',
                    '.zergnet-widget'
                ];

                var selectorString = adSelectors.join(',');

                // Consent/privacy selectors to never hide
                var consentKeywords = ['consent', 'cookie', 'gdpr', 'privacy', 'ccpa', 'onetrust', 'cookiebot', 'iubenda', 'didomi', 'quantcast', 'osano', 'usercentrics', 'termly'];

                function isConsentElement(el) {
                    var id = (el.id || '').toLowerCase();
                    var cls = (el.className || '').toString().toLowerCase();
                    for (var i = 0; i < consentKeywords.length; i++) {
                        if (id.indexOf(consentKeywords[i]) !== -1 || cls.indexOf(consentKeywords[i]) !== -1) {
                            return true;
                        }
                    }
                    return false;
                }

                function hideElement(el) {
                    if (isConsentElement(el)) return;
                    el.setAttribute('data-cherry-ad-hidden', '1');
                    el.style.setProperty('display', 'none', 'important');
                    el.style.setProperty('visibility', 'hidden', 'important');
                    el.style.setProperty('height', '0', 'important');
                    el.style.setProperty('min-height', '0', 'important');
                    el.style.setProperty('overflow', 'hidden', 'important');
                }

                function scanAndHide(root) {
                    try {
                        var ads = (root || document).querySelectorAll(selectorString);
                        for (var i = 0; i < ads.length; i++) {
                            hideElement(ads[i]);
                        }
                    } catch(e) {}
                }

                // Initial scan
                scanAndHide(document);

                // Watch for dynamically added nodes
                var pending = false;
                var observer = new MutationObserver(function(mutations) {
                    if (pending) return;
                    pending = true;
                    requestAnimationFrame(function() {
                        pending = false;
                        for (var i = 0; i < mutations.length; i++) {
                            var added = mutations[i].addedNodes;
                            for (var j = 0; j < added.length; j++) {
                                var node = added[j];
                                if (node.nodeType !== 1) continue;
                                try {
                                    if (node.matches && node.matches(selectorString)) {
                                        hideElement(node);
                                    }
                                    scanAndHide(node);
                                } catch(e) {}
                            }
                        }
                    });
                });

                observer.observe(document.documentElement, {
                    childList: true,
                    subtree: true
                });
                window.__cherryAdBlockObserver = observer;
            } catch(e) {}
        })();
        """
    }

    // MARK: - Supplementary Rules (hardcoded, guaranteed to compile)

    private static func buildSupplementaryJSON() -> String {
        // Every exact subdomain from the d3host adblock test list
        let exactDomains: [String] = [
            // Ads - Amazon
            "adtago.s3.amazonaws.com", "analyticsengine.s3.amazonaws.com",
            "analytics.s3.amazonaws.com", "advice-ads.s3.amazonaws.com",
            // Ads - Google
            "pagead2.googlesyndication.com", "adservice.google.com",
            "pagead2.googleadservices.com", "afs.googlesyndication.com",
            // Ads - Doubleclick
            "stats.g.doubleclick.net", "ad.doubleclick.net",
            "static.doubleclick.net", "m.doubleclick.net", "mediavisor.doubleclick.net",
            // Ads - Adcolony
            "ads30.adcolony.com", "adc3-launch.adcolony.com",
            "events3alt.adcolony.com", "wd.adcolony.com",
            // Ads - Media.net
            "static.media.net", "media.net", "adservetx.media.net",
            // Analytics - Google Analytics
            "analytics.google.com", "click.googleanalytics.com",
            "google-analytics.com", "ssl.google-analytics.com",
            // Analytics - Hotjar
            "adm.hotjar.com", "script.hotjar.com", "identify.hotjar.com",
            "insights.hotjar.com", "surveys.hotjar.com", "careers.hotjar.com", "events.hotjar.io",
            // Analytics - Luckyorange
            "api.luckyorange.com", "cdn.luckyorange.com", "realtime.luckyorange.com",
            "upload.luckyorange.net", "settings.luckyorange.net", "cs.luckyorange.net",
            "w1.luckyorange.com", "luckyorange.com",
            // Analytics - Mouseflow
            "api.mouseflow.com", "cdn.mouseflow.com", "cdn-test.mouseflow.com",
            "gtm.mouseflow.com", "o2.mouseflow.com", "tools.mouseflow.com", "mouseflow.com",
            // Analytics - Bugsnag
            "api.bugsnag.com", "app.bugsnag.com", "notify.bugsnag.com", "sessions.bugsnag.com",
            // Analytics - Sentry
            "browser.sentry-cdn.com", "app.getsentry.com",
            // Analytics - Freshmarketer
            "claritybt.freshmarketer.com", "fwtracks.freshmarketer.com", "freshmarketer.com",
            // Analytics - WordPress
            "stats.wp.com",
            // Social - Facebook
            "an.facebook.com", "pixel.facebook.com",
            // Social - Twitter
            "ads-api.twitter.com", "static.ads-twitter.com",
            // Social - LinkedIn
            "ads.linkedin.com", "analytics.pointdrive.linkedin.com",
            // Social - Pinterest
            "ads.pinterest.com", "log.pinterest.com", "trk.pinterest.com",
            // Social - Reddit
            "events.reddit.com", "events.redditmedia.com",
            // Social - TikTok
            "ads.tiktok.com", "ads-api.tiktok.com", "ads-sg.tiktok.com",
            "analytics.tiktok.com", "analytics-sg.tiktok.com",
            "business-api.tiktok.com", "log.byteoversea.com",
            // OEM - Xiaomi
            "sdkconfig.ad.xiaomi.com", "sdkconfig.ad.intl.xiaomi.com", "api.ad.xiaomi.com",
            "data.mistat.xiaomi.com", "data.mistat.india.xiaomi.com",
            "data.mistat.rus.xiaomi.com", "tracking.rus.miui.com",
            // OEM - Huawei
            "logservice.hicloud.com", "logservice1.hicloud.com", "logbak.hicloud.com",
            "metrics.data.hicloud.com", "metrics2.data.hicloud.com", "grs.hicloud.com",
            // OEM - Samsung
            "analytics-api.samsunghealthcn.com", "samsungads.com",
            "nmetrics.samsung.com", "smetrics.samsung.com", "samsung-com.112.2o7.net",
            // OEM - Apple
            "iadsdk.apple.com", "api-adservices.apple.com",
            "books-analytics-events.apple.com", "notes-analytics-events.apple.com",
            "weather-analytics-events.apple.com", "metrics.icloud.com", "metrics.mzstatic.com",
            // OEM - Oppo
            "adsfs.oppomobile.com", "adx.ads.oppomobile.com",
            "ck.ads.oppomobile.com", "data.ads.oppomobile.com",
            // OEM - Realme
            "bdapi-ads.realmemobile.com", "bdapi-in-ads.realmemobile.com",
            "iot-eu-logser.realme.com", "iot-logser.realme.com",
            // OEM - OnePlus
            "click.oneplus.cn", "open.oneplus.net",
            // OEM - Yandex
            "adfox.yandex.ru", "adfstat.yandex.ru", "appmetrica.yandex.ru",
            "extmaps-api.yandex.net", "metrika.yandex.ru", "offerwall.yandex.net",
            // Ads - Unity
            "adserver.unityads.unity3d.com", "auction.unityads.unity3d.com",
            "config.unityads.unity3d.com", "webview.unityads.unity3d.com",
            // Ads - Yahoo
            "ads.yahoo.com", "adtech.yahooinc.com", "analytics.query.yahoo.com",
            "analytics.yahoo.com", "gemini.yahoo.com", "geo.yahoo.com",
            "log.fc.yahoo.com", "partnerads.ysm.yahoo.com", "udcm.yahoo.com",
            // Ads - YouTube
            "ads.youtube.com",
        ]

        var rules: [[String: Any]] = []
        for domain in exactDomains {
            rules.append(AdBlockRuleBuilder.blockRule(for: domain))
        }

        // Block common ad script filenames (catches first-party served ad scripts)
        for filename in AdBlockRuleBuilder.blockedScriptFilenames {
            rules.append(AdBlockRuleBuilder.scriptPathBlockRule(for: filename))
        }

        // Exception rules: NEVER block requests to consent management platforms,
        // Cloudflare, or major CDNs. Must come LAST to override all block rules.
        for domain in AdBlockRuleBuilder.alwaysAllowedDomains {
            rules.append(AdBlockRuleBuilder.exceptionRule(for: domain))
        }
        // Never block Cloudflare internal paths (/cdn-cgi/)
        rules.append(AdBlockRuleBuilder.cdnCGIExceptionRule())

        guard let data = try? JSONSerialization.data(withJSONObject: rules, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        print("[AdBlocker] Supplementary: \(rules.count) rules")
        return json
    }
}
