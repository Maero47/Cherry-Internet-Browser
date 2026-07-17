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

    init(
        id: UUID = UUID(),
        name: String = "New Group",
        color: TabGroupColor = .blue,
        isCollapsed: Bool = false
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.isCollapsed = isCollapsed
    }

    var swiftUIColor: Color {
        color.color
    }
}

extension TabGroup {
    /// Derives an AI research group's name from the search query: whitespace
    /// collapsed, capped at `maxLength` characters — cut on a word boundary
    /// where one exists — with an ellipsis marking the cut.
    static func aiResearchName(for query: String, maxLength: Int = 24) -> String {
        let collapsed = query
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return "AI Research" }
        guard collapsed.count > maxLength else { return collapsed }
        var cut = String(collapsed.prefix(maxLength))
        if let lastSpace = cut.lastIndex(of: " "), lastSpace != cut.startIndex {
            cut = String(cut[..<lastSpace])
        }
        return cut + "…"
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
