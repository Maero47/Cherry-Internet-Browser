//
//  Tab.swift
//  Internet Browser
//

import SwiftUI
import WebKit
import Observation
import UniformTypeIdentifiers

extension UTType {
    static let cherryBrowserTab = UTType(exportedAs: "com.cherry.browser.tab")
}

@Observable
final class Tab: NSObject, Identifiable {
    let id: UUID
    var url: URL?
    var title: String
    var favicon: NSImage?
    var isLoading: Bool
    var loadingProgress: Double
    var canGoBack: Bool
    var canGoForward: Bool
    var isPinned: Bool
    var isMuted: Bool {
        didSet {
            applyMuteState()
        }
    }
    var showHomePage: Bool
    var showSettingsPage: Bool
    /// The internal `cherry://` page this tab is showing, if any. While set,
    /// the tab's location IS the page's cherry:// URL: the omnibox displays
    /// it, the web view is not rendered (releasing the site's connection),
    /// and Back returns to `returnURL`.
    var internalPage: CherryPage? = nil
    /// The web URL that was showing when the internal page opened — the one
    /// logical "Back" step out of an internal page. Nil when the internal
    /// page was opened from the home page / a blank tab.
    var returnURL: URL? = nil
    var webView: WKWebView?
    var group: TabGroup?
    var isSleeping: Bool
    var lastActiveDate: Date
    var isPrivate: Bool

    /// Whether `window.__cherryFind` has been injected into this tab's
    /// current page. Per-tab (not a shared view-model flag) so each
    /// split-view pane's page tracks its own injection independently —
    /// view-plumbing state, not something the UI observes.
    @ObservationIgnored var findHelperInjected: Bool = false

    private(set) var createdAt: Date

    // Store URL before sleeping so we can reload
    private var sleepURL: URL?

    init(
        id: UUID = UUID(),
        url: URL? = nil,
        title: String = "New Tab",
        favicon: NSImage? = nil,
        isLoading: Bool = false,
        showHomePage: Bool = true,
        isPrivate: Bool = false
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.favicon = favicon
        self.isLoading = isLoading
        self.loadingProgress = 0
        self.canGoBack = false
        self.canGoForward = false
        self.isPinned = false
        self.isMuted = false
        self.showHomePage = url == nil ? showHomePage : false
        self.showSettingsPage = false
        self.createdAt = Date()
        self.isSleeping = false
        self.lastActiveDate = Date()
        self.isPrivate = isPrivate
        super.init()
    }

    var displayTitle: String {
        if title.isEmpty {
            return url?.displayHost ?? "New Tab"
        }
        return title
    }

    /// The tab's displayed location: the internal page's `cherry://` URL
    /// while one is active, else the web URL. This is what the omnibox reads.
    var displayURL: String {
        internalPage?.url.absoluteString ?? url?.absoluteString ?? ""
    }

    static let dragUTType: UTType = .cherryBrowserTab

    func itemProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.cherryBrowserTab.identifier,
            visibility: .all
        ) { completion in
            let data = self.id.uuidString.data(using: .utf8)
            completion(data, nil)
            return nil
        }
        return provider
    }

    func createWebView(configuration: WKWebViewConfiguration = WKWebViewConfiguration()) -> WKWebView {
        if let existing = webView {
            return existing
        }

        let wv = WKWebView(frame: .zero, configuration: configuration)
        wv.allowsBackForwardNavigationGestures = true
        wv.allowsMagnification = true
        // User agent is set via applicationNameForUserAgent on the configuration in WebViewWrapper
        self.webView = wv
        applyMuteState()
        return wv
    }

    /// Adopt an externally-created WKWebView (e.g. from a popup)
    func adoptWebView(_ wv: WKWebView) {
        self.webView = wv
        applyMuteState()
    }

    /// Sub-frames (iframes) that registered themselves via the mute install
    /// script. `evaluateJavaScript` only reaches the main frame, so to mute
    /// cross-origin embeds (YouTube/Vimeo players, video ads) live we must
    /// address each frame with `evaluateJavaScript(_:in:contentWorld:)`.
    /// Not observed — this is view-plumbing state, not UI state.
    @ObservationIgnored private var muteFrames: [WKFrameInfo] = []

    /// Records a frame that installed the mute observer, so live toggles can
    /// reach it. Called by the WebViewWrapper coordinator's message handler.
    func registerMuteFrame(_ frame: WKFrameInfo) {
        guard !frame.isMainFrame else { return }
        // Bound the list: independently-reloading iframes (rotating ads, chat
        // widgets) re-register without a main-frame navigation to clear them.
        // Stale entries are harmless (their eval no-ops) but must not grow
        // without limit; drop the oldest beyond the cap.
        if muteFrames.count >= 64 {
            muteFrames.removeFirst(muteFrames.count - 63)
        }
        muteFrames.append(frame)
        // Always correct the just-registered frame to the CURRENT state — the
        // script's baked-in `muted` value is fixed at web-view creation and may
        // be stale (e.g. muted then unmuted, then this iframe loaded). Pushing
        // unconditionally prevents an iframe getting stuck force-muted.
        webView?.evaluateJavaScript(MuteScripts.applyMuteJS(muted: isMuted),
                                    in: frame, in: .page, completionHandler: nil)
    }

    /// Drops recorded sub-frames — call when the main frame navigates, since
    /// its WKFrameInfo handles become stale.
    func resetMuteFrames() {
        muteFrames.removeAll()
    }

    /// Re-applies `isMuted` to the live WebView via JS (WKWebView has no public
    /// audio-mute API on macOS). Must be called whenever a tab's WKWebView is
    /// (re)created — e.g. sleep/wake, popup adoption, WebViewWrapper recreation —
    /// and on every navigation, since the JS-side mute state lives in the page's
    /// document and is lost on reload. Applies to the main frame and every
    /// registered sub-frame so iframe media toggles live too.
    func applyMuteState() {
        let js = MuteScripts.applyMuteJS(muted: isMuted)
        webView?.evaluateJavaScript(js, completionHandler: nil)
        for frame in muteFrames where !frame.isMainFrame {
            // Stale frames throw — ignore; worst case it's a no-op.
            webView?.evaluateJavaScript(js, in: frame, in: .page, completionHandler: nil)
        }
    }

    func loadURL(_ url: URL) {
        self.url = url
        self.showHomePage = false
        self.showSettingsPage = false
        // Loading web content always leaves any internal cherry:// page.
        self.internalPage = nil
        self.returnURL = nil
        self.isSleeping = false
        self.lastActiveDate = Date()
        webView?.load(URLRequest(url: url))
    }

    // MARK: - Internal cherry:// Pages

    /// Makes `page` this tab's location. Snapshots the current web URL into
    /// `returnURL` (the one logical Back step) and releases the web view so
    /// the site's connection is dropped while the internal page is shown —
    /// the content slot stops rendering the WKWebView because
    /// `internalPage != nil`, mirroring how the settings page already worked.
    func openInternalPage(_ page: CherryPage) {
        if internalPage == nil {
            returnURL = url
        }
        internalPage = page
        title = page.displayTitle
        favicon = nil
        showHomePage = false
        showSettingsPage = false
        url = nil
        // Release the old page like goHome does, so its audio/JS/timers stop
        // instead of lingering invisibly behind the internal page.
        webView?.stopLoading()
        webView?.loadHTMLString("", baseURL: nil)
        webView = nil
        isLoading = false
        loadingProgress = 0
        // Back from an internal page is always available: it returns to
        // `returnURL`, or to the home page when there was no site. Forward
        // never re-enters internal pages (single logical back-step model).
        canGoBack = true
        canGoForward = false
        isSleeping = false
        lastActiveDate = Date()
    }

    /// Leaves the internal page and returns the web URL to go back to
    /// (nil means there was no site — go to the home/new-tab state).
    func closeInternalPage() -> URL? {
        let target = returnURL
        internalPage = nil
        returnURL = nil
        return target
    }

    func reload() {
        webView?.reload()
    }

    func goBack() {
        webView?.goBack()
    }

    func goForward() {
        webView?.goForward()
    }

    func stopLoading() {
        webView?.stopLoading()
    }

    // MARK: - Tab Sleeping

    func sleep() {
        // Internal cherry:// pages have no web view to release and no URL to
        // restore on wake — sleeping one would only corrupt its state.
        guard !isSleeping, !showHomePage, internalPage == nil else { return }
        sleepURL = url
        isSleeping = true
        // Release the WebView to free memory
        webView = nil
    }

    func wake() {
        guard isSleeping else { return }
        isSleeping = false
        lastActiveDate = Date()
        // WebView will be re-created by WebViewWrapper; reload the URL
        if let savedURL = sleepURL ?? url {
            // Delay slightly to let the WebView get created
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.webView?.load(URLRequest(url: savedURL))
            }
        }
    }
}

// Tab inherits NSObject (required by WKWebExtensionTab), which already bridges
// Equatable/Hashable through isEqual(_:)/hash — override those instead of
// declaring Swift Equatable/Hashable conformance again, which would collide.
extension Tab {
    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Tab else { return false }
        return id == other.id
    }

    override var hash: Int {
        id.hashValue
    }
}

// MARK: - WKWebExtensionTab

extension Tab: WKWebExtensionTab {
    func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }
    func title(for context: WKWebExtensionContext) -> String? { title }
    func url(for context: WKWebExtensionContext) -> URL? { url }
    func isPinned(for context: WKWebExtensionContext) -> Bool { isPinned }
    func isMuted(for context: WKWebExtensionContext) -> Bool { isMuted }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { isPrivate }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !isLoading }

    // `Tab` isn't `@MainActor`-isolated but WebKit only ever calls these on
    // the main thread — `assumeIsolated` to reach the `@MainActor`-isolated
    // `ExtensionManager.shared`, matching `TabManager.notifyExtensionManager`'s
    // pattern elsewhere in the extension integration.

    /// The `WKWebExtensionWindow` for this tab's owning browser window. Without
    /// this, WebKit can't associate a tab with a window, so `tabs.query`
    /// filters like `{active: true, currentWindow: true}` return nothing.
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        MainActor.assumeIsolated {
            ExtensionManager.shared.windowAdapter(owningTab: self)
        }
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        MainActor.assumeIsolated {
            ExtensionManager.shared.isTabSelected(self)
        }
    }
}

