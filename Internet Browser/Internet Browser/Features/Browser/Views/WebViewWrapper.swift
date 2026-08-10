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
        // Ad blocker state — used for the fresh configuration below and for
        // the coordinator's cosmetic-filter tracking on both paths.
        let adBlockActive = Self.adBlockActive(for: tab.url)

        // A tab that already has a webView keeps it (adopted popup or a
        // background research tab); everything else gets a fresh
        // CherryWebView (right-click Inspect support).
        let isAdoptedWebView = tab.webView != nil

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
            // The adopted webview's own configuration (a research tab's seed
            // config, a popup's opener-derived one) never went through the
            // fresh-path setup below, so without this it would permanently
            // lack DevTools capture, password autofill, and per-frame mute.
            Self.installCoreUserContent(
                into: webView.configuration.userContentController,
                coordinator: context.coordinator,
                isPrivate: tab.isPrivate,
                isMuted: tab.isMuted
            )
        } else {
            webView = makeFreshWebView(context: context, settings: settings, adBlockActive: adBlockActive)
        }

        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator

        // Re-apply the tab's muted state to the freshly (re)created WebView —
        // the JS-side mute state lives in the page's document, so it's lost
        // on sleep/wake and any other webView recreation.
        tab.applyMuteState()
        // Same story for page zoom: `pageZoom` belongs to the WKWebView, so a
        // 150%-zoomed tab would snap back to 100% on sleep/wake or Home
        // without this. The level itself lives on the Tab.
        tab.applyZoomLevel()

        // Enable Safari Web Inspector attachment (Develop > Show Web Inspector in menu bar)
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }

        context.coordinator.webView = webView
        context.coordinator.tab = tab
        context.coordinator.cosmeticAdBlockEnabled = adBlockActive

        context.coordinator.observeWebView(webView)

        if isAdoptedWebView {
            // An adopted web view (a popup carrying its opener's configuration,
            // or a background research tab built by TabManager) never went
            // through the fresh-configuration path, so it can be missing the
            // ad-block and cookie rule lists entirely. Attach the current set.
            context.coordinator.rebuildContentRuleLists()
        }

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

    /// Builds, configures, and attaches a fresh `CherryWebView` for a tab
    /// that has no webview yet.
    private func makeFreshWebView(context: Context, settings: SettingsManager, adBlockActive: Bool) -> WKWebView {
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

        // Network-level rule lists: ad-block (unless off or paused here) plus
        // the cookie policy, installed as one set by the single function that
        // owns them. Only applied at webview creation — NOT in updateNSView,
        // to prevent reload loops; later arrivals come via
        // `cherryContentRuleListsChanged`.
        Self.applyContentRuleLists(to: configuration, pageURL: tab.url)

        // Cosmetic filtering: inject CSS + JS scripts to hide ad DOM elements
        if adBlockActive {
            AdBlockManager.shared.applyCosmeticRules(to: configuration)
        }

        // Core page plumbing (password autofill, devtools bridges, per-frame
        // mute) — shared with the adopted-webview path in makeNSView.
        Self.installCoreUserContent(
            into: configuration.userContentController,
            coordinator: context.coordinator,
            isPrivate: tab.isPrivate,
            isMuted: tab.isMuted
        )

        let cherry = CherryWebView(frame: .zero, configuration: configuration)
        cherry.allowsBackForwardNavigationGestures = true
        cherry.allowsMagnification = true
        cherry.onFocused = onFocused
        cherry.tabID = tab.id
        tab.webView = cherry
        return cherry
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.tab = tab
        context.coordinator.viewModel = viewModel
        context.coordinator.onNewTabWithWebView = onNewTabWithWebView
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

    // MARK: - Content rule lists

    /// Installs exactly the content rule lists a page at `pageURL` should be
    /// carrying: the ad-block lists, unless blocking is off globally or paused
    /// for that site, plus the cookie policy list.
    ///
    /// **This is the only function in the app that touches the rule-list set.**
    /// Rule lists can only be removed wholesale, so a caller that removes them
    /// and re-adds only its own concern drops somebody else's — which is how
    /// the per-site ad-block pause used to wipe the cookie policy.
    ///
    /// Deliberately *static, idempotent, and derived entirely from current
    /// state*, with no notion of an owning coordinator. The previous version
    /// let the first coordinator to see a controller claim it through a weak
    /// map, which failed open twice: when that coordinator deallocated the
    /// entry became nobody's and the controller froze at whatever was attached
    /// at the time, and while it lived it decided the policy for every other
    /// tab sharing the controller. Any caller may now run this at any time and
    /// the result is the same.
    ///
    /// `pageURL == nil` (a tab that has not committed a URL) is treated as
    /// "protect it": the per-site pause is an opt-out and must never be
    /// inferred from missing information.
    static func applyContentRuleLists(to configuration: WKWebViewConfiguration, pageURL: URL?) {
        configuration.userContentController.removeAllContentRuleLists()
        if adBlockActive(for: pageURL), AdBlockManager.shared.rulesReady {
            AdBlockManager.shared.applyRules(to: configuration)
        }
        CookiePolicyManager.shared.apply(to: configuration)
    }

    /// Whether ad blocking applies to a page at `pageURL`, right now.
    ///
    /// The single expression of that decision — used when a web view is built,
    /// when a navigation commits, and when the settings change — so those three
    /// can never disagree about the same page.
    ///
    /// `nil` means protected. A per-site pause is an opt-out the user made for
    /// a specific site; it must never be inferred from a URL we don't have.
    static func adBlockActive(for pageURL: URL?) -> Bool {
        let settings = SettingsManager.shared
        guard settings.adBlockEnabled else { return false }
        guard let pageURL else { return true }
        return !settings.isAdBlockPaused(for: pageURL)
    }

    /// Everything that determines which lists a page gets: the blocking
    /// decision plus the identity of each manager's currently compiled set.
    /// Equal signatures mean an identical install, so the rebuild can be
    /// skipped — and any real change (a pause, a policy switch, a list
    /// finishing its compile) changes it.
    static func contentRuleListSignature(for pageURL: URL?) -> String {
        "\(adBlockActive(for: pageURL))"
            + "|\(AdBlockManager.shared.generation)"
            + "|\(CookiePolicyManager.shared.generation)"
    }

    // MARK: - Core user scripts / message handlers

    /// Handler names the core scripts post to — one list so registration and
    /// the remove-before-add guard in `installCoreUserContent` can't drift.
    private static let coreMessageHandlerNames = [
        "cherryPasswordDetect", "cherryPasswordCapture",
        "cherryConsole", "cherryNetwork", "cherryMuteFrame",
    ]

    /// Content controllers that already carry the core user scripts. Unlike
    /// message handlers, user scripts can't be removed by name, so installing
    /// onto a controller that already has them — a re-adopted webview, or a
    /// popup whose configuration shares its opener's controller — would
    /// inject every script twice into every page.
    private static let coreScriptedControllers = NSHashTable<WKUserContentController>.weakObjects()

    /// Installs the core user scripts + message handlers onto `controller`,
    /// routing messages to `coordinator`. Shared by the fresh-configuration
    /// path and webview adoption. Safe to call repeatedly: handlers are
    /// remove-then-add (a duplicate `add` throws, and re-adoption must
    /// re-route messages from a stale coordinator to the current one);
    /// scripts are added once per controller.
    static func installCoreUserContent(
        into controller: WKUserContentController,
        coordinator: Coordinator,
        isPrivate: Bool,
        isMuted: Bool
    ) {
        for name in coreMessageHandlerNames {
            controller.removeScriptMessageHandler(forName: name)
        }
        // Password auto-fill is skipped in private mode (no capture, no save
        // prompts on private pages), matching the scripts below.
        if !isPrivate {
            controller.add(coordinator, name: "cherryPasswordDetect")
            controller.add(coordinator, name: "cherryPasswordCapture")
        }
        controller.add(coordinator, name: "cherryConsole")
        controller.add(coordinator, name: "cherryNetwork")
        controller.add(coordinator, name: "cherryMuteFrame")

        if !coreScriptedControllers.contains(controller) {
            coreScriptedControllers.add(controller)
            addCoreUserScripts(to: controller, isPrivate: isPrivate, isMuted: isMuted)
        }
    }

    /// Adds the always-on user scripts. Also used by the coordinator to
    /// re-install after `removeAllUserScripts` (ad-block live toggle).
    static func addCoreUserScripts(
        to controller: WKUserContentController,
        isPrivate: Bool,
        isMuted: Bool
    ) {
        // Password auto-fill: form detection + capture (skip in private mode)
        if !isPrivate {
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

        // Developer Tools: console bridge + XHR/fetch network interceptor.
        // Also a permissive TrustedTypePolicy so the Elements editor can
        // apply HTML changes on TT-enforcing sites (Google, YouTube, etc.)
        controller.addUserScript(WKUserScript(
            source: ConsoleScripts.devToolsPolicyScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false   // iframes too, so nested elements are inspectable
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

        // Global Privacy Control: a document-start property on `navigator`,
        // in every frame, so third-party scripts see the signal too.
        if SettingsManager.shared.sendGlobalPrivacyControl {
            controller.addUserScript(WKUserScript(
                source: PrivacySignalScripts.globalPrivacyControlScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            ))
        }

        // Tab mute: install the media-muting observer into every frame on
        // each page load. The tab's current mute state is baked into the
        // script so cross-origin iframes (which evaluateJavaScript cannot
        // reach) mute themselves; the live main-frame value is also pushed
        // via tab.applyMuteState() and on every navigation (didCommit).
        controller.addUserScript(WKUserScript(
            source: MuteScripts.installScript(muted: isMuted),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandler {
        // Every reference back toward the window's object graph is weak: the
        // webView's userContentController retains this coordinator (script
        // message handlers), and viewModel → tabManager → tab → webView closes
        // the loop — so a strong reference to any of viewModel/tab/webView
        // here would keep a closed window's entire tab/webview graph alive
        // for the process lifetime (closing a window never nils tab.webView).
        weak var viewModel: BrowserViewModel?
        weak var webView: WKWebView?
        weak var tab: Tab?
        /// The wrapper's popup-adoption callback, stored directly instead of
        /// the wrapper struct itself (whose stored properties are strong).
        /// Its capture of the view model is weak on the BrowserView side.
        var onNewTabWithWebView: ((WKWebView, URL?) -> Void)?
        var lastLoadedURL: URL?
        /// URL of the PDF currently rendered in the viewer (set after didFinish)
        var displayedPDFURL: URL?
        /// Tracks whether cosmetic ad blocking is currently active for this web view
        var cosmeticAdBlockEnabled: Bool = false
        /// Cookie policy this web view's rule lists were built for, so a change
        /// in Settings can be detected and re-applied to a live tab.
        var appliedCookiePolicy: CookieBlockingLevel = SettingsManager.shared.blockCookies
        /// Same, for the GPC signal — whose user script also has to be
        /// rebuilt, not just reloaded, when the setting changes.
        var appliedGlobalPrivacyControl: Bool = SettingsManager.shared.sendGlobalPrivacyControl
        /// Set when a cookie-policy change is waiting for its rule list to
        /// finish compiling; the reload happens when the list arrives.
        private var reloadWhenRuleListsChange = false
        private var observations: [NSKeyValueObservation] = []
        private var progressThrottleTask: Task<Void, Never>?
        private var settingsObservation: (any NSObjectProtocol)?
        private var ruleListObservation: (any NSObjectProtocol)?
        /// Maps URL string -> DevTools network entry key for main-frame navigation timing
        private var pendingNetworkKeys: [String: String] = [:]

        init(_ parent: WebViewWrapper) {
            self.viewModel = parent.viewModel
            self.tab = parent.tab
            self.onNewTabWithWebView = parent.onNewTabWithWebView
            super.init()

            // Observe ad block setting changes via NotificationCenter on UserDefaults
            settingsObservation = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.applyLivePrivacySettings()
            }

            // Rule lists compile asynchronously. This web view may have been
            // built before its lists existed — a tab restored at launch always
            // is — so re-attach whenever a compiled list appears or changes.
            ruleListObservation = NotificationCenter.default.addObserver(
                forName: .cherryContentRuleListsChanged,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let kind = ContentRuleListKind.from(notification)
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.rebuildContentRuleLists()
                    // A policy change that was waiting for its list reloads
                    // HERE, once the list is actually attached — reloading at
                    // change time re-fetched the page under the old policy,
                    // because a main-actor hop always beats an out-of-process
                    // WebKit compile.
                    //
                    // Only the COOKIE list may consume that pending reload: an
                    // EasyList compile arriving first would otherwise clear the
                    // flag and reload under the old cookie policy — the same
                    // race, one level up.
                    if self.reloadWhenRuleListsChange, kind == .cookiePolicy {
                        self.reloadWhenRuleListsChange = false
                        self.tab?.reload()
                    }
                }
            }
        }

        deinit {
            if let obs = settingsObservation {
                NotificationCenter.default.removeObserver(obs)
            }
            if let obs = ruleListObservation {
                NotificationCenter.default.removeObserver(obs)
            }
        }

        /// The page this web view is actually showing.
        ///
        /// `webView.url` is WebKit's committed main-frame URL. `tab?.url` is
        /// written asynchronously by the KVO observer, so during a navigation
        /// it still holds the *previous* page — deriving blocking from it is
        /// exactly the staleness that let a paused site's decision follow the
        /// tab to the next site. It is only a fallback for a web view that has
        /// committed nothing yet.
        private var currentPageURL: URL? {
            webView?.url ?? tab?.url
        }

        /// Signature of the rule-list set currently installed, so an unchanged
        /// rebuild can be skipped.
        private var appliedRuleListSignature: String?

        /// Attaches exactly the content rule lists the page in this web view
        /// should be carrying right now.
        ///
        /// Skips the work when nothing that feeds the decision has changed:
        /// `didCommit` runs on every navigation, and the overwhelmingly common
        /// protected → protected case would otherwise pay a
        /// `removeAllContentRuleLists()` plus a re-add — two IPC round trips to
        /// the web process — for an identical result.
        func rebuildContentRuleLists() {
            guard let webView else { return }
            let pageURL = currentPageURL
            let signature = WebViewWrapper.contentRuleListSignature(for: pageURL)
            guard signature != appliedRuleListSignature else { return }
            appliedRuleListSignature = signature
            WebViewWrapper.applyContentRuleLists(to: webView.configuration, pageURL: pageURL)
        }

        /// Called when UserDefaults change — re-apply the privacy settings that
        /// have to reach web views that already exist.
        private func applyLivePrivacySettings() {
            guard let webView else { return }
            let settings = SettingsManager.shared
            // From the committed URL, like every other derivation — `tab?.url`
            // lags a navigation in progress.
            let shouldBeEnabled = WebViewWrapper.adBlockActive(for: currentPageURL)
            let cookiePolicy = settings.blockCookies
            let gpcEnabled = settings.sendGlobalPrivacyControl

            let adBlockChanged = shouldBeEnabled != cosmeticAdBlockEnabled
            let cookiePolicyChanged = cookiePolicy != appliedCookiePolicy
            let gpcChanged = gpcEnabled != appliedGlobalPrivacyControl
            guard adBlockChanged || cookiePolicyChanged || gpcChanged else { return }

            cosmeticAdBlockEnabled = shouldBeEnabled
            appliedCookiePolicy = cookiePolicy
            appliedGlobalPrivacyControl = gpcEnabled

            // Network-level rules. Turning "Block Ads & Trackers" off used to
            // toggle only the cosmetic CSS/JS, leaving the compiled block
            // rules attached — the switch said off while the blocker kept
            // blocking.
            if adBlockChanged || cookiePolicyChanged {
                rebuildContentRuleLists()
            }
            // A cookie-policy change reloads only once its list is actually in
            // place: reloading at change time (one main-actor hop) would beat
            // the compile (an out-of-process WebKit call) and re-fetch the page
            // under the OLD policy.
            //
            // The compile itself is NOT kicked off here: `blockCookies`'s
            // `didSet` already called `updatePolicy` synchronously before this
            // notification fanned out, and asking again from every open tab is
            // N-times-redundant work.
            var reloadNow = adBlockChanged || gpcChanged
            if cookiePolicyChanged {
                if CookiePolicyManager.shared.activeLevel == cookiePolicy {
                    // Already compiled and attached by the rebuild above —
                    // there is nothing to wait for. Arming the flag here would
                    // latch it until some unrelated cookie notification arrived.
                    reloadNow = true
                } else {
                    reloadWhenRuleListsChange = true
                }
            }

            if adBlockChanged {
                if shouldBeEnabled {
                    // Re-enable: inject CSS + JS on the current page
                    webView.evaluateJavaScript(AdBlockManager.cosmeticEnableJS(), completionHandler: nil)
                } else {
                    // Disable: remove style tag, disconnect observer, unhide elements on current page
                    webView.evaluateJavaScript(AdBlockManager.cosmeticDisableJS(), completionHandler: nil)
                }
            }

            // User scripts live on the content controller, not the document,
            // so a reload alone would NOT pick up a GPC or cosmetic-filter
            // change — the script set itself has to be rebuilt.
            if adBlockChanged || gpcChanged {
                rebuildUserScripts(adBlockActive: shouldBeEnabled)
            }

            // The page in front of the user was loaded under the old rules;
            // reload so what it shows matches what the switches now say. A
            // cookie change whose list is still compiling reloads later
            // instead, from the rule-list observer.
            if reloadNow {
                reloadWhenRuleListsChange = false
                Task { @MainActor in self.tab?.reload() }
            }
        }

        /// Rebuilds the whole user-script set: the always-on core scripts
        /// (password autofill, devtools bridges, GPC, mute) plus the cosmetic
        /// ad-block scripts when blocking is on.
        ///
        /// `WKUserContentController` can only remove scripts wholesale, so
        /// anything that changes one script has to re-add all of them —
        /// forgetting the others is how autofill and devtools used to stay
        /// broken until the tab was recreated.
        private func rebuildUserScripts(adBlockActive: Bool) {
            guard let webView else { return }
            let controller = webView.configuration.userContentController
            controller.removeAllUserScripts()
            WebViewWrapper.addCoreUserScripts(
                to: controller,
                isPrivate: tab?.isPrivate ?? false,
                isMuted: tab?.isMuted ?? false
            )
            if adBlockActive {
                AdBlockManager.shared.applyCosmeticRules(to: webView.configuration)
            }
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
                        // A failure surface owns the tab's address: WebKit
                        // reverts `webView.url` to the last committed page when
                        // a provisional navigation fails, and letting that
                        // write through would replace the address the user
                        // asked for with the one that happened to work last.
                        if let url, !tab.isShowingFailure {
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
                              // web view by closeInternalPage. A failure
                              // surface titles the tab after the host that
                              // failed, for the same reason: the tab strip
                              // must not advertise the last page that worked.
                              tab.internalPage == nil, !tab.isShowingFailure else { return }
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
                                self.viewModel?.isVideoFullscreen = true
                            case .inFullscreen:
                                self.viewModel?.isVideoFullscreen = true
                                // Reparenting is complete — expand to fill the window now.
                                self.expandViewsForVideoFullscreen(webView)
                            case .exitingFullscreen:
                                self.viewModel?.isVideoFullscreen = false
                            case .notInFullscreen:
                                self.viewModel?.isVideoFullscreen = false
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
            // A navigation that is NOT the retry of the failure on screen
            // replaces it immediately (the user typed something else, or a
            // link was followed). A retry keeps its surface up until it has
            // content to commit — see `didCommit`.
            if let tab, tab.isShowingFailure, !tab.isRetryingFailedLoad {
                tab.clearFailureState()
            }
            // If credentials were captured on the previous page, the navigation
            // confirms the login went through — show the save prompt now
            PasswordManager.shared.onNavigationAfterCapture()
            PasswordManager.shared.resetForNavigation()
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            // This coordinator is also the navigation delegate of any popup it
            // opens, until that popup's own tab adopts it. Everything below
            // mutates state belonging to *this* coordinator's tab and web view,
            // so a commit in someone else's web view must not reach it —
            // otherwise a popup's navigation would reset the opener's mute
            // frames and re-derive the opener's blocking from the popup's URL.
            guard webView === self.webView else { return }

            // Content is arriving, so whatever Cherry was drawing instead of
            // this page comes down now. Cleared HERE and not at
            // didStartProvisionalNavigation so a retry that fails again swaps
            // one failure surface for the next, with no blank frame between.
            tab?.clearFailureState()

            // Main-frame navigation invalidates previously-registered sub-frames;
            // drop them (iframes re-register as they load), then re-apply the
            // tab's mute state to the fresh main-frame JS context.
            tab?.resetMuteFrames()
            tab?.applyMuteState()

            // Re-derive blocking for the page that just committed. The set used
            // to be built only at web-view birth and on settings/compile
            // changes, so a tab that had been on an ad-block-paused site kept
            // blocking OFF for every site it navigated to next — while the
            // shield, which recomputes from the new URL, said "active". This is
            // the one place that knows a *different site* is now loaded.
            rebuildContentRuleLists()

            let adBlockActive = WebViewWrapper.adBlockActive(for: currentPageURL)
            if adBlockActive != cosmeticAdBlockEnabled {
                cosmeticAdBlockEnabled = adBlockActive
                rebuildUserScripts(adBlockActive: adBlockActive)
            }
            // No reload here, deliberately: rebuilding rule lists and user
            // scripts has no side effect on the load in progress, and reloading
            // from didCommit would loop.
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            tab?.isLoading = false
            tab?.loadingProgress = 1.0
            commitPendingCredentialSave(for: webView)
            fetchFavicon(for: webView)
            saveHistory(for: webView)

            // Track if we're displaying a PDF so the save button can appear
            let isPDF = webView.url?.pathExtension.lowercased() == "pdf"
            DispatchQueue.main.async { [weak self] in
                self?.viewModel?.isViewingPDF = isPDF
            }

            // If cosmetic ad blocking was re-enabled after scripts were removed,
            // the WKUserScripts may not be present. Run the JS directly as a fallback.
            if cosmeticAdBlockEnabled {
                webView.evaluateJavaScript(AdBlockManager.cosmeticEnableJS(), completionHandler: nil)
            }
        }

        private func saveHistory(for webView: WKWebView) {
            // Require a live, non-private tab. `tab` is weak now, so a nil tab
            // (deallocated mid-load, e.g. window closed) must NOT default to
            // "not private" — that would write a just-closed PRIVATE tab's URL
            // to persistent history. When the tab is gone, skip the write.
            guard let tab, !tab.isPrivate,
                  let url = webView.url,
                  url.scheme == "https" || url.scheme == "http" else { return }
            let title = webView.title ?? url.host ?? url.absoluteString
            HistoryRepository.shared.addHistoryItem(url: url, title: title, favicon: tab.favicon)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            handleNavigationFailure(error, in: webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            handleNavigationFailure(error, in: webView)
        }

        /// The single route from "WebKit said no" to something on screen.
        ///
        /// Both delegate callbacks land here because the distinction between
        /// them (did the navigation commit before it died?) changes nothing the
        /// user needs told: either way there is no page.
        private func handleNavigationFailure(_ error: Error, in webView: WKWebView) {
            // A popup this coordinator is still the delegate of is not this tab.
            guard webView === self.webView, let tab else { return }
            tab.isLoading = false

            // The certificate interstitial is already up for this tab. WebKit
            // fails the connection Cherry itself refused, and that -1202 must
            // not overwrite a screen that says something far more specific.
            guard tab.certificateWarning == nil else { return }

            let nsError = error as NSError
            // Declining the sign-in sheet is a decision, not a failure to
            // explain. Leave the tab on the page it was already showing.
            if nsError.domain == NSURLErrorDomain,
               nsError.code == NSURLErrorUserCancelledAuthentication {
                restoreAfterDeclinedAuthentication(webView)
                return
            }

            guard let failure = NavigationFailure.make(from: error, requestedURL: tab.url) else { return }
            // `webView.isLoading` is the discriminator between the two things
            // -999 means: a navigation already replaced this one (invisible),
            // or the user pressed Stop and nothing is running (a screen).
            guard !failure.isSilent(whileStillLoading: webView.isLoading) else { return }

            tab.showLoadFailure(failure)
            // Keep the coordinator's idea of what is loaded in step with the
            // tab's, or `updateNSView` sees a URL it has not loaded and
            // re-requests the address that just failed.
            lastLoadedURL = failure.url
        }

        /// Cancel on the authentication sheet leaves the tab where it was. A
        /// tab that had nowhere to be goes to the new-tab page rather than to a
        /// white rectangle.
        private func restoreAfterDeclinedAuthentication(_ webView: WKWebView) {
            guard let tab else { return }
            let current = webView.url?.absoluteString ?? ""
            guard current.isEmpty || current == "about:blank" else { return }
            if webView.canGoBack {
                webView.goBack()
            } else {
                tab.clearFailureState()
                tab.url = nil
                tab.title = "New Tab"
                tab.showHomePage = true
            }
        }

        // MARK: - Authentication challenges

        /// Certificates and HTTP authentication, which before this existed had
        /// no handler at all: an untrusted certificate failed into a blank tab,
        /// and a site behind HTTP basic auth was simply unreachable because
        /// there was nowhere in Cherry to type a user name.
        /// Deliberately the completion-handler spelling, not the `async` one
        /// this file uses everywhere else. WebKit decides whether to consult a
        /// navigation delegate about a challenge with `respondsToSelector:`,
        /// and the `async` overload was measured NOT to satisfy it: with it in
        /// place, `expired.badssl.com` never reached this method at all and
        /// failed straight through to a generic -1202. The two spellings are
        /// interchangeable for `decidePolicyFor`, which is why the rest of the
        /// file can use the nicer one; they are not interchangeable here.
        func webView(
            _ webView: WKWebView,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            switch challenge.protectionSpace.authenticationMethod {
            case NSURLAuthenticationMethodServerTrust:
                let outcome = handleServerTrust(challenge, in: webView)
                completionHandler(outcome.0, outcome.1)
            case NSURLAuthenticationMethodHTTPBasic,
                 NSURLAuthenticationMethodHTTPDigest,
                 NSURLAuthenticationMethodNTLM:
                Task { @MainActor in
                    let outcome = await self.handleHTTPAuthentication(challenge, in: webView)
                    completionHandler(outcome.0, outcome.1)
                }
            default:
                // Client certificates and anything else keep the behaviour they
                // had. Claiming to handle a method and then declining it is
                // worse than letting the system decline it.
                completionHandler(.performDefaultHandling, nil)
            }
        }

        /// Evaluates the server's chain ourselves, so a failure can be
        /// described rather than merely reported.
        ///
        /// A chain that evaluates cleanly goes to default handling: Cherry adds
        /// nothing to the trusted case and must not become the thing that
        /// decides it.
        private func handleServerTrust(
            _ challenge: URLAuthenticationChallenge,
            in webView: WKWebView
        ) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            guard let trust = challenge.protectionSpace.serverTrust else {
                return (.performDefaultHandling, nil)
            }
            if SecTrustEvaluateWithError(trust, nil) {
                return (.performDefaultHandling, nil)
            }

            let space = challenge.protectionSpace
            // A tab that has gone away is treated as private: an exception must
            // never be granted, or recorded, on behalf of a tab nobody can see.
            let isPrivate = tab?.isPrivate ?? true
            let key = CertificateExceptionStore.Key(host: space.host, port: space.port)

            if CertificateExceptionStore.shared.allows(key, isPrivate: isPrivate) {
                return (.useCredential, URLCredential(trust: trust))
            }

            guard let tab else { return (.cancelAuthenticationChallenge, nil) }

            let target = webView.url
                ?? tab.url
                ?? URL(string: "https://\(space.host)")
                ?? URL(fileURLWithPath: "/")
            tab.showCertificateWarning(
                CertificateWarning(
                    host: space.host,
                    port: space.port,
                    url: target,
                    problem: CertificateInspector.problem(with: trust, host: space.host),
                    certificateCommonName: CertificateInspector.commonName(of: trust),
                    isPrivate: isPrivate
                )
            )
            lastLoadedURL = target
            return (.cancelAuthenticationChallenge, nil)
        }

        /// Raises the sign-in sheet on this tab's own window and waits for it.
        private func handleHTTPAuthentication(
            _ challenge: URLAuthenticationChallenge,
            in webView: WKWebView
        ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            guard let tab, let viewModel else { return (.performDefaultHandling, nil) }
            let space = challenge.protectionSpace

            // A repeat challenge means the last answer was rejected, so the
            // credential that was about to be filed is not one worth filing.
            if challenge.previousFailureCount > 0 { pendingCredentialSave = nil }

            let target = webView.url
                ?? tab.url
                ?? URL(string: "\(space.protocol ?? "https")://\(space.host)")
                ?? URL(fileURLWithPath: "/")

            let answer = await withCheckedContinuation { (continuation: CheckedContinuation<HTTPAuthPrompt.Answer, Never>) in
                viewModel.pendingAuthPrompt = HTTPAuthPrompt(
                    host: space.host,
                    realm: space.realm,
                    previouslyFailed: challenge.previousFailureCount > 0,
                    isPrivate: tab.isPrivate,
                    url: target,
                    continuation: continuation
                )
            }
            viewModel.pendingAuthPrompt = nil

            switch answer {
            case .cancel:
                return (.cancelAuthenticationChallenge, nil)
            case .credential(let user, let password, let remember):
                if remember, !tab.isPrivate {
                    pendingCredentialSave = (url: target, user: user, password: password)
                }
                // A private tab's credential is not put in the process-wide
                // session credential store either: `.forSession` would leave it
                // reachable from normal windows for the rest of the run.
                let persistence: URLCredential.Persistence = tab.isPrivate ? .none : .forSession
                return (.useCredential, URLCredential(user: user, password: password, persistence: persistence))
            }
        }

        /// A credential the user asked Cherry to remember, held until the load
        /// it belongs to actually succeeds. Filing it at submit time would save
        /// every typo. Never set for a private tab.
        private var pendingCredentialSave: (url: URL, user: String, password: String)?

        /// Files the held credential once the authenticated page has loaded.
        private func commitPendingCredentialSave(for webView: WKWebView) {
            guard let pending = pendingCredentialSave else { return }
            pendingCredentialSave = nil
            guard let tab, !tab.isPrivate,
                  let loadedHost = webView.url?.host,
                  let pendingHost = pending.url.host,
                  HostNormalizer.foldedASCII(loadedHost) == HostNormalizer.foldedASCII(pendingHost)
            else { return }
            _ = PasswordRepository.shared.addCredential(
                url: pending.url.absoluteString,
                username: pending.user,
                password: pending.password
            )
        }

        /// WebKit prefers this overload when it exists, which is the point: it
        /// is the only hook that can push the "Enable JavaScript" setting into
        /// a web view that already exists. Read at construction time only, the
        /// setting silently kept its old value in every open tab.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            preferences: WKWebpagePreferences
        ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
            preferences.allowsContentJavaScript = SettingsManager.shared.enableJavaScript
            let policy = await self.webView(webView, decidePolicyFor: navigationAction)
            return (policy, preferences)
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

            // A port no browser will open. Caught HERE because WebKit's own
            // refusal happens below the navigation delegate: it produces no
            // error, calls nothing, and leaves the tab on about:blank with the
            // omnibox quietly rewritten. Refusing it ourselves is the only way
            // the user is told anything at all.
            if isMainFrame, let failure = NavigationFailure.blockedPortFailure(for: url) {
                tab?.showLoadFailure(failure)
                lastLoadedURL = url
                return .cancel
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
            // Read the tab's private flag now, not inside the panel callback:
            // `tab` is weak and the tab can be gone by the time the user picks
            // a location, and a nil tab must never default to "not private".
            let isPrivate = tab?.isPrivate ?? true
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
                manager.startDownload(
                    download,
                    suggestedFilename: saveURL.lastPathComponent,
                    sourceURL: sourceURL,
                    isPrivate: isPrivate
                )

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
                        // Private downloads get the quarantine bit but no
                        // origin: LaunchServices would otherwise log the URL
                        // to a permanent on-disk database.
                        manager.noteQuarantineResult(
                            id: itemID,
                            succeeded: DownloadQuarantine.apply(
                                to: saveURL,
                                sourceURL: download.originalRequest?.url,
                                isPrivate: manager.isPrivateDownload(id: itemID)
                            )
                        )
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
                self.viewModel?.isVideoFullscreen = true
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
                self.viewModel?.isVideoFullscreen = false
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

            // While an agent holds an action session for this tab, a popup that
            // no link and no form asked for is refused outright.
            //
            // This is not theoretical and the plan's claim about it was wrong.
            // `evaluateJavaScript` runs with a LIVE user gesture —
            // `navigator.userActivation.isActive` is true at the top of every
            // eval — so a synthesised click reaches `window.open` even with
            // `javaScriptCanOpenWindowsAutomatically` false. The popup arrives
            // here as `.other`, and the block below only refuses `.other` when
            // the popup blocker is on AND the URL looks like an ad, so an agent
            // click could open a real window over the user's browser. The gate
            // is narrow on purpose: an agent clicking a genuine
            // `<a target="_blank">` arrives as `.linkActivated` and still works.
            // `hasRecentSession`, not `hasLiveSession`: a `window.open` scheduled
            // by a `setTimeout` during a session is delivered after it, and a
            // gate keyed on liveness alone waved through exactly the popup it
            // exists to stop.
            if let tab = self.tab,
               WebActionSessionStore.shared.hasRecentSession(forTab: tab.id),
               !WebActionPopupPolicy.allowsPopup(navigationType: navigationAction.navigationType) {
                return nil
            }

            if SettingsManager.shared.blockPopups {
                let isUserInitiated = navigationAction.navigationType == .linkActivated ||
                    navigationAction.navigationType == .formSubmitted ||
                    navigationAction.navigationType == .formResubmitted

                if !isUserInitiated {
                    if let url, isLikelyAdPopup(url) {
                        DispatchQueue.main.async { [weak self] in
                            self?.viewModel?.popupBlockedCount += 1
                        }
                        return nil
                    }
                }
            }

            // Give the popup its OWN user-content controller before building
            // it. WebKit hands us a configuration derived from the opener, and
            // using that object is what preserves the opener relationship
            // (same process pool and data store, so `window.opener` and named
            // targets keep working) — but its `userContentController` is a
            // plain read-write property and nothing about `window.open`
            // requires the two pages to share one.
            //
            // Sharing it is what made rule lists ambiguous: one controller,
            // two tabs, two different sites, and only one per-site pause state
            // could win. With one controller per web view, "one web view, one
            // rule-list set" is true by construction and there is no ownership
            // to get wrong.
            configuration.userContentController = WKUserContentController()

            let popupWebView = WKWebView(frame: .zero, configuration: configuration)
            popupWebView.allowsBackForwardNavigationGestures = true
            popupWebView.allowsMagnification = true
            popupWebView.navigationDelegate = self
            popupWebView.uiDelegate = self

            // The popup starts loading before the tab adopts it, so set it up
            // now rather than at adoption — otherwise its first page load runs
            // with no blocking and no page plumbing at all.
            let isPrivate = tab?.isPrivate ?? true
            WebViewWrapper.installCoreUserContent(
                into: configuration.userContentController,
                coordinator: self,
                isPrivate: isPrivate,
                isMuted: tab?.isMuted ?? false
            )
            WebViewWrapper.applyContentRuleLists(to: configuration, pageURL: url)
            if WebViewWrapper.adBlockActive(for: url) {
                AdBlockManager.shared.applyCosmeticRules(to: configuration)
            }

            DispatchQueue.main.async { [weak self] in
                self?.onNewTabWithWebView?(popupWebView, url)
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

        /// The file chooser, gated.
        ///
        /// `click_element` already refuses a `role: "file"` element outright, so
        /// an agent cannot open a panel by clicking the input itself. This closes
        /// the OTHER route: a page's own button whose handler calls
        /// `fileInput.click()`. A synthesised click carries a live user gesture —
        /// `runOpenPanelWith` was measured firing from `evaluateJavaScript` — so
        /// without this a tool call could put a modal macOS panel over the user's
        /// browser with no user action behind it, and a modal panel is precisely
        /// the thing that stops the browser answering anything else.
        ///
        /// The cost, stated rather than buried: implementing this delegate method
        /// means Cherry owns file panels for every page, not only for pages under
        /// a session, and `WKOpenPanelParameters` does not expose the `accept`
        /// attribute — so the panel below cannot pre-filter by file type the way
        /// WebKit's own does. That is a real if small regression in exchange for
        /// closing the gate, and it is the reason this method exists at all.
        func webView(
            _ webView: WKWebView,
            runOpenPanelWith parameters: WKOpenPanelParameters,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping ([URL]?) -> Void
        ) {
            // `hasRecentSession` for the same reason the popup gate uses it: a
            // deferred `fileInput.click()` lands after the session it was
            // scheduled in.
            if let tab, WebActionSessionStore.shared.hasRecentSession(forTab: tab.id) {
                completionHandler(nil)
                return
            }
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            panel.canChooseDirectories = parameters.allowsDirectories
            panel.canChooseFiles = true
            panel.begin { response in
                completionHandler(response == .OK ? panel.urls : nil)
            }
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

            // Everything below is main-frame-only. `forMainFrameOnly: true` on
            // the injected scripts does NOT restrict the handlers: a
            // WKUserContentController message handler is reachable from every
            // frame in the page, including a cross-origin ad iframe, which can
            // post whatever it likes to `cherryPasswordDetect`.
            guard message.frameInfo.isMainFrame else { return }

            switch message.name {
            case "cherryPasswordDetect":
                // The origin comes from WebKit's own record of the frame, never
                // from `body["url"]` — that value is written by page script, so
                // a page could claim to be accounts.google.com and be offered
                // (one click from filling) the real Google credentials.
                if body["type"] as? String == "loginFormDetected",
                   let url = Self.trustedOrigin(of: message) {
                    Task { @MainActor in
                        PasswordManager.shared.onLoginFormDetected(url: url)
                    }
                }
            case "cherryPasswordCapture":
                // Same rule for capture: a page-supplied origin here would
                // file a credential the user typed on evil.com under a domain
                // evil.com doesn't own, poisoning later autofill.
                if body["type"] as? String == "credentialsCaptured",
                   let username = body["username"] as? String,
                   let password = body["password"] as? String,
                   let url = Self.trustedOrigin(of: message),
                   !(self.tab?.isPrivate ?? false) {
                    Task { @MainActor in
                        PasswordManager.shared.onCredentialsCaptured(
                            url: url.absoluteString,
                            username: username,
                            password: password
                        )
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

        /// The origin of the frame that sent `message`, taken from state only
        /// WebKit can set: the frame's security origin, falling back to the
        /// web view's committed URL. Returns `nil` for anything that isn't a
        /// normal http(s) page (about:blank, data:, a sandboxed frame with an
        /// opaque origin), so no credential is ever attributed to it.
        private static func trustedOrigin(of message: WKScriptMessage) -> URL? {
            let origin = message.frameInfo.securityOrigin
            let scheme = HostNormalizer.foldedASCII(origin.protocol)
            if scheme == "https" || scheme == "http", !origin.host.isEmpty {
                var components = URLComponents()
                components.scheme = scheme
                components.host = origin.host
                // WKSecurityOrigin reports 0 for the scheme's default port.
                if origin.port != 0 { components.port = Int(origin.port) }
                if let url = components.url { return url }
            }
            // Fallback: the committed page URL, reduced to a bare origin. The
            // full URL would carry the path and query into a saved credential
            // — some login flows put single-use tokens there.
            guard let pageURL = message.webView?.url,
                  let pageScheme = pageURL.scheme.map(HostNormalizer.foldedASCII),
                  pageScheme == "https" || pageScheme == "http",
                  let pageHost = pageURL.host, !pageHost.isEmpty else { return nil }
            var components = URLComponents()
            components.scheme = pageScheme
            components.host = pageHost
            components.port = pageURL.port
            return components.url
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
