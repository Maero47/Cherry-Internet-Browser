//
//  AdBlockManager.swift
//  Cherry Browser
//

import WebKit

@MainActor
final class AdBlockManager {
    static let shared = AdBlockManager()

    private var compiledRuleList: WKContentRuleList?
    private var isCompiling = false

    private init() {
        // Pre-compile rules on launch
        compileRules { _ in }
    }

    // MARK: - Apply Rules

    func applyRules(to configuration: WKWebViewConfiguration) {
        if let ruleList = compiledRuleList {
            configuration.userContentController.add(ruleList)
        } else {
            compileRules { ruleList in
                guard let ruleList else { return }
                configuration.userContentController.add(ruleList)
            }
        }
    }

    // MARK: - Compile Rules

    private func compileRules(completion: @escaping (WKContentRuleList?) -> Void) {
        guard !isCompiling else { return }
        isCompiling = true

        let rules = Self.buildRulesJSON()

        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "CherryAdBlocker",
            encodedContentRuleList: rules
        ) { [weak self] ruleList, error in
            Task { @MainActor in
                self?.isCompiling = false
                if let error {
                    print("Ad blocker compile error: \(error.localizedDescription)")
                }
                self?.compiledRuleList = ruleList
                completion(ruleList)
            }
        }
    }

    func invalidate() {
        compiledRuleList = nil
        WKContentRuleListStore.default().removeContentRuleList(forIdentifier: "CherryAdBlocker") { _ in }
    }

    // MARK: - Comprehensive Rule Builder

    private static func buildRulesJSON() -> String {
        var rules: [[String: Any]] = []

        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        // SECTION 1: Major Ad Networks — Block requests
        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        let adNetworks = [
            // Google Ads
            "doubleclick\\.net",
            "googlesyndication\\.com",
            "googleadservices\\.com",
            "googleads\\.g\\.doubleclick\\.net",
            "pagead2\\.googlesyndication\\.com",
            "adservice\\.google\\.com",
            "afd\\.l\\.google\\.com",
            "tpc\\.googlesyndication\\.com",
            "pagead-googlehosted\\.l\\.google\\.com",
            "imasdk\\.googleapis\\.com",  // Google video ads SDK

            // Facebook / Meta Ads
            "facebook\\.com\\/tr",
            "connect\\.facebook\\.net\\/.*\\/fbevents",
            "ads\\.facebook\\.com",
            "an\\.facebook\\.com",
            "pixel\\.facebook\\.com",
            "ad\\.atdmt\\.com",

            // Amazon Ads
            "amazon-adsystem\\.com",
            "aax\\.amazon-adsystem\\.com",
            "z-na\\.amazon-adsystem\\.com",
            "fls-na\\.amazon-adsystem\\.com",
            "unagi\\.amazon\\.com",
            "assoc-redirect\\.amazon\\.com",

            // Microsoft / Bing Ads
            "ads\\.yahoo\\.com",
            "ads\\.bing\\.com",
            "bat\\.bing\\.com",
            "c\\.bing\\.com",
            "flex\\.msn\\.com",
            "rad\\.msn\\.com",

            // Twitter / X Ads
            "ads\\.twitter\\.com",
            "ads-api\\.twitter\\.com",
            "analytics\\.twitter\\.com",
            "static\\.ads-twitter\\.com",
            "ads\\.x\\.com",

            // Major SSPs & Exchanges
            "adnxs\\.com",
            "adsrvr\\.org",
            "adtechus\\.com",
            "advertising\\.com",
            "openx\\.net",
            "openx\\.com",
            "pubmatic\\.com",
            "rubiconproject\\.com",
            "casalemedia\\.com",
            "indexww\\.com",
            "indexexchange\\.com",
            "bidswitch\\.net",
            "smartadserver\\.com",
            "lijit\\.com",
            "sovrn\\.com",
            "spotxchange\\.com",
            "spotx\\.tv",
            "tremorhub\\.com",
            "undertone\\.com",
            "sharethrough\\.com",
            "yieldmo\\.com",
            "33across\\.com",
            "triplelift\\.com",
            "emxdgt\\.com",
            "rhythmone\\.com",
            "liveintent\\.com",
            "gumgum\\.com",
            "consumable\\.com",
            "kargo\\.com",
            "nativo\\.com",
            "xandr\\.com",

            // Criteo
            "criteo\\.com",
            "criteo\\.net",
            "emailretargeting\\.com",
            "hlserve\\.com",

            // Content recommendation / Native ads
            "outbrain\\.com",
            "outbrainimg\\.com",
            "taboola\\.com",
            "taboolasyndication\\.com",
            "revcontent\\.com",
            "mgid\\.com",
            "dianomi\\.com",
            "zergnet\\.com",
            "content\\.ad",
            "adblade\\.com",
            "popin\\.cc",

            // Video ad networks
            "teads\\.tv",
            "aniview\\.com",
            "springserve\\.com",
            "videointellect\\.com",
            "connatix\\.com",
            "primis\\.tech",

            // Mobile ad networks
            "adcolony\\.com",
            "applovin\\.com",
            "chartboost\\.com",
            "vungle\\.com",
            "mopub\\.com",
            "smaato\\.com",
            "inmobi\\.com",
            "unityads\\.unity3d\\.com",
            "unity3d\\.com\\/ads",
            "appsflyer\\.com",
            "adjust\\.com",

            // Other ad networks
            "serving-sys\\.com",
            "media\\.net",
            "conversantmedia\\.com",
            "adform\\.net",
            "adroll\\.com",
            "tradedoubler\\.com",
            "zedo\\.com",
            "exponential\\.com",
            "tribalfusion\\.com",
            "yieldmanager\\.com",
            "specificclick\\.net",
            "buysellads\\.com",
            "carbonads\\.com",
            "revjet\\.com",
            "admixer\\.net",
            "bidtellect\\.com",
            "justpremium\\.com",
            "seedtag\\.com",
            "showheroes\\.com",
            "playground\\.xyz",
        ]

        for domain in adNetworks {
            rules.append([
                "trigger": ["url-filter": ".*\(domain).*"],
                "action": ["type": "block"]
            ])
        }

        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        // SECTION 2: Trackers & Analytics — Block requests
        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        let trackers = [
            // Google Analytics & Tag Manager
            "google-analytics\\.com",
            "googletagmanager\\.com",
            "googletagservices\\.com",
            "googlesyndication\\.com\\/safeframe",
            "ssl\\.google-analytics\\.com",

            // Social tracking pixels
            "platform\\.twitter\\.com\\/widgets",
            "connect\\.facebook\\.net",
            "platform\\.linkedin\\.com",
            "snap\\.licdn\\.com",
            "px\\.ads\\.linkedin\\.com",
            "ct\\.pinterest\\.com",
            "analytics\\.pinterest\\.com",
            "t\\.co\\/i\\/adsct",
            "sc-static\\.net\\/scevent",

            // Analytics platforms
            "scorecardresearch\\.com",
            "quantserve\\.com",
            "quantcount\\.com",
            "segment\\.io",
            "segment\\.com",
            "cdn\\.segment\\.com",
            "mixpanel\\.com",
            "hotjar\\.com",
            "static\\.hotjar\\.com",
            "script\\.hotjar\\.com",
            "fullstory\\.com",
            "rs\\.fullstory\\.com",
            "crazyegg\\.com",
            "mouseflow\\.com",
            "clicktale\\.net",
            "optimizely\\.com",
            "amplitude\\.com",
            "heapanalytics\\.com",
            "heap\\.io",
            "kissmetrics\\.com",
            "newrelic\\.com",
            "nr-data\\.net",
            "bam\\.nr-data\\.net",
            "bugsnag\\.com",
            "sentry\\.io",
            "matomo\\.cloud",
            "plausible\\.io",
            "clarity\\.ms",

            // DMP & Data brokers
            "omtrdc\\.net",
            "demdex\\.net",
            "bluekai\\.com",
            "krxd\\.net",
            "exelator\\.com",
            "turn\\.com",
            "rlcdn\\.com",
            "tapad\\.com",
            "pippio\\.com",
            "eyeota\\.net",
            "adsymptotic\\.com",
            "agkn\\.com",
            "bidswitch\\.net",
            "crwdcntrl\\.net",
            "lotame\\.com",
            "mookie1\\.com",
            "ib-ibi\\.com",
            "liveramp\\.com",
            "liadm\\.com",
            "oracleinfinity\\.io",
            "addthis\\.com",

            // Fingerprinting
            "fingerprintjs\\.com",
            "fpcdn\\.io",
            "cdn\\.fpjs\\.io",

            // Session replay
            "logrocket\\.com",
            "lr-in\\.com",
            "inspectlet\\.com",
            "smartlook\\.com",
            "sessioncam\\.com",
            "userreplay\\.net",
            "decibelinsight\\.net",
        ]

        for domain in trackers {
            rules.append([
                "trigger": ["url-filter": ".*\(domain).*"],
                "action": ["type": "block"]
            ])
        }

        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        // SECTION 3: URL patterns — Block ad/tracking paths
        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        let urlPatterns = [
            // Generic ad paths
            ".*\\/ads\\/.*",
            ".*\\/ad\\.js",
            ".*\\/ads\\.js",
            ".*\\/advert.*\\.js",
            ".*\\/advertisement\\/.*",
            ".*\\/banner[0-9]*\\..*",
            ".*\\/banners\\/.*",
            ".*\\/sponsor.*\\.js",
            ".*\\/sponsored\\/.*",

            // Tracking paths
            ".*\\/tracking\\/.*",
            ".*\\/tracker\\.js",
            ".*\\/tracker\\/.*",
            ".*\\/pixel\\.gif.*",
            ".*\\/pixel\\.png.*",
            ".*\\/pixel\\.js.*",
            ".*\\/beacon\\.js.*",
            ".*\\/collect\\?.*",
            ".*\\/__utm\\.gif.*",
            ".*\\/pageview\\?.*",
            ".*\\/event\\?.*tracking.*",
            ".*\\/telemetry.*",

            // Popups
            ".*\\/popup\\.js",
            ".*\\/popunder.*",
            ".*\\/interstitial.*\\.js",
            ".*\\/overlay-ad.*",

            // Ad scripts
            ".*\\/prebid.*\\.js",
            ".*\\/gpt\\.js",
            ".*\\/header-bidding.*",
            ".*\\/amazon-tam.*",
            ".*\\/aps-tag.*",

            // Common tracking params (block image/script requests)
            ".*\\/pixel\\?.*",
            ".*\\/log\\?.*event.*",
            ".*impression.*\\.gif",
            ".*click.*tracker.*",
        ]

        for pattern in urlPatterns {
            rules.append([
                "trigger": [
                    "url-filter": pattern,
                    "load-type": ["third-party"]
                ] as [String: Any],
                "action": ["type": "block"]
            ])
        }

        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        // SECTION 4: CSS Element Hiding — Hide ad containers
        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        let adSelectors = [
            // Google Ads
            ".adsbygoogle",
            "ins.adsbygoogle",
            "[id^=\"google_ads\"]",
            "[id^=\"div-gpt-ad\"]",
            "[data-google-query-id]",
            "[id^=\"google_companion_ad\"]",
            ".google-auto-placed",
            "google-ad",

            // Generic ad containers
            ".ad-banner",
            ".ad-container",
            ".ad-wrapper",
            ".ad-slot",
            ".ad-unit",
            ".ad-placement",
            ".ad-block",
            ".ad-box",
            ".ad-frame",
            ".ad-header",
            ".ad-footer",
            ".ad-leaderboard",
            ".ad-skyscraper",
            ".ad-rectangle",
            ".ad-overlay",
            ".ad-interstitial",
            ".advertisement",
            ".advertisment",
            ".advertising",
            "[class*=\"ad-slot\"]",
            "[class*=\"ad-banner\"]",
            "[class*=\"ad-container\"]",
            "[class*=\"ad-wrapper\"]",
            "[data-ad]",
            "[data-ad-slot]",
            "[data-ad-unit]",
            "[data-adunit]",
            "[data-ad-manager]",

            // Content recommendation widgets
            "[id*=\"taboola\"]",
            "[id*=\"outbrain\"]",
            ".ob-widget",
            ".ob-widget-section",
            ".OUTBRAIN",
            ".taboola-widget",
            ".trc_rbox",
            ".trc_related_container",
            "[id*=\"revcontent\"]",
            "[id*=\"mgid\"]",
            "[id*=\"zergnet\"]",

            // Sponsored content markers
            ".sponsored-content",
            ".promoted-content",
            ".native-ad",
            ".promoted-post",
            ".sponsored-post",
            ".paid-content",
            "[class*=\"sponsored\"]",
            "[class*=\"promoted-\"]",

            // Ad iframes
            "iframe[src*=\"doubleclick\"]",
            "iframe[src*=\"googlesyndication\"]",
            "iframe[src*=\"amazon-adsystem\"]",
            "iframe[src*=\"facebook.com/plugins\"]",
            "iframe[id*=\"google_ads\"]",
            "iframe[name*=\"google_ads\"]",
            "iframe[data-ad]",

            // Overlay / popup ads
            "[class*=\"popup-ad\"]",
            "[class*=\"modal-ad\"]",
            "[class*=\"interstitial\"]",
            "[id*=\"popup-ad\"]",
            "[id*=\"overlay-ad\"]",
            ".ad-modal",
            ".newsletter-popup",

            // Cookie consent / GDPR banners (optional, common annoyance)
            "[class*=\"cookie-banner\"]",
            "[class*=\"cookie-consent\"]",
            "[class*=\"cookie-notice\"]",
            "[id*=\"cookie-banner\"]",
            "[id*=\"cookie-consent\"]",
            "#onetrust-banner-sdk",
            ".cc-banner",
            ".cc-window",

            // Social share widgets (tracking)
            ".fb-like",
            ".twitter-share-button",
        ]

        let selectorString = adSelectors.joined(separator: ", ")
        rules.append([
            "trigger": ["url-filter": ".*"],
            "action": [
                "type": "css-display-none",
                "selector": selectorString
            ]
        ])

        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        // SECTION 5: Block WebSocket tracking
        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        let wsTrackers = [
            ".*\\.hotjar\\.com",
            ".*\\.fullstory\\.com",
            ".*\\.mouseflow\\.com",
            ".*\\.smartlook\\.com",
        ]

        for pattern in wsTrackers {
            rules.append([
                "trigger": [
                    "url-filter": pattern,
                    "resource-type": ["raw"]
                ] as [String: Any],
                "action": ["type": "block"]
            ])
        }

        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        // SECTION 6: Block tracking pixels (1x1 images)
        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        rules.append([
            "trigger": [
                "url-filter": ".*(pixel|beacon|track|log|collect|analytics).*\\.(gif|png|jpg).*",
                "resource-type": ["image"],
                "load-type": ["third-party"]
            ] as [String: Any],
            "action": ["type": "block"]
        ])

        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        // SECTION 7: Block third-party fonts used for tracking
        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        let fontTrackers = [
            ".*use\\.typekit\\.net\\/.*\\.js",  // Adobe Fonts tracking script
            ".*fast\\.fonts\\.net\\/t\\/trackingCode.*",
        ]

        for pattern in fontTrackers {
            rules.append([
                "trigger": ["url-filter": pattern],
                "action": ["type": "block"]
            ])
        }

        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        // SECTION 8: Site-specific rules for major sites
        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        // YouTube video ads (pre-roll, mid-roll ad requests)
        let youtubeAdPatterns = [
            ".*\\.youtube\\.com\\/api\\/stats\\/ads.*",
            ".*\\.youtube\\.com\\/pagead\\/.*",
            ".*\\.youtube\\.com\\/ptracking.*",
            ".*\\.youtube\\.com\\/get_midroll.*",
            ".*googlevideo\\.com\\/videogoodput.*",
            ".*youtube\\.com\\/sw\\.js_data.*",
        ]

        for pattern in youtubeAdPatterns {
            rules.append([
                "trigger": ["url-filter": pattern],
                "action": ["type": "block"]
            ])
        }

        // YouTube CSS hiding
        rules.append([
            "trigger": [
                "url-filter": ".*youtube\\.com.*",
                "if-domain": ["*youtube.com"]
            ] as [String: Any],
            "action": [
                "type": "css-display-none",
                "selector": ".ytp-ad-module, .ytp-ad-overlay-container, .ytp-ad-progress, .ytp-ad-skip-button-container, #player-ads, #masthead-ad, ytd-ad-slot-renderer, ytd-banner-promo-renderer, ytd-promoted-sparkles-web-renderer, ytd-display-ad-renderer, ytd-in-feed-ad-layout-renderer, .ytd-merch-shelf-renderer, #related ytd-promoted-video-renderer, ytd-promoted-sparkles-text-search-renderer, .sparkles-light-cta, ytd-action-companion-ad-renderer, tp-yt-paper-dialog.ytd-popup-container"
            ]
        ])

        // Reddit ads
        rules.append([
            "trigger": [
                "url-filter": ".*reddit\\.com.*",
                "if-domain": ["*reddit.com"]
            ] as [String: Any],
            "action": [
                "type": "css-display-none",
                "selector": "[data-testid=\"promoted\"], .promotedlink, .promoted, [class*=\"promoted\"], shreddit-ad-post, [data-before-content=\"promoted\"]"
            ]
        ])

        // Twitter/X ads
        rules.append([
            "trigger": [
                "url-filter": ".*x\\.com.*",
                "if-domain": ["*x.com", "*twitter.com"]
            ] as [String: Any],
            "action": [
                "type": "css-display-none",
                "selector": "[data-testid=\"placementTracking\"], article:has(path[d*=\"M19.498 3h-15\"])"
            ]
        ])

        // Serialize
        guard let data = try? JSONSerialization.data(withJSONObject: rules, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }

        return json
    }
}
