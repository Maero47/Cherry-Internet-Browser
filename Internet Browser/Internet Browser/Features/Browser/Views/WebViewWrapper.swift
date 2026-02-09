//
//  WebViewWrapper.swift
//  Internet Browser
//

import SwiftUI
import WebKit

struct WebViewWrapper: NSViewRepresentable {
    @Bindable var tab: Tab
    var urlVersion: Int = 0  // Forces updateNSView when URL changes

    func makeNSView(context: Context) -> WKWebView {
        let settings = SettingsManager.shared
        let configuration = WKWebViewConfiguration()
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        // Apply privacy settings
        configuration.defaultWebpagePreferences.allowsContentJavaScript = settings.enableJavaScript
        if settings.httpsOnlyMode {
            configuration.upgradeKnownHostsToHTTPS = true
        }

        // Private browsing — use non-persistent data store
        if tab.isPrivate {
            configuration.websiteDataStore = .nonPersistent()
        }

        // Apply ad blocker rules (skip for whitelisted domains)
        if settings.adBlockEnabled && !settings.isAdBlockPaused(for: tab.url) {
            AdBlockManager.shared.applyRules(to: configuration)
        }

        // Set modern user agent to get full website features
        configuration.applicationNameForUserAgent = "Safari/605.1.15"

        let webView = tab.createWebView(configuration: configuration)

        // Set custom user agent to appear as modern Safari
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator

        // Store references
        context.coordinator.webView = webView
        context.coordinator.tab = tab

        // Add observers for state changes
        context.coordinator.observeWebView(webView)

        // Load initial URL if present
        if let url = tab.url {
            webView.load(URLRequest(url: url))
            context.coordinator.lastLoadedURL = url
        }

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Update coordinator's tab reference
        context.coordinator.tab = tab

        // Check if we need to load a new URL
        if let tabURL = tab.url {
            let lastURLString = context.coordinator.lastLoadedURL?.absoluteString ?? ""
            let newURLString = tabURL.absoluteString

            // Only load if this is a different URL than what we last loaded
            if lastURLString != newURLString {
                context.coordinator.lastLoadedURL = tabURL
                webView.load(URLRequest(url: tabURL))
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: WebViewWrapper
        var webView: WKWebView?
        var tab: Tab?
        var lastLoadedURL: URL?
        private var observations: [NSKeyValueObservation] = []

        init(_ parent: WebViewWrapper) {
            self.parent = parent
            self.tab = parent.tab
        }

        func observeWebView(_ webView: WKWebView) {
            // Clear existing observations
            observations.removeAll()

            // Observe URL changes
            observations.append(
                webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                    Task { @MainActor in
                        if let url = webView.url {
                            self?.lastLoadedURL = url
                            self?.tab?.url = url
                        }
                    }
                }
            )

            // Observe title changes
            observations.append(
                webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                    Task { @MainActor in
                        if let title = webView.title, !title.isEmpty {
                            self?.tab?.title = title
                        }
                    }
                }
            )

            // Observe loading state
            observations.append(
                webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
                    Task { @MainActor in
                        self?.tab?.isLoading = webView.isLoading
                    }
                }
            )

            // Observe progress
            observations.append(
                webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
                    Task { @MainActor in
                        self?.tab?.loadingProgress = webView.estimatedProgress
                    }
                }
            )

            // Observe navigation state
            observations.append(
                webView.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
                    Task { @MainActor in
                        self?.tab?.canGoBack = webView.canGoBack
                    }
                }
            )

            observations.append(
                webView.observe(\.canGoForward, options: [.new]) { [weak self] webView, _ in
                    Task { @MainActor in
                        self?.tab?.canGoForward = webView.canGoForward
                    }
                }
            )
        }

        // MARK: - WKNavigationDelegate

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            tab?.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            tab?.isLoading = false
            tab?.loadingProgress = 1.0

            // Try to get favicon
            fetchFavicon(for: webView)

            // Save to history (skip in private browsing)
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
            // Handle special URL schemes
            if let url = navigationAction.request.url {
                let scheme = url.scheme?.lowercased() ?? ""

                // Open external apps for non-web URLs
                if !["http", "https", "about", "file"].contains(scheme) {
                    NSWorkspace.shared.open(url)
                    return .cancel
                }

                // Handle target="_blank" links - open in new tab
                if navigationAction.targetFrame == nil {
                    return .allow
                }

                // Add Do Not Track header if enabled
                if SettingsManager.shared.sendDoNotTrack {
                    var request = navigationAction.request
                    request.setValue("1", forHTTPHeaderField: "DNT")
                    // We can't modify the request directly, but the header is set via configuration
                }
            }

            return .allow
        }

        // MARK: - WKUIDelegate

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            // Handle popup windows - load in current tab for now
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
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

        // MARK: - Helpers

        private func fetchFavicon(for webView: WKWebView) {
            // Try to get favicon from the page
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
                guard let urlString = result as? String,
                      let url = URL(string: urlString) else {
                    // Fall back to /favicon.ico
                    if let faviconURL = webView.url?.faviconURL {
                        self?.downloadFavicon(from: faviconURL)
                    }
                    return
                }
                self?.downloadFavicon(from: url)
            }
        }

        private func downloadFavicon(from url: URL) {
            Task {
                do {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    if let image = NSImage(data: data) {
                        await MainActor.run {
                            self.tab?.favicon = image
                        }
                    }
                } catch {
                    // Favicon fetch failed - that's okay
                }
            }
        }
    }
}
