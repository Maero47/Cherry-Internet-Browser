//
//  SessionRestoreManager.swift
//  Cherry Browser
//

import Foundation

/// One saved tab entry — URL + display title.
struct SavedTabEntry: Codable {
    let urlString: String
    let title: String
}

/// Persists and restores the browser session using UserDefaults (JSON blob).
/// Private tabs and home-page-only tabs (no URL) are excluded.
final class SessionRestoreManager {
    static let shared = SessionRestoreManager()

    private let tabsKey          = "sessionRestoreTabs"
    private let selectedIndexKey = "sessionRestoreSelectedIndex"

    private init() {}

    // MARK: - Save

    func saveSession(tabs: [Tab], selectedIndex: Int?) {
        let entries: [SavedTabEntry] = tabs.compactMap { tab in
            guard !tab.isPrivate,
                  let url = tab.url,
                  !url.absoluteString.isEmpty else { return nil }
            return SavedTabEntry(urlString: url.absoluteString, title: tab.title)
        }
        guard !entries.isEmpty else {
            clearSession()
            return
        }
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: tabsKey)
        }
        UserDefaults.standard.set(selectedIndex ?? 0, forKey: selectedIndexKey)
        UserDefaults.standard.synchronize()
    }

    // MARK: - Load

    func loadSavedTabs() -> [SavedTabEntry] {
        guard let data = UserDefaults.standard.data(forKey: tabsKey),
              let entries = try? JSONDecoder().decode([SavedTabEntry].self, from: data)
        else { return [] }
        return entries
    }

    func loadSelectedIndex() -> Int {
        UserDefaults.standard.integer(forKey: selectedIndexKey)
    }

    var hasSavedSession: Bool {
        UserDefaults.standard.data(forKey: tabsKey) != nil
    }

    // MARK: - Clear

    func clearSession() {
        UserDefaults.standard.removeObject(forKey: tabsKey)
        UserDefaults.standard.removeObject(forKey: selectedIndexKey)
    }
}
