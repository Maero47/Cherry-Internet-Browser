//
//  TabGroup.swift
//  Internet Browser
//

import SwiftUI
import Observation

enum TabGroupColor: String, CaseIterable, Identifiable {
    case red, orange, yellow, green, blue, purple, pink, gray
    /// Reserved for AI research groups — kept out of `userSelectable` so an
    /// AI-opened group is instantly recognizable and never collides with a
    /// color auto-assigned to a user's own group.
    case aiIndigo

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        case .pink: return .pink
        case .gray: return .gray
        // A violet-indigo distinct from both the system purple and blue above.
        case .aiIndigo: return Color(red: 0.45, green: 0.38, blue: 0.94)
        }
    }

    var displayName: String {
        self == .aiIndigo ? "AI" : rawValue.capitalized
    }

    /// The palette for user-created groups: every case except the reserved AI hue.
    static var userSelectable: [TabGroupColor] {
        allCases.filter { $0 != .aiIndigo }
    }
}

@Observable
final class TabGroup: Identifiable {
    let id: UUID
    var name: String
    var color: TabGroupColor
    var isCollapsed: Bool
    /// A locked group keeps its name forever — rename is rejected and the UI
    /// never offers an edit field. Used for AI research groups, which must
    /// always read "AI". An explicit flag (not `color == .aiIndigo`) so the
    /// rule survives session restore and any future color changes.
    let isLocked: Bool

    init(
        id: UUID = UUID(),
        name: String = "New Group",
        color: TabGroupColor = .blue,
        isCollapsed: Bool = false,
        isLocked: Bool = false
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.isCollapsed = isCollapsed
        self.isLocked = isLocked
    }

    var swiftUIColor: Color {
        color.color
    }
}

extension TabGroup: Equatable {
    static func == (lhs: TabGroup, rhs: TabGroup) -> Bool {
        lhs.id == rhs.id
    }
}

extension TabGroup: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
