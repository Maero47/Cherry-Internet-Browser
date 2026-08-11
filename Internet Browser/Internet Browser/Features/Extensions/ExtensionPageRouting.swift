//
//  ExtensionPageRouting.swift
//  Internet Browser
//
//  Which web view can serve which URL.
//
//  Putting `webkit-extension` in `NavigationSchemePolicy.internallyHandled`
//  stopped Cherry from throwing an extension's own page out to LaunchServices,
//  but it did not make the page loadable, because loading it was never a
//  question of the scheme. WebKit decides whether a web view may serve an
//  extension URL from the CONFIGURATION the web view was built with, and it
//  enforces that in both directions (`WKWebExtensionContext.webViewConfiguration`):
//
//    * A web view built from a plain `WKWebViewConfiguration` — even one with
//      `webExtensionController` set, which is what every Cherry tab had — fails
//      every navigation to a `webkit-extension://` URL with
//      `NSURLErrorResourceUnavailable` (−1008). That is the error the user saw.
//    * A web view built from an extension context's `webViewConfiguration`
//      cannot navigate ANYWHERE outside that extension. Measured: the
//      navigation is dropped with no `didFail` and no error at all — the tab
//      simply stops. So this cannot be fixed by giving every tab the extension
//      configuration; it is a genuine either/or.
//
//  A web view is therefore one of two mutually exclusive kinds, fixed at
//  creation, and a tab that crosses between them needs a NEW web view rather
//  than a `load()` on the one it has.
//

import Foundation

/// Which kind of web view a URL requires.
enum WebViewServingIdentity: Equatable {
    /// Ordinary web content: http(s), file, data, blob, about.
    case ordinary

    /// Pages belonging to ONE loaded extension.
    ///
    /// Named by the host of that context's `baseURL` — deliberately not by
    /// Cherry's own record id. Those two are not the same value:
    /// `ExtensionManager` overrides `WKWebExtensionContext.uniqueIdentifier`
    /// with its persisted record id to keep the extension's WebKit-side
    /// storage stable across launches, and WebKit does NOT move `baseURL` to
    /// match (measured: setting `uniqueIdentifier` leaves `baseURL` on its
    /// original random host). Extension page URLs are built from `baseURL`, so
    /// a lookup keyed on the record id matches nothing — which is exactly why
    /// the failing URL the user reported carried a host appearing nowhere in
    /// `index.json`.
    case extensionPage(host: String)
}

enum ExtensionPageRouting {

    /// WebKit's scheme for a loaded extension's own pages.
    static let scheme = "webkit-extension"

    static func isExtensionURL(_ url: URL?) -> Bool {
        url?.scheme?.lowercased() == scheme
    }

    /// The kind of web view `url` needs.
    ///
    /// `nil` means the URL is an extension page that NOTHING currently loaded
    /// can serve — a page from an extension that was removed or disabled, or a
    /// stale URL restored from a previous session. There is no web view that
    /// could load it, so callers must refuse it rather than open a tab that is
    /// guaranteed to fail.
    ///
    /// `servingHost` answers "which loaded extension owns this URL", and is
    /// `ExtensionManager.servingHost(for:)` in the app — a closure here so the
    /// policy is testable without a live `WKWebExtensionController`.
    static func servingIdentity(for url: URL?, servingHost: (URL) -> String?) -> WebViewServingIdentity? {
        guard let url, isExtensionURL(url) else { return .ordinary }
        guard let host = servingHost(url) else { return nil }
        return .extensionPage(host: host)
    }

    /// Whether a web view currently of kind `current` must be replaced before
    /// `target` can be loaded. An unservable target (`nil`) is not a swap —
    /// no web view can serve it, so there is nothing to swap to.
    static func requiresNewWebView(
        current: WebViewServingIdentity,
        target: WebViewServingIdentity?
    ) -> Bool {
        guard let target else { return false }
        return current != target
    }
}
