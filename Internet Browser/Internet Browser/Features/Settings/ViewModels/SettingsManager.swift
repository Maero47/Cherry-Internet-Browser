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

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var id: String { rawValue }
}

struct AccentColorOption: Identifiable {
    let name: String
    let hex: String
    var id: String { hex }
    var color: Color { Color(hex: hex) }

    static let options: [AccentColorOption] = [
        .init(name: "Cherry Red", hex: "DB283C"),
        .init(name: "Ocean Blue", hex: "2563EB"),
        .init(name: "Emerald", hex: "059669"),
        .init(name: "Purple", hex: "7C3AED"),
        .init(name: "Orange", hex: "EA580C"),
        .init(name: "Pink", hex: "DB2777"),
        .init(name: "Teal", hex: "0D9488"),
        .init(name: "Graphite", hex: "6B7280"),
    ]
}

enum HomepageTheme: String, CaseIterable, Identifiable {
    case cherry = "Cherry"
    case ocean = "Ocean"
    case forest = "Forest"
    case sunset = "Sunset"
    case purple = "Purple"
    case midnight = "Midnight"
    case rose = "Rose"
    case slate = "Slate"

    var id: String { rawValue }

    /// Returns 9 MeshGradient colors (3x3 grid) for the homepage background
    var gradientColors: [Color] {
        switch self {
        case .cherry:
            return [
                Color(red: 0.5, green: 0.0, blue: 0.1),
                Color(red: 0.6, green: 0.0, blue: 0.15),
                Color(red: 0.4, green: 0.0, blue: 0.2),
                Color(red: 0.35, green: 0.0, blue: 0.12),
                Color(red: 0.45, green: 0.0, blue: 0.12),
                Color(red: 0.45, green: 0.0, blue: 0.15),
                Color(red: 0.15, green: 0.0, blue: 0.08),
                Color(red: 0.2, green: 0.0, blue: 0.1),
                Color(red: 0.1, green: 0.0, blue: 0.05),
            ]
        case .ocean:
            return [
                Color(red: 0.0, green: 0.15, blue: 0.4),
                Color(red: 0.0, green: 0.2, blue: 0.5),
                Color(red: 0.0, green: 0.1, blue: 0.35),
                Color(red: 0.0, green: 0.12, blue: 0.35),
                Color(red: 0.0, green: 0.25, blue: 0.55),
                Color(red: 0.0, green: 0.18, blue: 0.45),
                Color(red: 0.0, green: 0.05, blue: 0.2),
                Color(red: 0.0, green: 0.08, blue: 0.25),
                Color(red: 0.0, green: 0.03, blue: 0.15),
            ]
        case .forest:
            return [
                Color(red: 0.0, green: 0.3, blue: 0.15),
                Color(red: 0.0, green: 0.35, blue: 0.18),
                Color(red: 0.0, green: 0.25, blue: 0.12),
                Color(red: 0.0, green: 0.22, blue: 0.1),
                Color(red: 0.05, green: 0.35, blue: 0.15),
                Color(red: 0.0, green: 0.28, blue: 0.14),
                Color(red: 0.0, green: 0.1, blue: 0.05),
                Color(red: 0.0, green: 0.15, blue: 0.08),
                Color(red: 0.0, green: 0.08, blue: 0.04),
            ]
        case .sunset:
            return [
                Color(red: 0.6, green: 0.2, blue: 0.0),
                Color(red: 0.7, green: 0.15, blue: 0.0),
                Color(red: 0.5, green: 0.1, blue: 0.1),
                Color(red: 0.55, green: 0.08, blue: 0.15),
                Color(red: 0.65, green: 0.12, blue: 0.05),
                Color(red: 0.5, green: 0.15, blue: 0.1),
                Color(red: 0.25, green: 0.05, blue: 0.1),
                Color(red: 0.3, green: 0.05, blue: 0.15),
                Color(red: 0.2, green: 0.02, blue: 0.08),
            ]
        case .purple:
            return [
                Color(red: 0.3, green: 0.0, blue: 0.5),
                Color(red: 0.35, green: 0.0, blue: 0.55),
                Color(red: 0.25, green: 0.0, blue: 0.45),
                Color(red: 0.2, green: 0.0, blue: 0.4),
                Color(red: 0.35, green: 0.05, blue: 0.55),
                Color(red: 0.28, green: 0.0, blue: 0.48),
                Color(red: 0.1, green: 0.0, blue: 0.2),
                Color(red: 0.15, green: 0.0, blue: 0.25),
                Color(red: 0.08, green: 0.0, blue: 0.15),
            ]
        case .midnight:
            return [
                Color(red: 0.08, green: 0.08, blue: 0.2),
                Color(red: 0.1, green: 0.1, blue: 0.25),
                Color(red: 0.06, green: 0.06, blue: 0.18),
                Color(red: 0.05, green: 0.08, blue: 0.18),
                Color(red: 0.12, green: 0.12, blue: 0.3),
                Color(red: 0.08, green: 0.1, blue: 0.22),
                Color(red: 0.02, green: 0.02, blue: 0.08),
                Color(red: 0.04, green: 0.04, blue: 0.12),
                Color(red: 0.01, green: 0.01, blue: 0.06),
            ]
        case .rose:
            return [
                Color(red: 0.55, green: 0.1, blue: 0.3),
                Color(red: 0.6, green: 0.08, blue: 0.35),
                Color(red: 0.45, green: 0.05, blue: 0.25),
                Color(red: 0.4, green: 0.08, blue: 0.28),
                Color(red: 0.55, green: 0.12, blue: 0.35),
                Color(red: 0.48, green: 0.08, blue: 0.3),
                Color(red: 0.2, green: 0.02, blue: 0.12),
                Color(red: 0.25, green: 0.04, blue: 0.15),
                Color(red: 0.15, green: 0.01, blue: 0.08),
            ]
        case .slate:
            return [
                Color(red: 0.2, green: 0.22, blue: 0.25),
                Color(red: 0.25, green: 0.27, blue: 0.3),
                Color(red: 0.18, green: 0.2, blue: 0.22),
                Color(red: 0.15, green: 0.17, blue: 0.2),
                Color(red: 0.22, green: 0.25, blue: 0.28),
                Color(red: 0.18, green: 0.2, blue: 0.24),
                Color(red: 0.08, green: 0.09, blue: 0.1),
                Color(red: 0.1, green: 0.11, blue: 0.13),
                Color(red: 0.06, green: 0.07, blue: 0.08),
            ]
        }
    }

    /// Preview color for the theme picker (center color of gradient)
    var previewColor: Color {
        gradientColors[4]
    }
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

    // MARK: - Theme

    var appearanceMode: AppearanceMode {
        didSet { UserDefaults.standard.set(appearanceMode.rawValue, forKey: Keys.appearanceMode) }
    }

    var accentColorHex: String {
        didSet { UserDefaults.standard.set(accentColorHex, forKey: Keys.accentColorHex) }
    }

    var homepageTheme: HomepageTheme {
        didSet { UserDefaults.standard.set(homepageTheme.rawValue, forKey: Keys.homepageTheme) }
    }

    var accentColor: Color {
        Color(hex: accentColorHex)
    }

    var resolvedColorScheme: ColorScheme? {
        switch appearanceMode {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    // MARK: - Privacy

    var adBlockEnabled: Bool {
        didSet { UserDefaults.standard.set(adBlockEnabled, forKey: Keys.adBlockEnabled) }
    }

    var adBlockWhitelistedDomains: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(adBlockWhitelistedDomains), forKey: Keys.adBlockWhitelistedDomains)
        }
    }

    func isAdBlockPaused(for url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        // Check both the full host and the base domain (e.g. www.example.com → example.com)
        let baseDomain = host.components(separatedBy: ".").suffix(2).joined(separator: ".")
        return adBlockWhitelistedDomains.contains(host) || adBlockWhitelistedDomains.contains(baseDomain)
    }

    func toggleAdBlockPause(for url: URL?) {
        guard let host = url?.host?.lowercased() else { return }
        let baseDomain = host.components(separatedBy: ".").suffix(2).joined(separator: ".")
        if adBlockWhitelistedDomains.contains(baseDomain) {
            adBlockWhitelistedDomains.remove(baseDomain)
        } else {
            adBlockWhitelistedDomains.insert(baseDomain)
        }
    }

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

        // Theme
        if let modeRaw = defaults.string(forKey: Keys.appearanceMode),
           let mode = AppearanceMode(rawValue: modeRaw) {
            self.appearanceMode = mode
        } else {
            self.appearanceMode = .system
        }
        self.accentColorHex = defaults.string(forKey: Keys.accentColorHex) ?? "DB283C"

        if let themeRaw = defaults.string(forKey: Keys.homepageTheme),
           let theme = HomepageTheme(rawValue: themeRaw) {
            self.homepageTheme = theme
        } else {
            self.homepageTheme = .cherry
        }

        // Privacy
        self.adBlockEnabled = defaults.object(forKey: Keys.adBlockEnabled) as? Bool ?? true
        let savedDomains = defaults.stringArray(forKey: Keys.adBlockWhitelistedDomains) ?? []
        self.adBlockWhitelistedDomains = Set(savedDomains)

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
        static let appearanceMode = "appearanceMode"
        static let accentColorHex = "accentColorHex"
        static let homepageTheme = "homepageTheme"
        static let adBlockEnabled = "adBlockEnabled"
        static let adBlockWhitelistedDomains = "adBlockWhitelistedDomains"
    }
}
