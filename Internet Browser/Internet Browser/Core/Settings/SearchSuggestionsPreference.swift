//
//  SearchSuggestionsPreference.swift
//  Cherry Browser
//

import Foundation
import Observation

/// Whether Cherry may send what you type in the address bar to a search
/// engine's suggestion endpoint.
///
/// Turning this off makes the omnibox strictly local: no request is built and
/// none is sent, so suggestions come only from your own history. On (the
/// default) it queries the SELECTED engine — never a hard-coded one.
@Observable
final class SearchSuggestionsPreference {
    static let shared = SearchSuggestionsPreference()

    private enum Keys {
        static let sendSearchSuggestions = "sendSearchSuggestions"
    }

    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Keys.sendSearchSuggestions) }
    }

    private init() {
        // Defaults to on: it's what the omnibox already did, minus the privacy
        // bug of always asking Google.
        isEnabled = UserDefaults.standard.object(forKey: Keys.sendSearchSuggestions) as? Bool ?? true
    }
}
