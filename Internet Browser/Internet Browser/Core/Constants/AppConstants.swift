//
//  AppConstants.swift
//  Internet Browser
//

import SwiftUI

enum AppConstants {
    static let appName = "Cherry"
    static let defaultHomePage = "https://www.google.com"
    static let newTabPage = "about:blank"

    enum Search {
        static let defaultEngine = SearchEngine.google
        static let googleURL = "https://www.google.com/search?q="
        static let duckDuckGoURL = "https://duckduckgo.com/?q="
        static let bingURL = "https://www.bing.com/search?q="
    }

    enum UI {
        static let tabBarHeight: CGFloat = 38
        static let navigationBarHeight: CGFloat = 44
        static let minTabWidth: CGFloat = 120
        static let maxTabWidth: CGFloat = 240
        static let tabCornerRadius: CGFloat = 8
        static let toolbarIconSize: CGFloat = 16
    }

    enum Colors {
        static var accent: Color { Color(hex: SettingsManager.shared.accentColorHex) }
        static var accentBlue: Color { Color(hex: SettingsManager.shared.accentColorHex) }
    }
}

enum SearchEngine: String, CaseIterable, Identifiable {
    case google = "Google"
    case duckDuckGo = "DuckDuckGo"
    case bing = "Bing"
    case ecosia = "Ecosia"
    case brave = "Brave"

    var id: String { rawValue }

    var searchURL: String {
        switch self {
        case .google: return "https://www.google.com/search?q="
        case .duckDuckGo: return "https://duckduckgo.com/?q="
        case .bing: return "https://www.bing.com/search?q="
        case .ecosia: return "https://www.ecosia.org/search?q="
        case .brave: return "https://search.brave.com/search?q="
        }
    }

    var suggestionsURL: String? {
        switch self {
        case .google: return "https://suggestqueries.google.com/complete/search?client=firefox&q="
        case .duckDuckGo: return "https://duckduckgo.com/ac/?q="
        default: return nil
        }
    }
}
