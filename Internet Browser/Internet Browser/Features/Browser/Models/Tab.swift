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
    /// it and the web view is not rendered — but `url` and `webView` keep the
    /// covered site, so Back simply re-shows it with history intact.
    var internalPage: CherryPage? = nil
    var webView: WKWebView?
    var group: TabGroup?
    var isSleeping: Bool
    var lastActiveDate: Date
    var isPrivate: Bool

    /// This tab's page-zoom level (View ▸ Zoom In / Zoom Out / Actual Size).
    /// Owned by the Tab, not the `WKWebView`, so it survives every web-view
    /// recreation — sleep/wake, Home, popup adoption — and so ⌘+ still records
    /// a level on a tab whose web view doesn't exist yet (it's applied the
    /// moment one does). See `applyZoomLevel()`.
    var zoomLevel: Double = PageZoom.defaultLevel

    /// Whether `window.__cherryFind` has been injected into this tab's
    /// current page. Per-tab (not a shared view-model flag) so each
    /// split-view pane's page tracks its own injection independently —
    /// view-plumbing state, not something the UI observes.
    @ObservationIgnored var findHelperInjected: Bool = false

    /// Set on tabs the web research AGENT opened as background result tabs
    /// (`TabManager.openBackgroundResearchTab`). The research indexer caps
    /// how much of such a tab's text it embeds (`WebAgentIndexBudget`) so the
    /// agent stays responsive; the user's own tabs are never capped. Plumbing
    /// state, not something the UI observes.
    @ObservationIgnored var isWebResearchTab: Bool = false

    /// The search-result SNIPPET for an agent-opened result tab, if any. Used
    /// as a fallback research source when the page itself can't be extracted
    /// (bot-gated/heavy sites) so the result still contributes text to the
    /// answer instead of being skipped. Plumbing state, not UI-observed.
    @ObservationIgnored var webResearchSnippet: String?

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

    /// The tab's displayed location: the internal page's `cherry://` URL while
    /// one is active, the `cherry://newtab` home address while on the home page,
    /// else the web URL. This is what the omnibox reads.
    var displayURL: String {
        if let page = internalPage { return page.url.absoluteString }
        if showHomePage { return CherryPage.newTabURLString }
        return url?.absoluteString ?? ""
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
        applyZoomLevel()
        return wv
    }

    /// Adopt an externally-created WKWebView (e.g. from a popup)
    func adoptWebView(_ wv: WKWebView) {
        self.webView = wv
        applyMuteState()
        applyZoomLevel()
    }

    /// Pushes `zoomLevel` onto the live web view. Must be called wherever a
    /// tab's WKWebView is (re)created or adopted — the same requirement
    /// `applyMuteState()` has, and the same call sites.
    func applyZoomLevel() {
        webView?.pageZoom = zoomLevel
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
        // Loading web content always leaves any internal cherry:// page; the
        // new navigation brings its own favicon, so drop the parked one.
        self.internalPage = nil
        self.faviconBeforeInternalPage = nil
        self.isSleeping = false
        self.lastActiveDate = Date()
        webView?.load(URLRequest(url: url))
    }

    // MARK: - Internal cherry:// Pages

    /// The site's tab-bar favicon, parked while an internal page is shown so
    /// the internal page's tab doesn't wear the covered site's icon; restored
    /// by `closeInternalPage`. Not observed — bookkeeping, not UI state.
    @ObservationIgnored private var faviconBeforeInternalPage: NSImage?

    /// Sets the covered SITE's favicon. Writes the tab icon directly unless
    /// an internal page is shown — then it updates the parked snapshot
    /// instead, so a slow background favicon fetch can't repaint the internal
    /// page's tab, and Back restores the fresh site icon rather than a stale
    /// one. Used by the WebViewWrapper coordinator's favicon download.
    func updateSiteFavicon(_ image: NSImage?) {
        if internalPage == nil {
            favicon = image
        } else {
            faviconBeforeInternalPage = image
        }
    }

    /// Makes `page` this tab's location. The WKWebView and `url` are
    /// deliberately KEPT (mirroring how `showSettingsPage` always worked):
    /// the content slot merely stops rendering the web view while
    /// `internalPage != nil`, so the site's back/forward list, scroll
    /// position, and form state all survive, and Back re-inserts the very
    /// same web view.
    func openInternalPage(_ page: CherryPage) {
        if internalPage == nil {
            faviconBeforeInternalPage = favicon
        }
        internalPage = page
        title = page.displayTitle
        favicon = nil
        showHomePage = false
        showSettingsPage = false
        // Back from an internal page is always available: it re-shows the
        // preserved site, or the home page when there was no site. Forward
        // never re-enters internal pages (single logical back-step model).
        // The WebViewWrapper coordinator's KVO write-backs skip these two
        // while internalPage != nil so background activity can't clobber them.
        canGoBack = true
        canGoForward = false
        isSleeping = false
        lastActiveDate = Date()
    }

    /// Leaves the internal page, restoring the tab's presentation (title,
    /// favicon, real back/forward state) from the preserved web view. The
    /// caller decides what to show next: `url` still holds the covered site
    /// (nil means there was no site — go to the home/new-tab state).
    func closeInternalPage() {
        internalPage = nil
        canGoBack = webView?.canGoBack ?? false
        canGoForward = webView?.canGoForward ?? false
        if let webTitle = webView?.title, !webTitle.isEmpty {
            title = webTitle
        } else if url == nil {
            title = "New Tab"
            // No covered site to return to (opened from a home/new tab) —
            // restore the home page, which openInternalPage cleared. Without
            // this the tab falls through to a blank WebView that reports
            // about:blank.
            showHomePage = true
        }
        favicon = faviconBeforeInternalPage
        faviconBeforeInternalPage = nil
    }

    // MARK: - Background load observation

    /// KVO bridges for a webview loading WITHOUT a `WebViewWrapper` (a
    /// background research tab): only the displayed tab gets a wrapper
    /// coordinator, so until this tab is selected nothing else mirrors the
    /// webview into the model. Mirroring matters for three things — the tab
    /// bar shows a live spinner/title, a redirect lands in `url` so adoption
    /// doesn't see a stale seed URL and issue a spurious reload of it (see
    /// `WebViewWrapper.updateNSView`'s reload condition), and the research
    /// panel's staleness re-gather (keyed on `isLoading`) can fire when a
    /// slow result page finishes after the agent's wait cap. Not observed —
    /// view plumbing, not UI state.
    @ObservationIgnored private var backgroundLoadObservations: [NSKeyValueObservation] = []

    /// Starts mirroring `webView`'s `url`/`title`/`isLoading` into the tab.
    /// Call right after attaching a webview that will load in the background;
    /// `WebViewWrapper` tears it down on adoption (its coordinator takes
    /// over the same properties — double KVO would race the two writers).
    func beginBackgroundLoadObservation() {
        endBackgroundLoadObservation()
        guard let webView else { return }
        backgroundLoadObservations = [
            webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                let url = webView.url
                Task { @MainActor in
                    guard let self, let url else { return }
                    self.url = url
                }
            },
            webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                let title = webView.title
                Task { @MainActor in
                    guard let self, let title, !title.isEmpty else { return }
                    self.title = title
                }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
                let loading = webView.isLoading
                Task { @MainActor in
                    self?.isLoading = loading
                }
            },
        ]
    }

    /// Stops the background mirroring. Safe to call when none is active;
    /// called on wrapper adoption, sleep, and close so the coordinator's own
    /// KVO (or teardown) never coexists with these observers.
    func endBackgroundLoadObservation() {
        for observation in backgroundLoadObservations {
            observation.invalidate()
        }
        backgroundLoadObservations = []
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
        // Tabs showing an internal cherry:// page keep their covered site's
        // WKWebView alive so Back can restore it with history intact —
        // sleeping would destroy exactly that preserved state.
        guard !isSleeping, !showHomePage, internalPage == nil else { return }
        sleepURL = url
        isSleeping = true
        // Release the WebView to free memory (a never-displayed background
        // research tab may still be mirroring it — stop that first).
        endBackgroundLoadObservation()
        webView = nil
    }

    func wake() {
        guard isSleeping else { return }
        isSleeping = false
        lastActiveDate = Date()
        // No load here: `webView` is nil after sleep, so when the woken tab
        // is displayed WebViewWrapper.makeNSView creates a fresh webview and
        // performs the (single) load of `url` itself — issuing a delayed
        // load here as well double-loaded the page. A woken tab that is
        // never displayed simply keeps its restored `url` until it is.
        if let savedURL = sleepURL {
            url = savedURL
            sleepURL = nil
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

