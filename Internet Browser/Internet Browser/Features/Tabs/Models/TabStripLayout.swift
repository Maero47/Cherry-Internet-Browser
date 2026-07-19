//
//  TabStripLayout.swift
//  Internet Browser
//

import Foundation

/// One slot in a tab strip's regular (non-pinned) section: either a group's
/// persistent header pill or a visible tab. Both tab bars render the same
/// flattened sequence so the pill always sits at its group's position.
enum TabStripItem: Identifiable {
    case groupHeader(TabGroup)
    case tab(Tab)

    var id: UUID {
        switch self {
        case .groupHeader(let group): return group.id
        case .tab(let tab): return tab.id
        }
    }
}

enum TabStripLayout {
    /// Flattens `tabs` (in their existing order) into the items the regular
    /// section of a tab strip renders:
    ///
    /// - Every group that has at least one member gets exactly ONE header
    ///   pill, emitted at the position of the group's first member — so the
    ///   pill leads the group's run of tabs whether the group is expanded or
    ///   collapsed. For a non-contiguous group the pill marks the first
    ///   member; later scattered members stay where they are.
    /// - Tabs of a collapsed group are omitted (the pill alone represents
    ///   the group — the existing hide/show behavior).
    /// - Pinned tabs never appear as items (the pinned section renders them),
    ///   but they still count as members: a group whose first/only members
    ///   are pinned keeps its pill, otherwise a collapsed all-pinned group
    ///   could never be expanded again.
    static func regularItems(for tabs: [Tab]) -> [TabStripItem] {
        var items: [TabStripItem] = []
        var seenGroupIDs = Set<UUID>()

        for tab in tabs {
            if let group = tab.group, seenGroupIDs.insert(group.id).inserted {
                items.append(.groupHeader(group))
            }
            guard !tab.isPinned else { continue }
            if let group = tab.group, group.isCollapsed { continue }
            items.append(.tab(tab))
        }
        return items
    }
}
