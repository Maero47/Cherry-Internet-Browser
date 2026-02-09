//
//  TabGroup.swift
//  Internet Browser
//

import SwiftUI
import Observation

enum TabGroupColor: String, CaseIterable, Identifiable {
    case red, orange, yellow, green, blue, purple, pink, gray

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
        }
    }

    var displayName: String {
        rawValue.capitalized
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
