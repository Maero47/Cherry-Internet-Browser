//
//  CookiePolicyManager.swift
//  Cherry Browser
//

import Foundation
import WebKit

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
final class CookiePolicyManager {
    static let shared = CookiePolicyManager()

    private var compiledList: WKContentRuleList?
    private var compiledLevel: CookieBlockingLevel?
    private var isCompiling = false

    /// Identifier suffix is bumped whenever the emitted JSON changes, so a
    /// previously compiled list is never reused for different rules.
    private static func identifier(for level: CookieBlockingLevel) -> String {
        "CherryCookiePolicy_V1_\(level.rawValue.replacingOccurrences(of: " ", with: "_"))"
    }

    private init() {}

    // MARK: - Apply

    /// Adds the current cookie rule list to a web view configuration. Called
    /// for every new web view and again whenever the live rule lists are
    /// rebuilt after a settings change.
    func apply(to configuration: WKWebViewConfiguration) {
        guard let compiledList else { return }
        configuration.userContentController.add(compiledList)
    }

    /// Compiles the rule list for `level` (or drops it for "Allow All").
    /// Idempotent: re-selecting the active level is a no-op.
    func updatePolicy(_ level: CookieBlockingLevel) {
        guard compiledLevel != level else { return }
        compiledLevel = level

        guard let json = Self.ruleJSON(for: level) else {
            compiledList = nil
            return
        }

        isCompiling = true
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: Self.identifier(for: level),
            encodedContentRuleList: json
        ) { [weak self] ruleList, error in
            Task { @MainActor in
                guard let self else { return }
                self.isCompiling = false
                if let error {
                    print("[Cookies] ❌ Compile error for \(level.rawValue): \(error.localizedDescription)")
                    return
                }
                // A newer selection may have landed while this compiled.
                guard self.compiledLevel == level else { return }
                self.compiledList = ruleList
                print("[Cookies] ✅ Applied policy: \(level.rawValue)")
            }
        }
    }

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
