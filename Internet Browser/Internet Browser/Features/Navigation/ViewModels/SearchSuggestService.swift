//
//  SearchSuggestService.swift
//  Internet Browser
//

import Foundation

enum SuggestionItem: Identifiable {
    case history(title: String, url: URL)
    case search(text: String)

    var id: String {
        switch self {
        case .history(_, let url): return "history:\(url.absoluteString)"
        case .search(let text): return "search:\(text)"
        }
    }

    var displayText: String {
        switch self {
        case .history(let title, let url):
            return title.isEmpty ? url.absoluteString : title
        case .search(let text):
            return text
        }
    }
}

@Observable
class SearchSuggestService {
    var suggestions: [SuggestionItem] = []
    var isLoading: Bool = false

    private var fetchTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?

    func fetch(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clear()
            return
        }

        // Show history matches immediately (no debounce)
        let historyMatches = matchHistory(query: trimmed)
        suggestions = historyMatches

        // "Don't send search suggestions" means exactly that: no request is
        // built, nothing is scheduled, nothing leaves the machine. Local
        // history matches are all you get.
        guard SearchSuggestionsPreference.shared.isEnabled else { return }

        // Debounce the suggest request to the SELECTED engine
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await performFetch(query: trimmed, historyMatches: historyMatches)
        }
    }

    func clear() {
        debounceTask?.cancel()
        fetchTask?.cancel()
        suggestions = []
        isLoading = false
    }

    /// How many history rows the omnibox will ever show. Unchanged — the
    /// difference is that these are now the best four rather than the first
    /// four the repository happened to hand back.
    private static let historySuggestionLimit = 4

    /// The address bar's history matches, best first.
    ///
    /// This used to take whatever order `searchHistory` returned — which is
    /// `historyItems` order, i.e. most-recently-visited-anything first — and
    /// keep the first four. So typing `git` offered whichever four pages
    /// containing "git" happened to have been visited last, and the site the
    /// user opens every morning could sit below a page they read once.
    ///
    /// Ordering, deduplication and the "you are already typing it" rule all
    /// live in `OmniboxRanking` now, which is pure and tested; the repository
    /// does the scan. See `OmniboxRanking.recencyHalfLifeDays` for the curve.
    private func matchHistory(query: String) -> [SuggestionItem] {
        HistoryRepository.shared
            .rankedSuggestions(query: query, limit: Self.historySuggestionLimit)
            .map { .history(title: $0.candidate.title, url: $0.candidate.url) }
    }

    @MainActor
    private func performFetch(query: String, historyMatches: [SuggestionItem]) async {
        guard !looksLikeURL(query) else {
            // For URLs, only show history matches
            suggestions = historyMatches
            return
        }

        // The engine the user actually chose. An engine with no suggestions
        // endpoint (Bing/Ecosia/Brave today) means local history only — it
        // must never quietly fall back to another engine's servers.
        guard let url = Self.suggestionsRequestURL(
            for: query,
            engine: SettingsManager.shared.searchEngine
        ) else {
            suggestions = historyMatches
            return
        }

        fetchTask?.cancel()
        isLoading = true

        fetchTask = Task {
            defer { Task { @MainActor in self.isLoading = false } }

            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard !Task.isCancelled else { return }

                let results = Self.parseSuggestions(from: data)
                guard !results.isEmpty else { return }

                let maxSearch = 8 - historyMatches.count
                let searchItems = results.prefix(maxSearch).map { SuggestionItem.search(text: $0) }
                await MainActor.run {
                    self.suggestions = historyMatches + searchItems
                }
            } catch {
                guard !Task.isCancelled else { return }
            }
        }
    }

    // MARK: - Endpoint & parsing
    //
    // Kept `static` and side-effect free so both halves are unit-testable
    // without a network round trip.

    /// The suggestions request for `query` against `engine`, or `nil` when that
    /// engine publishes no suggestions endpoint (`SearchEngine.suggestionsURL`).
    /// Returning `nil` is what keeps a DuckDuckGo/Brave user's keystrokes off
    /// Google's servers.
    static func suggestionsRequestURL(for query: String, engine: SearchEngine) -> URL? {
        guard let endpoint = engine.suggestionsURL,
              let encoded = query.addingPercentEncoding(withAllowedCharacters: URL.urlQueryValueAllowed)
        else { return nil }
        return URL(string: endpoint + encoded)
    }

    /// Reads the two suggestion payload shapes Cherry's engines return:
    ///
    /// * OpenSearch array — `["query", ["a", "b"], …]` (Google `client=firefox`)
    /// * phrase objects — `[{"phrase": "a"}, {"phrase": "b"}]` (DuckDuckGo `/ac/`)
    ///
    /// Anything else yields no suggestions rather than an error, so a changed
    /// payload degrades to history-only instead of breaking the omnibox.
    static func parseSuggestions(from data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }

        if let array = json as? [Any] {
            if array.count >= 2, let results = array[1] as? [String] {
                return results
            }
            if let objects = array as? [[String: Any]] {
                return objects.compactMap { $0["phrase"] as? String }
            }
        }
        return []
    }

    private func looksLikeURL(_ text: String) -> Bool {
        if text.contains(" ") { return false }
        if text.hasPrefix("http://") || text.hasPrefix("https://") { return true }
        if text.contains(".") {
            let parts = text.split(separator: ".")
            if parts.count >= 2, let last = parts.last, last.count >= 2 {
                return last.allSatisfy(\.isLetter)
            }
        }
        return false
    }
}
