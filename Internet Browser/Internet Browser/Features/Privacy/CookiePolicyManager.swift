//
//  CookiePolicyManager.swift
//  Cherry Browser
//

import Foundation
import WebKit

extension Notification.Name {
    /// Posted whenever a compiled `WKContentRuleList` appears, changes, or is
    /// dropped — by `CookiePolicyManager` and by `AdBlockManager`.
    ///
    /// Rule lists compile asynchronously, and a web view only ever holds the
    /// lists that existed when it was built. Without this, tabs restored at
    /// launch (created before the first compile finishes), background-research
    /// web views, and adopted popups all run with no rules attached, while the
    /// settings UI says otherwise. Every coordinator listens and re-attaches.
    static let cherryContentRuleListsChanged = Notification.Name("cherryContentRuleListsChanged")
}

/// Enforces the Cookie Policy picker.
///
/// The picker used to do nothing at all: it set
/// `HTTPCookieStorage.shared.cookieAcceptPolicy`, which governs `URLSession`
/// and is simply not consulted by WKWebView (WebKit keeps its cookies in
/// `WKWebsiteDataStore.httpCookieStore`), and it was only applied from the
/// property's `didSet`, so a policy chosen in a previous launch was never
/// re-applied anyway.
///
/// What actually works from an embedder is a `WKContentRuleList` with the
/// `block-cookies` action, which strips cookies from requests before they are
/// sent. That is real, but it is not total: it acts on network requests, so a
/// page's own `document.cookie` still works for the lifetime of the document.
/// The settings UI says so rather than overpromising.
@MainActor
@Observable
final class CookiePolicyManager {
    static let shared = CookiePolicyManager()

    /// The list every web view should currently be carrying. `nil` for "Allow
    /// All", and also while a newly selected policy is still compiling.
    private(set) var compiledList: WKContentRuleList?

    /// Policy `compiledList` belongs to. Read by web views to tell "no list
    /// because Allow All" apart from "no list yet".
    private(set) var activeLevel: CookieBlockingLevel = .none

    /// Identifier is versioned so a previously compiled list is never reused
    /// for different rules.
    private static func identifier(for level: CookieBlockingLevel) -> String {
        "CherryCookiePolicy_V1_\(level.rawValue.replacingOccurrences(of: " ", with: "_"))"
    }

    private init() {}

    // MARK: - Apply

    /// Adds the current cookie rule list to a web view configuration. Called
    /// for every new web view — fresh, adopted, or background — and again
    /// whenever the live rule lists are rebuilt.
    func apply(to configuration: WKWebViewConfiguration) {
        guard let compiledList else { return }
        configuration.userContentController.add(compiledList)
    }

    /// Compiles the rule list for `level` (or drops it for "Allow All").
    ///
    /// Not idempotent on the *stored* level alone: a repeat call for a level
    /// whose compile failed will retry, and every successful compile posts
    /// `cherryContentRuleListsChanged` so existing web views pick it up. The
    /// previous version latched — it recorded the new level immediately and
    /// returned early forever after, so the second policy change a user made
    /// was silently a no-op.
    func updatePolicy(_ level: CookieBlockingLevel) {
        guard let json = Self.ruleJSON(for: level) else {
            activeLevel = level
            compiledList = nil
            NotificationCenter.default.post(name: .cherryContentRuleListsChanged, object: nil)
            return
        }
        // Already compiled and in force.
        if activeLevel == level, compiledList != nil { return }

        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: Self.identifier(for: level),
            encodedContentRuleList: json
        ) { [weak self] ruleList, error in
            Task { @MainActor in
                guard let self else { return }
                // A newer selection may have landed while this compiled.
                guard SettingsManager.shared.blockCookies == level else { return }

                if let error {
                    print("""
                    [Cookies] ❌❌❌ POLICY "\(level.rawValue)" FAILED TO COMPILE — \
                    COOKIES ARE NOT BEING BLOCKED. \(error.localizedDescription)
                    """)
                    self.compileFailure = error.localizedDescription
                    return
                }
                self.compileFailure = nil
                self.activeLevel = level
                self.compiledList = ruleList
                print("[Cookies] ✅ Applied policy: \(level.rawValue)")
                NotificationCenter.default.post(name: .cherryContentRuleListsChanged, object: nil)
            }
        }
    }

    /// Non-nil when the selected policy could not be compiled, i.e. cookies
    /// are not actually being blocked. Surfaced in Settings.
    private(set) var compileFailure: String?

    // MARK: - Rules

    /// `nil` when the level needs no rules at all.
    static func ruleJSON(for level: CookieBlockingLevel) -> String? {
        let trigger: [String: Any]
        switch level {
        case .none:
            return nil
        case .thirdParty:
            // Everything loaded from a registrable domain other than the
            // page's own — the tracking case.
            trigger = ["url-filter": ".*", "load-type": ["third-party"]]
        case .all:
            trigger = ["url-filter": ".*"]
        }

        let rules: [[String: Any]] = [["trigger": trigger, "action": ["type": "block-cookies"]]]
        guard let data = try? JSONSerialization.data(withJSONObject: rules, options: []),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }
}
