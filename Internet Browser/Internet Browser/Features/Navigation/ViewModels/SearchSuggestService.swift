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

        // Debounce the Google suggest request
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

    private func matchHistory(query: String) -> [SuggestionItem] {
        let lowered = query.lowercased()
        let matches = HistoryRepository.shared.searchHistory(query: query)

        // Deduplicate by host+path, prefer higher visit count
        var seen = Set<String>()
        var results: [SuggestionItem] = []

        for item in matches {
            let key = item.url.absoluteString.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)

            // Skip if the URL exactly matches the query (user is already typing it)
            if item.url.absoluteString.lowercased() == lowered { continue }

            results.append(.history(title: item.title, url: item.url))
            if results.count >= 4 { break }
        }

        return results
    }

    @MainActor
    private func performFetch(query: String, historyMatches: [SuggestionItem]) async {
        guard !looksLikeURL(query) else {
            // For URLs, only show history matches
            suggestions = historyMatches
            return
        }

        fetchTask?.cancel()
        isLoading = true

        fetchTask = Task {
            defer { Task { @MainActor in self.isLoading = false } }

            guard let encoded = query.addingPercentEncoding(withAllowedCharacters: URL.urlQueryValueAllowed),
                  let url = URL(string: "https://suggestqueries.google.com/complete/search?client=firefox&q=\(encoded)") else {
                return
            }

            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard !Task.isCancelled else { return }

                if let json = try JSONSerialization.jsonObject(with: data) as? [Any],
                   json.count >= 2,
                   let results = json[1] as? [String] {
                    let maxSearch = 8 - historyMatches.count
                    let searchItems = results.prefix(maxSearch).map { SuggestionItem.search(text: $0) }
                    await MainActor.run {
                        self.suggestions = historyMatches + searchItems
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
            }
        }
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
