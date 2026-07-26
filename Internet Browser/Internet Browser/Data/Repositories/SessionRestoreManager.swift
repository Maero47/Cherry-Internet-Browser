//
//  SessionRestoreManager.swift
//  Cherry Browser
//

import Foundation

/// One saved tab entry — URL + display title + optional tab-group membership
/// and page zoom.
///
/// Both extras are Optional so sessions saved before they were persisted still
/// decode: Swift's synthesized decoder uses `decodeIfPresent` for Optional
/// properties, so an absent key yields `nil` rather than a thrown error (the
/// whole `loadSavedTabs` decode is all-or-nothing, so one missing key would
/// otherwise silently drop the entire saved session).
struct SavedTabEntry: Codable {
    let urlString: String
    let title: String
    var groupID: UUID? = nil
    /// `nil` means "was at 100%" — written only for a tab the user actually
    /// zoomed, so an un-zoomed session's JSON is byte-identical to before.
    var zoomLevel: Double? = nil
}

/// One saved tab group — enough to recreate it (name, color, collapsed state,
/// rename lock) on restore.
struct SavedTabGroup: Codable {
    let id: UUID
    let name: String
    let colorRawValue: String
    let isCollapsed: Bool
    /// Decoded leniently so sessions saved before the lock existed still load.
    var isLocked: Bool = false

    init(id: UUID, name: String, colorRawValue: String, isCollapsed: Bool, isLocked: Bool = false) {
        self.id = id
        self.name = name
        self.colorRawValue = colorRawValue
        self.isCollapsed = isCollapsed
        self.isLocked = isLocked
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        colorRawValue = try container.decode(String.self, forKey: .colorRawValue)
        isCollapsed = try container.decode(Bool.self, forKey: .isCollapsed)
        isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
    }
}

/// Persists and restores the browser session using UserDefaults (JSON blob).
/// Private tabs and home-page-only tabs (no URL) are excluded.
final class SessionRestoreManager {
    static let shared = SessionRestoreManager()

    private let tabsKey          = "sessionRestoreTabs"
    private let groupsKey        = "sessionRestoreGroups"
    private let selectedIndexKey = "sessionRestoreSelectedIndex"

    private init() {}

    // MARK: - Save

    func saveSession(tabs: [Tab], groups: [TabGroup], selectedIndex: Int?) {
        // selectedIndex refers to the full tabs array, but private and
        // URL-less tabs are excluded from the saved entries — map the index
        // into the filtered list so the correct tab is selected on restore.
        var entries: [SavedTabEntry] = []
        var mappedSelectedIndex = 0
        for (index, tab) in tabs.enumerated() {
            guard !tab.isPrivate,
                  let url = tab.url,
                  !url.absoluteString.isEmpty else { continue }
            if let selectedIndex, index == selectedIndex {
                mappedSelectedIndex = entries.count
            }
            entries.append(SavedTabEntry(
                urlString: url.absoluteString,
                title: tab.title,
                groupID: tab.group?.id,
                zoomLevel: tab.zoomLevel == PageZoom.defaultLevel ? nil : tab.zoomLevel
            ))
        }
        guard !entries.isEmpty else {
            clearSession()
            return
        }

        // Only persist groups that still have a surviving member — otherwise
        // private/URL-less tabs dropped above would leave orphaned empty groups.
        let referencedGroupIDs = Set(entries.compactMap { $0.groupID })
        let savedGroups = groups
            .filter { referencedGroupIDs.contains($0.id) }
            .map { SavedTabGroup(id: $0.id, name: $0.name, colorRawValue: $0.color.rawValue, isCollapsed: $0.isCollapsed, isLocked: $0.isLocked) }

        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: tabsKey)
        }
        if let data = try? JSONEncoder().encode(savedGroups) {
            UserDefaults.standard.set(data, forKey: groupsKey)
        }
        UserDefaults.standard.set(mappedSelectedIndex, forKey: selectedIndexKey)
        UserDefaults.standard.synchronize()
    }

    // MARK: - Load

    func loadSavedTabs() -> [SavedTabEntry] {
        guard let data = UserDefaults.standard.data(forKey: tabsKey),
              let entries = try? JSONDecoder().decode([SavedTabEntry].self, from: data)
        else { return [] }
        return entries
    }

    func loadSavedGroups() -> [SavedTabGroup] {
        guard let data = UserDefaults.standard.data(forKey: groupsKey),
              let groups = try? JSONDecoder().decode([SavedTabGroup].self, from: data)
        else { return [] }
        return groups
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
        UserDefaults.standard.removeObject(forKey: groupsKey)
        UserDefaults.standard.removeObject(forKey: selectedIndexKey)
    }
}
