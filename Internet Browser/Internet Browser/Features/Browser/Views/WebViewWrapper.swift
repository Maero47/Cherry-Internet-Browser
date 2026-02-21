//
//  WebViewWrapper.swift
//  Internet Browser
//

import SwiftUI
import WebKit

struct WebViewWrapper: NSViewRepresentable {
    @Bindable var tab: Tab
    var urlVersion: Int = 0
    var onNewTab: ((URL) -> Void)? = nil
    var onNewTabWithWebView: ((WKWebView, URL?) -> Void)? = nil
    var viewModel: BrowserViewModel? = nil

    func makeNSView(context: Context) -> WKWebView {
        let settings = SettingsManager.shared
        let configuration = WKWebViewConfiguration()
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = !settings.blockPopups
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

        // Check if the tab already has a webView (e.g. adopted popup)
        let isAdoptedWebView = tab.webView != nil

        let webView = tab.createWebView(configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator

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
        var webView: WKWebView?
        var tab: Tab?
        var lastLoadedURL: URL?
        /// URL of the PDF currently rendered in the viewer (set after didFinish)
        var displayedPDFURL: URL?
        /// Tracks whether cosmetic ad blocking is currently active for this web view
        var cosmeticAdBlockEnabled: Bool = false
        private var observations: [NSKeyValueObservation] = []
        private var progressThrottleTask: Task<Void, Never>?
        private var settingsObservation: (any NSObjectProtocol)?

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
                    // Remove all user scripts so future navigations don't re-inject
                    webView.configuration.userContentController.removeAllUserScripts()
                }
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
                        if let url {
                            self.lastLoadedURL = url
                            tab.url = url
                        }
                        tab.canGoBack = canBack
                        tab.canGoForward = canForward
                    }
                }
            )

            observations.append(
                webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                    let title = webView.title
                    Task { @MainActor in
                        if let title, !title.isEmpty {
                            self?.tab?.title = title
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
        }

        // MARK: - WKNavigationDelegate

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            tab?.isLoading = true
            // If credentials were captured on the previous page, the navigation
            // confirms the login went through — show the save prompt now
            PasswordManager.shared.onNavigationAfterCapture()
            PasswordManager.shared.resetForNavigation()
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
            if let url = navigationAction.request.url {
                let scheme = url.scheme?.lowercased() ?? ""

                if !["http", "https", "about", "file", "blob"].contains(scheme) {
                    NSWorkspace.shared.open(url)
                    return .cancel
                }

                if navigationAction.shouldPerformDownload {
                    return .download
                }

                if navigationAction.targetFrame == nil {
                    return .allow
                }
            }

            return .allow
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
            if let response = navigationResponse.response as? HTTPURLResponse {
                let contentDisposition = response.value(forHTTPHeaderField: "Content-Disposition") ?? ""
                let mimeType = response.mimeType ?? ""

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
                guard let urlString = result as? String,
                      let url = URL(string: urlString) else {
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
                    // Favicon fetch failed
                }
            }
        }
    }
}
