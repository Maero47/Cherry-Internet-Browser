//
//  URL+Extensions.swift
//  Internet Browser
//

import Foundation

extension URL {
    var isWebURL: Bool {
        guard let scheme = scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    var displayHost: String {
        host ?? absoluteString
    }

    var faviconURL: URL? {
        guard let scheme = scheme, let host = host else { return nil }
        return URL(string: "\(scheme)://\(host)/favicon.ico")
    }

    static func fromUserInput(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // Already a valid URL with scheme
        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }

        // Looks like a URL (contains dot, no spaces)
        if trimmed.contains(".") && !trimmed.contains(" ") {
            // Try with https first
            if let url = URL(string: "https://\(trimmed)") {
                return url
            }
        }

        return nil
    }

    /// Characters allowed unescaped inside a single query *value*.
    /// .urlQueryAllowed permits &, +, =, ?, # which corrupt the query
    /// (e.g. "fish & chips" truncates at &, "c++" turns + into spaces).
    static var urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&+=?#")
        return set
    }()

    static func searchURL(for query: String, engine: SearchEngine = .google) -> URL? {
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: urlQueryValueAllowed) ?? query
        return URL(string: engine.searchURL + encodedQuery)
    }
}

extension String {
    var isLikelyURL: Bool {
        let trimmed = self.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // Check for common URL patterns
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return true
        }

        // Check if it looks like a domain
        if trimmed.contains(".") && !trimmed.contains(" ") {
            let parts = trimmed.split(separator: ".")
            if parts.count >= 2 {
                let tld = String(parts.last ?? "")
                let commonTLDs = ["com", "org", "net", "edu", "gov", "io", "co", "app", "dev", "me", "info", "biz"]
                if commonTLDs.contains(tld) || tld.count == 2 { // 2-letter country codes
                    return true
                }
            }
        }

        // Check for localhost
        if trimmed.hasPrefix("localhost") {
            return true
        }

        return false
    }
}
