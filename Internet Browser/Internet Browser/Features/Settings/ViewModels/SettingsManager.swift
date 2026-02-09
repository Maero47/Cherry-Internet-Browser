//
//  SettingsManager.swift
//  Cherry Browser
//

import SwiftUI
import Observation
import WebKit

enum CookieBlockingLevel: String, CaseIterable, Identifiable {
    case none = "Allow All"
    case thirdParty = "Block Third-Party"
    case all = "Block All"

    var id: String { rawValue }
}

@Observable
final class SettingsManager {
    static let shared = SettingsManager()

    // MARK: - General

    var searchEngine: SearchEngine {
        didSet { UserDefaults.standard.set(searchEngine.rawValue, forKey: Keys.searchEngine) }
    }

    var homepage: String {
        didSet { UserDefaults.standard.set(homepage, forKey: Keys.homepage) }
    }

    var showBookmarkBar: Bool {
        didSet { UserDefaults.standard.set(showBookmarkBar, forKey: Keys.showBookmarkBar) }
    }

    var useVerticalTabs: Bool {
        didSet { UserDefaults.standard.set(useVerticalTabs, forKey: Keys.useVerticalTabs) }
    }

    var verticalTabBarCollapsed: Bool {
        didSet { UserDefaults.standard.set(verticalTabBarCollapsed, forKey: Keys.verticalTabBarCollapsed) }
    }

    // MARK: - Privacy

    var blockCookies: CookieBlockingLevel {
        didSet {
            UserDefaults.standard.set(blockCookies.rawValue, forKey: Keys.blockCookies)
            applyCookiePolicy()
        }
    }

    var httpsOnlyMode: Bool {
        didSet { UserDefaults.standard.set(httpsOnlyMode, forKey: Keys.httpsOnlyMode) }
    }

    var sendDoNotTrack: Bool {
        didSet { UserDefaults.standard.set(sendDoNotTrack, forKey: Keys.sendDoNotTrack) }
    }

    var enableJavaScript: Bool {
        didSet { UserDefaults.standard.set(enableJavaScript, forKey: Keys.enableJavaScript) }
    }

    // MARK: - Tabs

    var tabSleepEnabled: Bool {
        didSet { UserDefaults.standard.set(tabSleepEnabled, forKey: Keys.tabSleepEnabled) }
    }

    var tabSleepTimeout: Int {
        didSet { UserDefaults.standard.set(tabSleepTimeout, forKey: Keys.tabSleepTimeout) }
    }

    // MARK: - Init

    private init() {
        let defaults = UserDefaults.standard

        // General
        if let engineRaw = defaults.string(forKey: Keys.searchEngine),
           let engine = SearchEngine(rawValue: engineRaw) {
            self.searchEngine = engine
        } else {
            self.searchEngine = .google
        }

        self.homepage = defaults.string(forKey: Keys.homepage) ?? AppConstants.defaultHomePage
        self.showBookmarkBar = defaults.object(forKey: Keys.showBookmarkBar) as? Bool ?? true
        self.useVerticalTabs = defaults.bool(forKey: Keys.useVerticalTabs)
        self.verticalTabBarCollapsed = defaults.bool(forKey: Keys.verticalTabBarCollapsed)

        // Privacy
        if let cookieRaw = defaults.string(forKey: Keys.blockCookies),
           let level = CookieBlockingLevel(rawValue: cookieRaw) {
            self.blockCookies = level
        } else {
            self.blockCookies = .none
        }

        self.httpsOnlyMode = defaults.bool(forKey: Keys.httpsOnlyMode)
        self.sendDoNotTrack = defaults.bool(forKey: Keys.sendDoNotTrack)
        self.enableJavaScript = defaults.object(forKey: Keys.enableJavaScript) as? Bool ?? true

        // Tabs
        self.tabSleepEnabled = defaults.object(forKey: Keys.tabSleepEnabled) as? Bool ?? true
        self.tabSleepTimeout = defaults.object(forKey: Keys.tabSleepTimeout) as? Int ?? 30
    }

    // MARK: - Cookie Policy

    func applyCookiePolicy() {
        let policy: HTTPCookie.AcceptPolicy
        switch blockCookies {
        case .none: policy = .always
        case .thirdParty: policy = .onlyFromMainDocumentDomain
        case .all: policy = .never
        }
        HTTPCookieStorage.shared.cookieAcceptPolicy = policy
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { _ in }
    }

    // MARK: - Clear Data

    func clearBrowsingData(history: Bool, cookies: Bool, cache: Bool, since: Date?) async {
        if history {
            await MainActor.run {
                if let date = since {
                    HistoryRepository.shared.clearHistory(since: date)
                } else {
                    HistoryRepository.shared.clearAllHistory()
                }
            }
        }

        var dataTypes: Set<String> = []
        if cookies {
            dataTypes.insert(WKWebsiteDataTypeCookies)
            dataTypes.insert(WKWebsiteDataTypeLocalStorage)
            dataTypes.insert(WKWebsiteDataTypeSessionStorage)
        }
        if cache {
            dataTypes.insert(WKWebsiteDataTypeDiskCache)
            dataTypes.insert(WKWebsiteDataTypeMemoryCache)
            dataTypes.insert(WKWebsiteDataTypeOfflineWebApplicationCache)
        }

        if !dataTypes.isEmpty {
            let date = since ?? Date.distantPast
            await WKWebsiteDataStore.default().removeData(
                ofTypes: dataTypes,
                modifiedSince: date
            )
        }
    }

    // MARK: - Keys

    private enum Keys {
        static let searchEngine = "searchEngine"
        static let homepage = "homepage"
        static let showBookmarkBar = "showBookmarkBar"
        static let useVerticalTabs = "useVerticalTabs"
        static let verticalTabBarCollapsed = "verticalTabBarCollapsed"
        static let blockCookies = "blockCookies"
        static let httpsOnlyMode = "httpsOnlyMode"
        static let sendDoNotTrack = "sendDoNotTrack"
        static let enableJavaScript = "enableJavaScript"
        static let tabSleepEnabled = "tabSleepEnabled"
        static let tabSleepTimeout = "tabSleepTimeout"
    }
}
