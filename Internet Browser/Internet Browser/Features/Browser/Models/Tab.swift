//
//  Tab.swift
//  Internet Browser
//

import SwiftUI
import WebKit
import Observation

@Observable
final class Tab: Identifiable {
    let id: UUID
    var url: URL?
    var title: String
    var favicon: NSImage?
    var isLoading: Bool
    var loadingProgress: Double
    var canGoBack: Bool
    var canGoForward: Bool
    var isPinned: Bool
    var isMuted: Bool
    var showHomePage: Bool
    var webView: WKWebView?
    var group: TabGroup?
    var isSleeping: Bool
    var lastActiveDate: Date
    var isPrivate: Bool

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
        self.createdAt = Date()
        self.isSleeping = false
        self.lastActiveDate = Date()
        self.isPrivate = isPrivate
    }

    var displayTitle: String {
        if title.isEmpty {
            return url?.displayHost ?? "New Tab"
        }
        return title
    }

    var displayURL: String {
        url?.absoluteString ?? ""
    }

    private static let modernUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    func createWebView(configuration: WKWebViewConfiguration = WKWebViewConfiguration()) -> WKWebView {
        if let existing = webView {
            return existing
        }

        let wv = WKWebView(frame: .zero, configuration: configuration)
        wv.allowsBackForwardNavigationGestures = true
        wv.allowsMagnification = true
        wv.customUserAgent = Self.modernUserAgent
        self.webView = wv
        return wv
    }

    func loadURL(_ url: URL) {
        self.url = url
        self.showHomePage = false
        self.isSleeping = false
        self.lastActiveDate = Date()
        webView?.load(URLRequest(url: url))
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
        guard !isSleeping, !showHomePage else { return }
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

extension Tab: Equatable {
    static func == (lhs: Tab, rhs: Tab) -> Bool {
        lhs.id == rhs.id
    }
}

extension Tab: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
