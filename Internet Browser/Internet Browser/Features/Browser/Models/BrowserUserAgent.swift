//
//  BrowserUserAgent.swift
//  Internet Browser
//

import WebKit

/// The ONE place Cherry's user-agent product token is written.
///
/// WKWebView appends `applicationNameForUserAgent` to WebKit's own user
/// agent string; without it the page (or extension page) sees a bare
/// `Mozilla/5.0 (Macintosh…) AppleWebKit/605.1.15 (KHTML, like Gecko)` with
/// no product token at all, which every browser-sniffing script on the web
/// reads as "not a browser I know". Cherry claims Safari's token because
/// WKWebView IS the Safari/WebKit engine — a Chrome token would make the
/// fingerprint disagree with the engine and send Cloudflare-style bot
/// detectors into challenge loops.
///
/// Every web view Cherry creates goes through `apply(to:)`: visible tabs
/// (`WebViewWrapper`), background research tabs (`TabManager`), the
/// off-screen search scraper (`WebSearchService`), and — via the extension
/// controller's `webViewConfiguration` — every extension popup, options page
/// and background page (`ExtensionManager`).
///
/// It is deliberately one constant and one setter rather than a literal per
/// call site: extension pages were left on a bare user agent for exactly as
/// long as this string was copied per-web-view, and Bitwarden's popup was
/// the extension that noticed (its `getDevice()` sniff matched no browser,
/// returned nothing, and threw inside Angular's dependency injection, so the
/// popup never left its loading shell). Anything that raises the Safari
/// version here must raise it for extension pages in the same edit, and
/// `ExtensionRuntimeTests` fails if a second copy of the string appears.
enum BrowserUserAgent {
    /// The product token appended to WebKit's user agent.
    static let applicationName = "Version/18.3 Safari/605.1.15"

    /// Gives `configuration` Cherry's product token. The only assignment to
    /// `applicationNameForUserAgent` in the app.
    static func apply(to configuration: WKWebViewConfiguration) {
        configuration.applicationNameForUserAgent = applicationName
    }
}
