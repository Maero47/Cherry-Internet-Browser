//
//  AppConstants.swift
//  Internet Browser
//

import SwiftUI

enum AppConstants {
    static let appName = "Cherry"
    /// Seeds `SettingsManager.homepage` for a fresh install. Only used when the
    /// user turns on a custom homepage (`HomepagePreference`); Cherry's own
    /// new-tab page is Home by default.
    static let defaultHomePage = "https://www.google.com"

    enum UI {
        static let tabBarHeight: CGFloat = 38
        static let navigationBarHeight: CGFloat = 44
        static let minTabWidth: CGFloat = 120
        static let maxTabWidth: CGFloat = 240
        static let tabCornerRadius: CGFloat = 8
        static let toolbarIconSize: CGFloat = 16
    }

    /// The one shape every surface in the navigation bar's row is drawn as.
    ///
    /// The omnibox pill and the themed cluster surfaces are siblings on one
    /// line, and they only read as siblings if they share a height, a vertical
    /// centre and a corner. They did not: the omnibox was 28pt tall with a
    /// circular 8pt corner (its height falling out of its own vertical
    /// padding), while the cluster surface was 34pt with a CONTINUOUS 8pt
    /// corner (its height falling out of its own 3pt spread). Same centre,
    /// different everything else — which is why the row read as two surfaces
    /// that had been designed apart.
    ///
    /// So the numbers live here rather than in either view, and a surface that
    /// joins the row later inherits them instead of inventing its own.
    ///
    /// The values are the OMNIBOX's, deliberately: the pill is the oldest and
    /// most load-bearing surface in the row, it is the one the unthemed look
    /// shows, and adopting its geometry means this alignment costs the stock
    /// appearance nothing.
    ///
    /// The corner style is stated rather than left to default. It has to be:
    /// writing `.circular` here — which is what the documented default for
    /// `RoundedRectangle(cornerRadius:)` is — moved 120 pixels of the stock
    /// omnibox's antialiased rim, so the bare initialiser this row has always
    /// used is evidently resolving to `.continuous` on this SDK. Naming it
    /// pins the row to the curve it actually draws instead of to whichever one
    /// the default happens to mean.
    enum ToolbarSurface {
        static let height: CGFloat = 28
        static let cornerRadius: CGFloat = 8
        static let cornerStyle: RoundedCornerStyle = .continuous

        static var shape: RoundedRectangle {
            RoundedRectangle(cornerRadius: cornerRadius, style: cornerStyle)
        }
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
