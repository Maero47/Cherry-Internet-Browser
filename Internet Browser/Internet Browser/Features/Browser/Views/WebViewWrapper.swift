//
//  WebViewWrapper.swift
//  Internet Browser
//

import SwiftUI
import WebKit

// MARK: - CherryWebView (adds "Inspect Element" to the right-click context menu)

final class CherryWebView: WKWebView {
    private var lastRightClickLocation: CGPoint = .zero

    /// Fired when this web view becomes first responder or receives a
    /// mouseDown, so split view can focus the pane the user clicked INTO
    /// (not just its nav-bar chrome). `nil` outside split view, where
    /// there's nothing to switch focus to.
    var onFocused: (() -> Void)?

    /// The tab this web view belongs to. Kept in sync by `WebViewWrapper` so
    /// `cherryInspect` can tag the inspected element with the right pane's
    /// tab, regardless of which pane the user right-clicked into.
    var tabID: UUID?

    override func becomeFirstResponder() -> Bool {
        onFocused?()
        return super.becomeFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        onFocused?()
        super.mouseDown(with: event)
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        // Capture position before the menu opens
        lastRightClickLocation = convert(event.locationInWindow, from: nil)
        // WKWebView is a flipped view (y=0 at top), so no coordinate flip needed

        let item = NSMenuItem(
            title: "Inspect Element",
            action: #selector(cherryInspect),
            keyEquivalent: ""
        )
        item.target = self
        menu.addItem(.separator())
        menu.addItem(item)

        super.willOpenMenu(menu, with: event)
    }

    @objc private func cherryInspect() {
        let x = lastRightClickLocation.x
        let y = lastRightClickLocation.y

        let js = """
        (function(){
            var el=document.elementFromPoint(\(x),\(y));
            if(!el||el===document.documentElement||el===document.body)
                el=document.body||document.documentElement;
            function getPath(n){
                var path=[];
                while(n&&n.tagName&&n!==document.documentElement){
                    var seg=n.tagName.toLowerCase();
                    if(n.id){seg+='#'+n.id;path.unshift(seg);break;}
                    var sibs=Array.from(n.parentNode?n.parentNode.children:[]);
                    var same=sibs.filter(function(s){return s.tagName===n.tagName;});
                    if(same.length>1)seg+=':nth-of-type('+(same.indexOf(n)+1)+')';
                    path.unshift(seg);n=n.parentNode;
                }
                return path.join(' > ');
            }
            var cs=window.getComputedStyle(el);
            var props=['display','position','width','height',
                'margin-top','margin-right','margin-bottom','margin-left',
                'padding-top','padding-right','padding-bottom','padding-left',
                'color','background-color','font-size','font-family','font-weight',
                'border-top','border-radius','opacity','z-index','overflow',
                'flex','grid-template-columns','box-sizing','text-align',
                'line-height','letter-spacing','white-space','cursor'];
            var styles={};
            props.forEach(function(p){styles[p]=cs.getPropertyValue(p);});
            var attrs={};
            Array.from(el.attributes||[]).forEach(function(a){attrs[a.name]=a.value;});
            return JSON.stringify({
                tag:el.tagName.toLowerCase(),
                id:el.id||'',
                classes:typeof el.className==='string'?el.className:'',
                outerHTML:el.outerHTML.slice(0,10000),
                selector:getPath(el),
                styles:styles,
                attrs:attrs
            });
        })();
        """

        let inspectedTabID = tabID
        evaluateJavaScript(js) { result, _ in
            guard let jsonStr = result as? String,
                  let data    = jsonStr.data(using: .utf8),
                  let dict    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let inspectedTabID
            else { return }
            DispatchQueue.main.async {
                // Focus this pane BEFORE selecting the element, so the panel
                // (which shows the focused pane's tab) actually displays it.
                self.onFocused?()
                DevToolsManager.shared.selectElement(from: dict, tabID: inspectedTabID)
                // Open the dev tools panel if not already open
                NotificationCenter.default.post(name: .showConsole, object: nil)
            }
        }
    }
}

// MARK: - WebViewWrapper

struct WebViewWrapper: NSViewRepresentable {

    @Bindable var tab: Tab
    var urlVersion: Int = 0
    var onNewTab: ((URL) -> Void)? = nil
    var onNewTabWithWebView: ((WKWebView, URL?) -> Void)? = nil
    var viewModel: BrowserViewModel? = nil
    /// Same closure the pane's nav-bar tap uses to claim focus — passed
    /// through to `CherryWebView.onFocused` so clicking inside the page
    /// focuses the pane too. `nil` outside split view.
    var onFocused: (() -> Void)? = nil

    func makeNSView(context: Context) -> WKWebView {
        let settings = SettingsManager.shared
        let configuration = WKWebViewConfiguration()
        // Extensions never run in private/incognito tabs in v1a — there's no
        // per-extension "allow in private browsing" opt-in yet, so leaving the
        // controller unset here is what actually prevents content scripts from
        // running on private pages (ExtensionManager also excludes private
        // windows from every window/tab-enumeration API as a second layer).
        if !tab.isPrivate {
            configuration.webExtensionController = ExtensionManager.shared.controller
        }
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = !settings.blockPopups
        // Enable video Picture-in-Picture. On macOS the public
        // `WKWebViewConfiguration.allowsPictureInPictureMediaPlayback` is iOS-only,
        // but the underlying WKPreferences flag is settable via KVC and is REQUIRED —
        // without it `video.webkitSupportsPresentationMode('picture-in-picture')` is
        // false and `webkitSetPresentationMode(...)` is a silent no-op. This exact key
        // was verified against WKPreferences to be KVC-compliant (no exception) and to
        // flip PiP support on. See BrowserViewModel.togglePictureInPicture().
        configuration.preferences.setValue(true, forKey: "allowsPictureInPictureMediaPlayback")
        configuration.defaultWebpagePreferences.allowsContentJavaScript = settings.enableJavaScript

        // Use Safari user agent — WKWebView IS the Safari/WebKit engine, so this
        // matches the actual browser fingerprint. Using Chrome UA causes Cloudflare
        // and other bot detectors to see a fingerprint mismatch and enter infinite
        // challenge loops. Modern Safari UA is well-supported by all sites.
        configuration.applicationNameForUserAgent = "Version/18.3 Safari/605.1.15"

        if settings.httpsOnlyMode {
            configuration.upgradeKnownHostsToHTTPS = true
        }

        // Private browsing
        if tab.isPrivate {
            configuration.websiteDataStore = .nonPersistent()
        }

        // Ad blocker: apply network-level blocking rules
        // Only applied here in makeNSView — NOT in updateNSView to prevent reload loops
        let adBlockActive = settings.adBlockEnabled && !settings.isAdBlockPaused(for: tab.url)
        if adBlockActive {
            let adBlocker = AdBlockManager.shared
            if adBlocker.rulesReady {
                adBlocker.applyRules(to: configuration)
            }
            // Cosmetic filtering: inject CSS + JS scripts to hide ad DOM elements
            adBlocker.applyCosmeticRules(to: configuration)
        }

        // Password auto-fill: inject form detection + capture scripts (skip in private mode)
        if !tab.isPrivate {
            let controller = configuration.userContentController
            let detectScript = WKUserScript(
                source: PasswordAutoFillScripts.formDetectionScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
            let captureScript = WKUserScript(
                source: PasswordAutoFillScripts.credentialCaptureScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
            controller.addUserScript(detectScript)
            controller.addUserScript(captureScript)
            controller.add(context.coordinator, name: "cherryPasswordDetect")
            controller.add(context.coordinator, name: "cherryPasswordCapture")
        }

        // Developer Tools: inject console bridge + XHR/fetch network interceptor
        // Also register a permissive TrustedTypePolicy so the Elements editor can
        // apply HTML changes on TT-enforcing sites (Google, YouTube, etc.)
        let devController = configuration.userContentController
        devController.addUserScript(WKUserScript(
            source: ConsoleScripts.devToolsPolicyScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false   // iframes too, so nested elements are inspectable
        ))
        devController.addUserScript(WKUserScript(
            source: ConsoleScripts.consoleInterceptScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        devController.addUserScript(WKUserScript(
            source: ConsoleScripts.networkInterceptScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        devController.add(context.coordinator, name: "cherryConsole")
        devController.add(context.coordinator, name: "cherryNetwork")

        // Tab mute: install the media-muting observer into every frame on each
        // page load. The tab's current mute state is baked into the script so
        // cross-origin iframes (which evaluateJavaScript cannot reach) mute
        // themselves; the live main-frame value is also pushed via
        // tab.applyMuteState() below and on every navigation (Coordinator.didCommit).
        devController.addUserScript(WKUserScript(
            source: MuteScripts.installScript(muted: tab.isMuted),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        devController.add(context.coordinator, name: "cherryMuteFrame")

        // Check if the tab already has a webView (e.g. adopted popup)
        let isAdoptedWebView = tab.webView != nil

        // Use CherryWebView for new tabs (right-click Inspect support)
        // For adopted popups keep the existing WKWebView as-is
        let webView: WKWebView
        if isAdoptedWebView {
            webView = tab.webView!
            // A background research tab mirrored url/title/isLoading itself
            // while it had no wrapper; from here the coordinator's KVO below
            // owns those writes — never leave both observing.
            tab.endBackgroundLoadObservation()
            // Displaying an agent-opened result tab promotes it to a normal
            // user tab: drop the web-agent index cap so a later deliberate
            // research gather over it indexes the full page, not just the
            // first budgeted slice.
            tab.isWebResearchTab = false
        } else {
            let cherry = CherryWebView(frame: .zero, configuration: configuration)
            cherry.allowsBackForwardNavigationGestures = true
            cherry.allowsMagnification = true
            cherry.onFocused = onFocused
            cherry.tabID = tab.id
            tab.webView = cherry
            webView = cherry
        }

        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator

        // Re-apply the tab's muted state to the freshly (re)created WebView —
        // the JS-side mute state lives in the page's document, so it's lost
        // on sleep/wake and any other webView recreation.
        tab.applyMuteState()

        // Enable Safari Web Inspector attachment (Develop > Show Web Inspector in menu bar)
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }

        context.coordinator.webView = webView
        context.coordinator.tab = tab
        context.coordinator.cosmeticAdBlockEnabled = adBlockActive

        context.coordinator.observeWebView(webView)

        if !isAdoptedWebView {
            if let url = tab.url {
                if webView.url == nil {
                    webView.load(URLRequest(url: url))
                }
                context.coordinator.lastLoadedURL = webView.url ?? url
            }
        } else {
            context.coordinator.lastLoadedURL = webView.url
        }

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.tab = tab
        // Re-sync every render — split view can be toggled on/off, which
        // changes onFocusPane from nil to a live closure (or back), and a
        // stale closure captured only at makeNSView-time would miss that.
        (webView as? CherryWebView)?.onFocused = onFocused
        (webView as? CherryWebView)?.tabID = tab.id

        if let tabURL = tab.url {
            let lastURLString = context.coordinator.lastLoadedURL?.absoluteString ?? ""
            let newURLString = tabURL.absoluteString

            if lastURLString != newURLString
                && !webView.isLoading
                && webView.url?.absoluteString != newURLString {
                context.coordinator.lastLoadedURL = tabURL
                webView.load(URLRequest(url: tabURL))
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandler {
        var parent: WebViewWrapper
        // Weak: the webView's userContentController retains this coordinator
        // (script message handlers), so a strong reference here would create a
        // retain cycle that keeps every closed tab's WKWebView alive forever.
        weak var webView: WKWebView?
        var tab: Tab?
        var lastLoadedURL: URL?
        /// URL of the PDF currently rendered in the viewer (set after didFinish)
        var displayedPDFURL: URL?
        /// Tracks whether cosmetic ad blocking is currently active for this web view
        var cosmeticAdBlockEnabled: Bool = false
        private var observations: [NSKeyValueObservation] = []
        private var progressThrottleTask: Task<Void, Never>?
        private var settingsObservation: (any NSObjectProtocol)?
        /// Maps URL string -> DevTools network entry key for main-frame navigation timing
        private var pendingNetworkKeys: [String: String] = [:]

        init(_ parent: WebViewWrapper) {
            self.parent = parent
            self.tab = parent.tab
            super.init()

            // Observe ad block setting changes via NotificationCenter on UserDefaults
            settingsObservation = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.checkAdBlockStateChanged()
            }
        }

        deinit {
            if let obs = settingsObservation {
                NotificationCenter.default.removeObserver(obs)
            }
        }

        /// Called when UserDefaults change — check if ad block state differs and toggle cosmetic filtering
        private func checkAdBlockStateChanged() {
            guard let webView else { return }
            let settings = SettingsManager.shared
            let shouldBeEnabled = settings.adBlockEnabled && !settings.isAdBlockPaused(for: tab?.url)

            if shouldBeEnabled != cosmeticAdBlockEnabled {
                cosmeticAdBlockEnabled = shouldBeEnabled
                if shouldBeEnabled {
                    // Re-enable: inject CSS + JS on the current page
                    webView.evaluateJavaScript(AdBlockManager.cosmeticEnableJS(), completionHandler: nil)
                    // Add scripts back to the controller for future navigations
                    AdBlockManager.shared.applyCosmeticRules(to: webView.configuration)
                } else {
                    // Disable: remove style tag, disconnect observer, unhide elements on current page
                    webView.evaluateJavaScript(AdBlockManager.cosmeticDisableJS(), completionHandler: nil)
                    // Remove all user scripts so future navigations don't re-inject.
                    // WKUserContentController can only remove scripts wholesale,
                    // which also wipes the password autofill and devtools scripts —
                    // reinstall those or they stay broken until the tab is recreated.
                    let controller = webView.configuration.userContentController
                    controller.removeAllUserScripts()
                    reinstallCoreUserScripts(on: controller)
                }
            }
        }

        /// Re-adds the always-on user scripts (password autofill, devtools
        /// bridges) after removeAllUserScripts wiped them. Message handlers
        /// remain registered on the controller, only the scripts are gone.
        private func reinstallCoreUserScripts(on controller: WKUserContentController) {
            if !(tab?.isPrivate ?? false) {
                controller.addUserScript(WKUserScript(
                    source: PasswordAutoFillScripts.formDetectionScript,
                    injectionTime: .atDocumentEnd,
                    forMainFrameOnly: true
                ))
                controller.addUserScript(WKUserScript(
                    source: PasswordAutoFillScripts.credentialCaptureScript,
                    injectionTime: .atDocumentEnd,
                    forMainFrameOnly: true
                ))
            }
            controller.addUserScript(WKUserScript(
                source: ConsoleScripts.devToolsPolicyScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            ))
            controller.addUserScript(WKUserScript(
                source: ConsoleScripts.consoleInterceptScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
            controller.addUserScript(WKUserScript(
                source: ConsoleScripts.networkInterceptScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
            controller.addUserScript(WKUserScript(
                source: MuteScripts.installScript(muted: tab?.isMuted ?? false),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            ))
        }

        func observeWebView(_ webView: WKWebView) {
            observations.removeAll()

            observations.append(
                webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                    let url = webView.url
                    let canBack = webView.canGoBack
                    let canForward = webView.canGoForward
                    Task { @MainActor in
                        guard let self, let tab = self.tab else { return }
                        if let url {
                            self.lastLoadedURL = url
                            tab.url = url
                        }
                        // While an internal cherry:// page covers this (still
                        // live) web view, Back/Forward belong to the internal
                        // page, not the background site — don't clobber them.
                        guard tab.internalPage == nil else { return }
                        tab.canGoBack = canBack
                        tab.canGoForward = canForward
                    }
                }
            )

            observations.append(
                webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                    let title = webView.title
                    Task { @MainActor in
                        guard let tab = self?.tab,
                              // The tab is titled after the internal page
                              // while one is shown ("Settings" etc.); the
                              // covered site's title is restored from the
                              // web view by closeInternalPage.
                              tab.internalPage == nil else { return }
                        if let title, !title.isEmpty {
                            tab.title = title
                        }
                    }
                }
            )

            observations.append(
                webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
                    let loading = webView.isLoading
                    let canBack = webView.canGoBack
                    let canForward = webView.canGoForward
                    Task { @MainActor in
                        guard let self, let tab = self.tab else { return }
                        tab.isLoading = loading
                        // Same guard as the url observer: internal pages own
                        // the Back/Forward state while they're shown.
                        guard tab.internalPage == nil else { return }
                        tab.canGoBack = canBack
                        tab.canGoForward = canForward
                    }
                }
            )

            observations.append(
                webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
                    let progress = webView.estimatedProgress
                    if progress >= 1.0 {
                        self?.progressThrottleTask?.cancel()
                        Task { @MainActor in
                            self?.tab?.loadingProgress = 1.0
                        }
                        return
                    }
                    self?.progressThrottleTask?.cancel()
                    self?.progressThrottleTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        guard !Task.isCancelled else { return }
                        self?.tab?.loadingProgress = progress
                    }
                }
            )

            // macOS 13+: observe fullscreenState for granular enter/exit events.
            // .enteringFullscreen → hide chrome early (during animation).
            // .inFullscreen → animation complete, WKWebView is in fullscreen window;
            //                 this is the reliable moment to resize it.
            if #available(macOS 13.0, *) {
                observations.append(
                    webView.observe(\.fullscreenState, options: [.new]) { [weak self] webView, _ in
                        Task { @MainActor in
                            guard let self else { return }
                            switch webView.fullscreenState {
                            case .enteringFullscreen:
                                self.parent.viewModel?.isVideoFullscreen = true
                            case .inFullscreen:
                                self.parent.viewModel?.isVideoFullscreen = true
                                // Reparenting is complete — expand to fill the window now.
                                self.expandViewsForVideoFullscreen(webView)
                            case .exitingFullscreen:
                                self.parent.viewModel?.isVideoFullscreen = false
                            case .notInFullscreen:
                                self.parent.viewModel?.isVideoFullscreen = false
                            @unknown default:
                                break
                            }
                        }
                    }
                )
            }
        }

        // MARK: - WKNavigationDelegate

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            tab?.isLoading = true
            // If credentials were captured on the previous page, the navigation
            // confirms the login went through — show the save prompt now
            PasswordManager.shared.onNavigationAfterCapture()
            PasswordManager.shared.resetForNavigation()
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            // Main-frame navigation invalidates previously-registered sub-frames;
            // drop them (iframes re-register as they load), then re-apply the
            // tab's mute state to the fresh main-frame JS context.
            tab?.resetMuteFrames()
            tab?.applyMuteState()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            tab?.isLoading = false
            tab?.loadingProgress = 1.0
            fetchFavicon(for: webView)
            saveHistory(for: webView)

            // Track if we're displaying a PDF so the save button can appear
            let isPDF = webView.url?.pathExtension.lowercased() == "pdf"
            DispatchQueue.main.async { [weak self] in
                self?.parent.viewModel?.isViewingPDF = isPDF
            }

            // If cosmetic ad blocking was re-enabled after scripts were removed,
            // the WKUserScripts may not be present. Run the JS directly as a fallback.
            if cosmeticAdBlockEnabled {
                webView.evaluateJavaScript(AdBlockManager.cosmeticEnableJS(), completionHandler: nil)
            }
        }

        private func saveHistory(for webView: WKWebView) {
            if let url = webView.url,
               (url.scheme == "https" || url.scheme == "http"),
               !(tab?.isPrivate ?? false) {
                let title = webView.title ?? url.host ?? url.absoluteString
                HistoryRepository.shared.addHistoryItem(url: url, title: title, favicon: tab?.favicon)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            tab?.isLoading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            tab?.isLoading = false
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .allow }

            let scheme = url.scheme?.lowercased() ?? ""
            let isMainFrame = navigationAction.targetFrame?.isMainFrame == true
            let isNewWindow = navigationAction.targetFrame == nil

            // Non-standard schemes (tel:, mailto:, custom app schemes, etc.)
            // Only intercept on main-frame or new-window navigations.
            // Sub-frame navigations (iframes, media sources) must be left alone —
            // video players use blob:, data:, and other schemes internally.
            if isMainFrame || isNewWindow {
                if !["http", "https", "about", "file", "blob", "data"].contains(scheme) {
                    NSWorkspace.shared.open(url)
                    return .cancel
                }
            }

            // Download intent — only trigger for main-frame navigations.
            // Sub-frame video/audio sources sometimes set shouldPerformDownload but
            // must be rendered inline, not handed to the download manager.
            if isMainFrame && navigationAction.shouldPerformDownload {
                return .download
            }

            // New-window request with no target frame: let it through so
            // createWebViewWith can decide whether to open a tab or block it.
            if isNewWindow {
                return .allow
            }

            // Focus Mode: block main-frame navigations to blocked domains
            if isMainFrame,
               (scheme == "https" || scheme == "http"),
               let host = url.host,
               FocusModeManager.shared.isDomainBlocked(host) {
                let blockedURL = url
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .siteBlocked,
                        object: nil,
                        userInfo: ["host": host, "url": blockedURL.absoluteString]
                    )
                }
                return .cancel
            }

            // Track main-frame HTTP navigations for the network panel
            if isMainFrame, scheme == "https" || scheme == "http", let tabID = tab?.id {
                let method = navigationAction.request.httpMethod ?? "GET"
                let urlStr = url.absoluteString
                let key = DevToolsManager.shared.networkRequestStarted(url: urlStr, method: method, tabID: tabID)
                pendingNetworkKeys[urlStr] = key
            }

            return .allow
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
            if let response = navigationResponse.response as? HTTPURLResponse {
                let contentDisposition = response.value(forHTTPHeaderField: "Content-Disposition") ?? ""
                let mimeType = response.mimeType ?? ""

                // Finalize network entry for this main-frame response
                if let url = response.url {
                    let urlStr = url.absoluteString
                    if let key = pendingNetworkKeys.removeValue(forKey: urlStr) {
                        DevToolsManager.shared.networkRequestFinished(
                            key: key,
                            statusCode: response.statusCode,
                            mimeType: mimeType.isEmpty ? nil : mimeType,
                            isError: response.statusCode >= 400
                        )
                    }
                }

                let isAttachment = contentDisposition.lowercased().contains("attachment")
                let isRenderableMIME = [
                    "text/html", "text/plain", "application/xhtml+xml",
                    "application/pdf", "image/", "video/", "audio/"
                ].contains(where: { mimeType.lowercased().hasPrefix($0) })

                if isAttachment || (!navigationResponse.canShowMIMEType && !isRenderableMIME) {
                    return .download
                }
            }

            if !navigationResponse.canShowMIMEType {
                return .download
            }

            return .allow
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            download.delegate = self
            restorePageAfterDownload(webView)
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
            restorePageAfterDownload(webView)
        }

        private func restorePageAfterDownload(_ webView: WKWebView) {
            DispatchQueue.main.async { [weak self] in
                let currentURL = webView.url?.absoluteString ?? ""
                if currentURL.isEmpty || currentURL == "about:blank" {
                    if webView.canGoBack {
                        webView.goBack()
                    } else {
                        self?.tab?.showHomePage = true
                    }
                }
            }
        }

        // MARK: - WKDownloadDelegate

        private static var tempFileLocations: [Int: URL] = [:]
        private static var saveDestinations: [Int: URL] = [:]

        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = suggestedFilename
            panel.directoryURL = SettingsManager.shared.downloadDirectoryURL
            panel.canCreateDirectories = true
            panel.title = "Save Download"

            panel.begin { result in
                guard result == .OK, let saveURL = panel.url else {
                    completionHandler(nil)
                    return
                }

                let manager = DownloadManager.shared
                let sourceURL = download.originalRequest?.url ?? response.url
                manager.startDownload(download, suggestedFilename: saveURL.lastPathComponent, sourceURL: sourceURL)

                let tempDir = FileManager.default.temporaryDirectory
                let tempFile = tempDir.appendingPathComponent(UUID().uuidString + "_" + saveURL.lastPathComponent)
                Self.tempFileLocations[ObjectIdentifier(download).hashValue] = tempFile
                Self.saveDestinations[ObjectIdentifier(download).hashValue] = saveURL
                completionHandler(tempFile)
            }
        }

        func downloadDidFinish(_ download: WKDownload) {
            let manager = DownloadManager.shared
            guard let itemID = manager.itemID(for: download) else { return }
            let key = ObjectIdentifier(download).hashValue

            if let tempFile = Self.tempFileLocations[key] {
                if let saveURL = Self.saveDestinations[key] {
                    do {
                        if FileManager.default.fileExists(atPath: saveURL.path) {
                            try FileManager.default.removeItem(at: saveURL)
                        }
                        try FileManager.default.moveItem(at: tempFile, to: saveURL)
                        DownloadRepository.shared.completeDownload(id: itemID, filePath: saveURL.path)
                        manager.downloadDidCleanup(id: itemID)
                    } catch {
                        print("Failed to move downloaded file: \(error)")
                        manager.downloadDidFinish(id: itemID, at: tempFile, finalFilename: saveURL.lastPathComponent)
                    }
                    Self.saveDestinations.removeValue(forKey: key)
                } else {
                    let suggestedFilename = tempFile.lastPathComponent
                        .components(separatedBy: "_")
                        .dropFirst()
                        .joined(separator: "_")
                    let finalName = suggestedFilename.isEmpty ? tempFile.lastPathComponent : suggestedFilename
                    manager.downloadDidFinish(id: itemID, at: tempFile, finalFilename: finalName)
                }
                Self.tempFileLocations.removeValue(forKey: key)
            }
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            let manager = DownloadManager.shared
            guard let itemID = manager.itemID(for: download) else { return }
            manager.downloadDidFail(id: itemID, errorMessage: error.localizedDescription)
            let key = ObjectIdentifier(download).hashValue
            if let tempFile = Self.tempFileLocations[key] {
                try? FileManager.default.removeItem(at: tempFile)
                Self.tempFileLocations.removeValue(forKey: key)
            }
            Self.saveDestinations.removeValue(forKey: key)
        }

        // MARK: - WKUIDelegate

        // MARK: - Element / Video Fullscreen

        /// Saved browser-window frame when we expand it ourselves for fullscreen.
        var videoFullscreenSavedFrame: NSRect = .zero

        func webViewDidEnterFullscreen(_ webView: WKWebView) {
            Task { @MainActor in
                self.parent.viewModel?.isVideoFullscreen = true
            }
            // WebKit places the WKWebView in a screen-covering window but does NOT
            // resize the WKWebView itself — it stays at the original browser-content
            // position and size. Attempt the resize at t=0, 100 ms, and 350 ms so
            // we catch whichever moment the reparenting actually completes.
            for delay in [0.0, 0.1, 0.35] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak webView] in
                    guard let self, let webView else { return }
                    Task { @MainActor in self.expandViewsForVideoFullscreen(webView) }
                }
            }
        }

        @MainActor
        private func expandViewsForVideoFullscreen(_ webView: WKWebView) {
            guard let window = webView.window,
                  let screen = window.screen ?? NSScreen.main else { return }

            // If WebKit hasn't moved the webView into its fullscreen window yet,
            // the view is still in the small browser window — expand that window.
            if window.frame.width < screen.frame.width - 20 {
                if videoFullscreenSavedFrame == .zero {
                    videoFullscreenSavedFrame = window.frame
                }
                window.setFrame(screen.frame, display: true, animate: false)
            }

            guard let contentView = window.contentView else { return }
            let fill = contentView.bounds  // e.g. {0,0,2560,1600}

            // Walk every view from WKWebView up to (but not including) contentView
            // and expand it to fill the window. This unblocks any intermediate views
            // that would otherwise clip the WKWebView.
            var v: NSView = webView
            while v !== contentView {
                if abs(v.frame.width - fill.width) > 10 || abs(v.frame.height - fill.height) > 10 {
                    v.translatesAutoresizingMaskIntoConstraints = true
                    v.frame = fill
                    v.autoresizingMask = [.width, .height]
                }
                guard let sv = v.superview else { break }
                v = sv
            }

            // Tell page JS (YouTube player etc.) to recalculate for the new viewport.
            webView.evaluateJavaScript(
                "window.dispatchEvent(new Event('resize'))",
                completionHandler: nil
            )
        }

        func webViewDidExitFullscreen(_ webView: WKWebView) {
            Task { @MainActor in
                self.parent.viewModel?.isVideoFullscreen = false
                // Restore the browser window if we expanded it ourselves.
                guard videoFullscreenSavedFrame != .zero else { return }
                let saved = videoFullscreenSavedFrame
                videoFullscreenSavedFrame = .zero
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    webView.window?.setFrame(saved, display: true, animate: true)
                }
            }
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            let url = navigationAction.request.url

            if navigationAction.shouldPerformDownload || (url != nil && looksLikeDownloadURL(url!)) {
                webView.startDownload(using: navigationAction.request) { download in
                    download.delegate = self
                }
                return nil
            }

            if SettingsManager.shared.blockPopups {
                let isUserInitiated = navigationAction.navigationType == .linkActivated ||
                    navigationAction.navigationType == .formSubmitted ||
                    navigationAction.navigationType == .formResubmitted

                if !isUserInitiated {
                    if let url, isLikelyAdPopup(url) {
                        DispatchQueue.main.async { [weak self] in
                            self?.parent.viewModel?.popupBlockedCount += 1
                        }
                        return nil
                    }
                }
            }

            let popupWebView = WKWebView(frame: .zero, configuration: configuration)
            popupWebView.allowsBackForwardNavigationGestures = true
            popupWebView.allowsMagnification = true
            popupWebView.navigationDelegate = self
            popupWebView.uiDelegate = self

            DispatchQueue.main.async { [weak self] in
                self?.parent.onNewTabWithWebView?(popupWebView, url)
            }

            return popupWebView
        }

        private func isLikelyAdPopup(_ url: URL) -> Bool {
            let host = url.host?.lowercased() ?? ""
            let urlString = url.absoluteString.lowercased()

            let adDomains = [
                "doubleclick.net", "googlesyndication.com", "googleadservices.com",
                "googleads.g.doubleclick.net", "adservice.google.com",
                "facebook.com/tr", "ads.facebook.com", "an.facebook.com",
                "amazon-adsystem.com", "ads.yahoo.com", "ads.bing.com",
                "adnxs.com", "adsrvr.org", "pubmatic.com", "rubiconproject.com",
                "openx.net", "criteo.com", "taboola.com", "outbrain.com",
                "popads.net", "popcash.net", "propellerads.com", "adsterra.com",
                "exoclick.com", "juicyads.com", "clickadu.com", "hilltopads.com",
                "trafficjunky.com", "adcash.com", "revcontent.com", "mgid.com",
                "zergnet.com", "content.ad", "adblade.com",
                "serving-sys.com", "media.net", "adform.net", "adroll.com",
            ]

            for domain in adDomains {
                if host.contains(domain) || urlString.contains(domain) {
                    return true
                }
            }

            let adPatterns = [
                "/ads/", "/ad/click", "/ad/popup", "adserver", "adclick",
                "/popup", "/popunder", "clicktrack", "redirect.php",
                "/out/", "tracker.", "tracking.", "/afu.php",
                "exoclick", "juicyads", "/go/", "banners/",
            ]

            for pattern in adPatterns {
                if urlString.contains(pattern) {
                    return true
                }
            }

            if urlString.contains("utm_") && urlString.contains("click") {
                return true
            }

            return false
        }

        private func looksLikeDownloadURL(_ url: URL) -> Bool {
            let ext = url.pathExtension.lowercased()
            let downloadExtensions: Set<String> = [
                "zip", "gz", "tar", "rar", "7z", "bz2", "xz",
                "dmg", "pkg", "iso", "app",
                "exe", "msi", "deb", "rpm",
                "mp3", "wav", "aac", "flac", "m4a", "ogg",
                "mp4", "mov", "avi", "mkv", "webm", "flv",
                "apk", "ipa", "bin", "dat",
            ]
            return downloadExtensions.contains(ext)
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
            let alert = NSAlert()
            alert.messageText = message
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
            let alert = NSAlert()
            alert.messageText = message
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn
        }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
            let alert = NSAlert()
            alert.messageText = prompt
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")

            let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            textField.stringValue = defaultText ?? ""
            alert.accessoryView = textField

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                return textField.stringValue
            }
            return nil
        }

        // MARK: - WKScriptMessageHandler

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "cherryMuteFrame" {
                // A sub-frame installed the mute observer; record it so live
                // toggles can address it. Main frame is handled directly.
                let frame = message.frameInfo
                Task { @MainActor in
                    self.tab?.registerMuteFrame(frame)
                }
                return
            }

            guard let body = message.body as? [String: Any] else { return }

            switch message.name {
            case "cherryPasswordDetect":
                if body["type"] as? String == "loginFormDetected",
                   let urlString = body["url"] as? String,
                   let url = URL(string: urlString) {
                    Task { @MainActor in
                        PasswordManager.shared.onLoginFormDetected(url: url)
                    }
                }
            case "cherryPasswordCapture":
                if body["type"] as? String == "credentialsCaptured",
                   let username = body["username"] as? String,
                   let password = body["password"] as? String,
                   let url = body["url"] as? String,
                   !(self.tab?.isPrivate ?? false) {
                    Task { @MainActor in
                        PasswordManager.shared.onCredentialsCaptured(url: url, username: username, password: password)
                    }
                }
            case "cherryConsole":
                let levelStr = body["level"] as? String ?? "log"
                let message  = body["message"] as? String ?? ""
                let level    = ConsoleLevel(rawValue: levelStr) ?? .log
                guard let tabID = self.tab?.id else { return }
                let entry    = ConsoleEntry(level: level, message: message, tabID: tabID)
                Task { @MainActor in
                    DevToolsManager.shared.appendConsole(entry)
                }

            case "cherryNetwork":
                let type     = body["type"] as? String ?? "start"
                let url      = body["url"] as? String ?? ""
                let method   = body["method"] as? String ?? "GET"
                guard let tabID = self.tab?.id else { return }
                Task { @MainActor in
                    if type == "start" {
                        _ = DevToolsManager.shared.networkRequestStarted(url: url, method: method, tabID: tabID)
                    } else {
                        let status  = body["status"] as? Int ?? 0
                        let mime    = body["mimeType"] as? String
                        DevToolsManager.shared.finalizeByURL(
                            url: url, statusCode: status,
                            mimeType: mime, isError: status >= 400, tabID: tabID
                        )
                    }
                }

            default:
                break
            }
        }

        // MARK: - Helpers

        private func fetchFavicon(for webView: WKWebView) {
            let script = """
                (function() {
                    var icons = document.querySelectorAll('link[rel~="icon"]');
                    if (icons.length > 0) {
                        return icons[icons.length - 1].href;
                    }
                    return null;
                })();
            """

            webView.evaluateJavaScript(script) { [weak self] result, _ in
                let pageURL = webView.url
                guard let urlString = result as? String,
                      let url = URL(string: urlString) else {
                    if let faviconURL = webView.url?.faviconURL {
                        self?.downloadFavicon(from: faviconURL, pageURL: pageURL)
                    }
                    return
                }
                self?.downloadFavicon(from: url, pageURL: pageURL)
            }
        }

        /// `pageURL` is the page the icon belongs to, captured when the fetch
        /// starts — the tab may have navigated elsewhere by the time the
        /// download finishes, and the old page's icon must not be written
        /// onto the new page's saved bookmarks or shortcuts.
        private func downloadFavicon(from url: URL, pageURL: URL?) {
            Task {
                do {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    if let image = NSImage(data: data), image.size.width >= 1 {
                        await MainActor.run {
                            // Routes around an internal cherry:// page if one
                            // is covering the site (updates the parked icon
                            // instead of repainting the internal page's tab).
                            self.tab?.updateSiteFavicon(image)
                            // The real page icon also refreshes any saved
                            // bookmark or home-screen shortcut for this page.
                            if let pageURL = pageURL {
                                BookmarkRepository.shared.updateFavicon(forURL: pageURL, image: image)
                                ShortcutRepository.shared.updateFavicon(forURL: pageURL, image: image)
                            }
                        }
                    }
                } catch {
                    // Favicon fetch failed
                }
            }
        }
    }
}
