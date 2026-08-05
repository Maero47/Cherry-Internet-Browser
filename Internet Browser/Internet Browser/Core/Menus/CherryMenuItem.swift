//
//  CherryMenuItem.swift
//  Cherry Browser
//

import SwiftUI

/// One row of a Cherry-drawn menu.
///
/// This is the model `CherryMenu` renders instead of handing the same rows to
/// `NSMenu`. It carries exactly what a menu row needs to be *drawn* and what
/// VoiceOver needs to *describe* it — title, symbol, enabled, checked,
/// destructive — because the whole point of drawing our own menus is that both
/// of those become ours rather than AppKit's.
struct CherryMenuItem: Identifiable {
    enum Kind {
        case action(() -> Void)
        case submenu([CherryMenuItem])
        /// A rule. Never highlighted, never focusable, skipped by ↑/↓.
        case separator
    }

    let id = UUID()
    var title: String
    var systemImage: String?
    /// A disabled row is drawn dimmed, is skipped by ↑/↓, does nothing on
    /// Return or click, and reads as unavailable to VoiceOver.
    var isEnabled: Bool
    /// Draws the checkmark column, and reads as "on" to VoiceOver. This is
    /// what `Toggle`-in-a-menu meant before the conversion.
    var isOn: Bool
    var isDestructive: Bool
    /// The tab-group colour dot, the one piece of non-text content any of
    /// Cherry's menus put in a row.
    var swatch: Color?
    var kind: Kind

    /// Whether ↑/↓ may land here, and whether Return or a click does anything.
    /// Separators and disabled rows are both excluded — the same rule `NSMenu`
    /// applies.
    var isSelectable: Bool {
        if case .separator = kind { return false }
        return isEnabled
    }

    var hasSubmenu: Bool {
        if case .submenu = kind { return true }
        return false
    }

    var submenuItems: [CherryMenuItem] {
        if case .submenu(let items) = kind { return items }
        return []
    }
}

extension CherryMenuItem {
    static func action(
        _ title: String,
        systemImage: String? = nil,
        enabled: Bool = true,
        on: Bool = false,
        destructive: Bool = false,
        swatch: Color? = nil,
        _ perform: @escaping () -> Void
    ) -> CherryMenuItem {
        CherryMenuItem(
            title: title, systemImage: systemImage, isEnabled: enabled, isOn: on,
            isDestructive: destructive, swatch: swatch, kind: .action(perform)
        )
    }

    static func submenu(
        _ title: String,
        systemImage: String? = nil,
        enabled: Bool = true,
        @CherryMenuBuilder items: () -> [CherryMenuItem]
    ) -> CherryMenuItem {
        let children = items()
        return CherryMenuItem(
            title: title, systemImage: systemImage,
            // A submenu with nothing in it can't be opened, so it is disabled
            // rather than a row that swallows Return silently.
            isEnabled: enabled && children.contains(where: \.isSelectable),
            isOn: false, isDestructive: false, swatch: nil,
            kind: .submenu(children)
        )
    }

    static var separator: CherryMenuItem {
        CherryMenuItem(
            title: "", systemImage: nil, isEnabled: false, isOn: false,
            isDestructive: false, swatch: nil, kind: .separator
        )
    }

    var isSeparator: Bool {
        if case .separator = kind { return true }
        return false
    }
}

/// Lets a menu be written the way the `NSMenu`-backed ones were — a list of
/// rows with `if` and `for` in it — so converting a call site is a change of
/// spelling, not a restructuring.
@resultBuilder
enum CherryMenuBuilder {
    static func buildBlock(_ parts: [CherryMenuItem]...) -> [CherryMenuItem] { parts.flatMap { $0 } }
    static func buildExpression(_ item: CherryMenuItem) -> [CherryMenuItem] { [item] }
    static func buildExpression(_ items: [CherryMenuItem]) -> [CherryMenuItem] { items }
    static func buildExpression(_ item: CherryMenuItem?) -> [CherryMenuItem] { item.map { [$0] } ?? [] }
    static func buildOptional(_ items: [CherryMenuItem]?) -> [CherryMenuItem] { items ?? [] }
    static func buildEither(first items: [CherryMenuItem]) -> [CherryMenuItem] { items }
    static func buildEither(second items: [CherryMenuItem]) -> [CherryMenuItem] { items }
    static func buildArray(_ items: [[CherryMenuItem]]) -> [CherryMenuItem] { items.flatMap { $0 } }
    static func buildLimitedAvailability(_ items: [CherryMenuItem]) -> [CherryMenuItem] { items }
}

extension Array where Element == CherryMenuItem {
    /// Drops separators that would draw against nothing — leading, trailing, or
    /// doubled — which is what happens whenever a conditional row is absent.
    /// `NSMenu` does not do this for you either, but the old call sites were
    /// built so it never showed; keeping the rule here means a new `if` cannot
    /// leave a stray rule behind.
    func tidiedSeparators() -> [CherryMenuItem] {
        var out: [CherryMenuItem] = []
        for item in self {
            if item.isSeparator {
                guard let last = out.last, !last.isSeparator else { continue }
            }
            out.append(item)
        }
        while let last = out.last, last.isSeparator { out.removeLast() }
        return out
    }
}
