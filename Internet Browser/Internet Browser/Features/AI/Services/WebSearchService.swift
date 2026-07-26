//
//  WebSearchService.swift
//  Cherry Browser
//
//  Single-shot DuckDuckGo web search for the panel's read-only research
//  agent: load the HTML results page in an off-screen WKWebView (Cherry is
//  WebKit-based, and a real render is far more robust against bot-gating
//  than a bare URLSession fetch of the SERP), pull the result anchors out
//  with injected JS, and turn them into up to `maxResults` `(url, title)`
//  pairs. The anchor-list → results step is a pure `nonisolated` function
//  (`parseResults`) so the redirect decoding, ad filtering, de-duping, and
//  capping are unit-testable without a webview or the network.
//
//  Read-only by construction: this service only ever LOADS the one search
//  page and READS its links. It never clicks, submits, or navigates further,
//  and the query is the only thing sent to DuckDuckGo.
//

import Foundation
import WebKit

/// One web search hit, ready to open as a tab. `snippet` is DuckDuckGo's own
/// result summary — used as a fallback source when the opened page can't be
/// extracted (bot-gated/heavy sites), so every result still contributes text.
struct WebSearchResult: Equatable {
    let url: URL
    let title: String
    var snippet: String = ""
}

/// One raw result pulled off the results page by the extraction JS, before
/// any filtering. `isAd` is the DOM-level signal (the anchor sat inside a
/// `.result--ad` container); URL-level ad signals are handled in parsing.
/// `snippet` is the result's `.result__snippet` text, if present.
struct WebSearchAnchor: Equatable {
    let href: String
    let text: String
    var snippet: String = ""
    var isAd: Bool = false
}

/// Searches DuckDuckGo's HTML endpoint and returns the top organic results.
/// Owned by the panel; a fresh off-screen webview is created per `search`
/// call and torn down when it returns, so no page state outlives a search.
@MainActor
final class WebSearchService {

    /// Top-N cap, per the single-shot research agent's design. `nonisolated`
    /// so the pure parsing below (and its tests) can read it off-main.
    nonisolated static let maxResults = 5
    /// The plain-HTML results endpoint — server-rendered anchors, no
    /// infinite scroll, and the layout the extraction JS below targets.
    static let endpoint = "https://html.duckduckgo.com/html/"
    /// SERP load budget. DuckDuckGo's HTML endpoint is a light static page;
    /// if it hasn't finished in this long it's blocked or broken — give up
    /// and return no results rather than hang the agent.
    static let loadTimeout: Duration = .seconds(12)

    /// Pulls every candidate result anchor off the loaded SERP: the modern
    /// layout's `a.result__a` title links, with an href-shaped fallback in
    /// case the class names change. Ad containers are tagged, not skipped,
    /// so the pure parser owns all filtering (and is tested for it).
    private static let anchorExtractionJS = """
    (function() {
        // Walk result containers so each title anchor can be paired with its
        // own `.result__snippet` summary (DuckDuckGo's per-result text).
        var out = [];
        var containers = Array.prototype.slice.call(document.querySelectorAll('.result, .web-result, .results_links'));
        containers.forEach(function(c) {
            var a = c.querySelector('a.result__a') || c.querySelector('a[href*="uddg="]');
            if (!a) return;
            var isAd = false;
            try { isAd = !!c.closest('.result--ad, .result--ad--small, [data-nrn="ad"]'); } catch (e) {}
            var snip = c.querySelector('.result__snippet');
            out.push({
                href: a.href || '',
                text: (a.innerText || '').trim(),
                snippet: (snip ? (snip.innerText || snip.textContent || '') : '').trim(),
                isAd: isAd
            });
        });
        // Fallback if the container layout changed: bare anchors, no snippets.
        if (out.length === 0) {
            var anchors = Array.prototype.slice.call(document.querySelectorAll('a.result__a'));
            if (anchors.length === 0) {
                anchors = Array.prototype.slice.call(document.querySelectorAll('a[href*="uddg="]'));
            }
            anchors.forEach(function(a) {
                var isAd = false;
                try { isAd = !!a.closest('.result--ad, .result--ad--small, [data-nrn="ad"]'); } catch (e) {}
                out.push({ href: a.href || '', text: (a.innerText || '').trim(), snippet: '', isAd: isAd });
            });
        }
        return out;
    })();
    """

    /// Runs ONE DuckDuckGo search for `query` and returns up to `maxResults`
    /// organic results. Every failure mode — bad query, load failure,
    /// timeout, layout change yielding no anchors — returns `[]`; the caller
    /// shows a friendly message and nothing else happens.
    func search(_ query: String) async -> [WebSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: Self.endpoint) else { return [] }
        components.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        guard let url = components.url else { return [] }

        // Off-screen, never in any window. Non-persistent store: the search
        // leaves no cookies or cache behind. Safari UA for the same reason as
        // WebViewWrapper — WKWebView IS Safari's engine, and a matching
        // fingerprint avoids bot-detection challenge loops.
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.applicationNameForUserAgent = "Version/18.3 Safari/605.1.15"
        // This page still makes real third-party requests, so it gets the same
        // network-level blocking a visible tab would. Cosmetic filtering is
        // skipped — nothing is displayed.
        //
        // This is a one-shot load with no coordinator, so it can never pick up
        // a list that compiles later — hence the await rather than a
        // best-effort `if rulesReady`. On a cold launch the search waits for
        // the blocklist instead of racing it.
        if SettingsManager.shared.adBlockEnabled {
            await AdBlockManager.shared.ensureRulesCompiled()
        }
        WebViewWrapper.applyContentRuleLists(to: configuration, pageURL: url)
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768), configuration: configuration)

        // `navigationDelegate` is weak — the local strong reference keeps the
        // waiter (and the webview) alive for exactly the duration of the call.
        let waiter = SERPLoadWaiter()
        webView.navigationDelegate = waiter

        defer {
            webView.stopLoading()
            webView.navigationDelegate = nil
        }

        guard await waiter.loadAndWait(URLRequest(url: url), in: webView, timeout: Self.loadTimeout) else {
            return []
        }

        guard let raw = try? await webView.evaluateJavaScript(Self.anchorExtractionJS),
              let entries = raw as? [[String: Any]] else {
            return []
        }
        let anchors = entries.map { entry in
            WebSearchAnchor(
                href: entry["href"] as? String ?? "",
                text: entry["text"] as? String ?? "",
                snippet: entry["snippet"] as? String ?? "",
                isAd: entry["isAd"] as? Bool ?? false
            )
        }
        let results = Self.parseResults(from: anchors)
        return results
    }
}

// MARK: - Pure SERP parsing (unit-tested)

extension WebSearchService {

    /// Turns the raw anchor list extracted from a DuckDuckGo HTML results
    /// page into the final result list: resolves each href to its real
    /// external target (decoding the `/l/?uddg=` redirect wrapper), drops
    /// ads (DOM-tagged, and everything routed through `y.js` — which the
    /// redirect-path check rejects) and non-http(s) links, de-dupes by
    /// target URL keeping the first (title) anchor, and caps the list at
    /// `maxResults`. Pure and `nonisolated` so it's testable with fixtures.
    nonisolated static func parseResults(
        from anchors: [WebSearchAnchor],
        maxResults: Int = WebSearchService.maxResults
    ) -> [WebSearchResult] {
        var seenKeys = Set<String>()
        var results: [WebSearchResult] = []
        for anchor in anchors {
            guard results.count < maxResults else { break }
            guard !anchor.isAd else { continue }
            guard let url = resolveTargetURL(fromHref: anchor.href) else { continue }
            let key = dedupeKey(for: url)
            guard !seenKeys.contains(key) else { continue }
            seenKeys.insert(key)
            let title = anchor.text.trimmingCharacters(in: .whitespacesAndNewlines)
            results.append(WebSearchResult(
                url: url,
                title: title.isEmpty ? (url.host() ?? url.absoluteString) : title,
                snippet: anchor.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
        return results
    }

    /// Resolves one SERP href to the external page it actually points at,
    /// or `nil` for anything that isn't an organic result link:
    /// - `duckduckgo.com/l/?uddg=<encoded>` redirect wrappers decode to
    ///   their target (which must itself be an external http(s) URL);
    /// - every other duckduckgo.com link (`y.js` ad clicks, settings,
    ///   feedback, pagination) is rejected;
    /// - non-http(s) schemes are rejected.
    /// Scheme-relative (`//…`) and site-relative (`/l/?…`) hrefs are
    /// accepted too, since fixture HTML — unlike the DOM's absolutized
    /// `a.href` property — can carry them verbatim.
    nonisolated static func resolveTargetURL(fromHref href: String) -> URL? {
        var absolute = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !absolute.isEmpty else { return nil }
        if absolute.hasPrefix("//") {
            absolute = "https:" + absolute
        } else if absolute.hasPrefix("/") {
            absolute = "https://duckduckgo.com" + absolute
        }
        guard let url = URL(string: absolute), isHTTPScheme(url) else { return nil }

        guard isDuckDuckGoHost(url) else { return url }

        // Only the /l/ redirect wrapper can yield a result from a DDG-hosted
        // link; y.js (ad clicks) and everything else internal is dropped.
        // Compared via pathComponents because `URL.path` strips the trailing
        // slash ("/l/" reads back as "/l").
        guard url.pathComponents.dropFirst().first == "l",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let target = components.queryItems?.first(where: { $0.name == "uddg" })?.value,
              let targetURL = URL(string: target),
              isHTTPScheme(targetURL),
              !isDuckDuckGoHost(targetURL) else { return nil }
        return targetURL
    }

    private nonisolated static func isHTTPScheme(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }

    private nonisolated static func isDuckDuckGoHost(_ url: URL) -> Bool {
        let host = url.host()?.lowercased() ?? ""
        return host == "duckduckgo.com" || host.hasSuffix(".duckduckgo.com")
    }

    /// De-dupe identity for a result URL: fragment-free, trailing-slash- and
    /// case-insensitive, so the same page linked twice (e.g. once by title,
    /// once by snippet under the href fallback) collapses to one result.
    private nonisolated static func dedupeKey(for url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        var key = components?.url?.absoluteString ?? url.absoluteString
        while key.hasSuffix("/") { key.removeLast() }
        return key.lowercased()
    }
}

// MARK: - SERP load waiting

/// Bridges the one-shot "did the SERP finish loading?" question into async.
/// Resumes its continuation exactly once, whichever comes first of didFinish,
/// didFail, or the timeout — everything runs on the main actor, so the
/// nil-out is race-free.
@MainActor
private final class SERPLoadWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Bool, Never>?

    func loadAndWait(_ request: URLRequest, in webView: WKWebView, timeout: Duration) async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            webView.load(request)
            // Unstructured on purpose: the caller's task being cancelled must
            // not cancel this sleep, or a leaked continuation could never
            // resume. Worst case the timeout fires late into a no-op.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.finish(false)
            }
        }
    }

    private func finish(_ loaded: Bool) {
        continuation?.resume(returning: loaded)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(false)
    }
}
