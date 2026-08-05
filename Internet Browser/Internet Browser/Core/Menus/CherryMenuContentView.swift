//
//  CherryMenuContentView.swift
//  Cherry Browser
//

import SwiftUI
import AppKit

/// One open level of a menu: its rows and which of them is highlighted.
///
/// Shared between the AppKit side (which owns the panel, the keyboard and the
/// pointer) and the SwiftUI side (which draws). AppKit moves the highlight,
/// SwiftUI redraws.
@MainActor
@Observable
final class CherryMenuLevelModel {
    var items: [CherryMenuItem]
    var highlightedIndex: Int?
    /// The accent the highlight is filled with — `SettingsManager.accentColor`,
    /// the same value `CherryWindowRoot` puts in `.tint`. Passed in explicitly
    /// because a menu panel is its own window and inherits nothing from the
    /// window that opened it.
    var accent: Color

    init(items: [CherryMenuItem], accent: Color) {
        self.items = items
        self.accent = accent
    }
}

/// The menu itself. Drawing only — every interaction is handled in AppKit by
/// `CherryMenuHostView`, so this view installs no gestures and takes no focus.
struct CherryMenuContentView: View {
    @Bindable var model: CherryMenuLevelModel
    let maxHeight: CGFloat

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                row(item, index: index)
            }
        }
        .padding(.vertical, CherryMenuMetrics.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)

        Group {
            if CherryMenuLayout.contentHeight(of: model.items) > maxHeight {
                ScrollView(.vertical) { content }
            } else {
                content
            }
        }
        // The menu's material is an `NSVisualEffectView` *behind* this view
        // (see `CherryMenuHostView`), not a SwiftUI `.regularMaterial` here.
        // That is not a detail: SwiftUI blends content drawn on top of one of
        // its own materials, which turned a `#7C3AED` highlight into `#9059F1`
        // — the accent would have been followed but never actually matched,
        // and "follows the accent" has to survive being measured.
        .overlay {
            RoundedRectangle(cornerRadius: CherryMenuMetrics.menuCornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .tint(model.accent)
    }

    @ViewBuilder
    private func row(_ item: CherryMenuItem, index: Int) -> some View {
        if item.isSeparator {
            Divider()
                .frame(height: CherryMenuMetrics.separatorHeight)
                .padding(.horizontal, CherryMenuMetrics.horizontalInset + 6)
                .accessibilityHidden(true)
        } else {
            let isHighlighted = model.highlightedIndex == index
            let foreground = foregroundColor(for: item, highlighted: isHighlighted)

            HStack(spacing: 0) {
                ZStack {
                    if item.isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .frame(width: CherryMenuMetrics.stateColumnWidth, alignment: .leading)

                if let swatch = item.swatch {
                    Circle()
                        .fill(swatch)
                        .frame(width: 8, height: 8)
                        .padding(.trailing, 6)
                }

                if let symbol = item.systemImage {
                    Image(systemName: symbol)
                        .font(.system(size: 12))
                        .frame(width: CherryMenuMetrics.iconColumnWidth, alignment: .leading)
                }

                Text(item.title)
                    .font(.system(size: CherryMenuMetrics.fontSize))
                    .lineLimit(1)

                Spacer(minLength: CherryMenuMetrics.titleTrailingPadding)

                if item.hasSubmenu {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: CherryMenuMetrics.submenuChevronWidth, alignment: .trailing)
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, CherryMenuMetrics.rowHorizontalPadding)
            .frame(height: CherryMenuMetrics.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: CherryMenuMetrics.rowCornerRadius, style: .continuous)
                        .fill(model.accent)
                        .padding(.horizontal, CherryMenuMetrics.horizontalInset)
                }
            }
            // SwiftUI's own accessibility for these rows is switched off and
            // replaced by a real `NSView` per row (`CherryMenuItemAXView`), so
            // VoiceOver sees `AXMenuItem`s inside an `AXMenu` — the same tree
            // `NSMenu` publishes — rather than a stack of `AXButton`s.
            .accessibilityHidden(true)
            .overlay {
                CherryMenuItemAccessibility(item: item, isHighlighted: isHighlighted)
            }
        }
    }

    private func foregroundColor(for item: CherryMenuItem, highlighted: Bool) -> Color {
        if !item.isEnabled { return .primary.opacity(0.32) }
        if highlighted { return CherryMenuColors.foregroundOn(model.accent) }
        return item.isDestructive ? .red : .primary
    }
}

// MARK: - Accessibility

/// The accessibility element for one menu row.
///
/// A real `NSView` rather than SwiftUI accessibility modifiers because SwiftUI
/// cannot publish the `AXMenuItem` role, and the role is the difference between
/// VoiceOver saying "Duplicate Tab, menu item, 4 of 16" — what it says for the
/// menus this replaces — and "Duplicate Tab, button". It is laid out by SwiftUI
/// as an overlay on its row, so its frame tracks the row for free, and it never
/// takes the mouse.
final class CherryMenuItemAXView: NSView {
    var item: CherryMenuItem?
    var isHighlighted = false
    var onPress: (() -> Void)?

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .menuItem }
    /// Title, not label: `NSMenu` publishes its rows' text as `AXTitle`, and
    /// matching that is what makes an assistive client treat these rows the
    /// same way it treats the menus this replaces.
    override func accessibilityTitle() -> String? { item?.title }
    override func isAccessibilityEnabled() -> Bool { item?.isEnabled ?? false }
    override func isAccessibilitySelected() -> Bool { isHighlighted }
    override func accessibilityChildren() -> [Any]? { nil }

    /// What "and its state" means for a menu row: a checked row reads as on, an
    /// unchecked one as off, and a plain action row has no state to read.
    override func accessibilityValue() -> Any? {
        guard let item, !item.hasSubmenu else { return nil }
        return item.isOn ? 1 : nil
    }

    override func accessibilityRoleDescription() -> String? {
        item?.hasSubmenu == true ? "submenu" : NSAccessibility.Role.menuItem.description(with: nil)
    }

    override func accessibilityPerformPress() -> Bool {
        guard item?.isEnabled == true else { return false }
        onPress?()
        return true
    }

    /// Never in the way of the pointer: `CherryMenuHostView` does the hit
    /// testing, over the whole menu, from the row geometry.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct CherryMenuItemAccessibility: NSViewRepresentable {
    let item: CherryMenuItem
    let isHighlighted: Bool

    func makeNSView(context: Context) -> CherryMenuItemAXView {
        let view = CherryMenuItemAXView()
        view.item = item
        view.isHighlighted = isHighlighted
        return view
    }

    func updateNSView(_ view: CherryMenuItemAXView, context: Context) {
        view.item = item
        let changed = view.isHighlighted != isHighlighted
        view.isHighlighted = isHighlighted
        // VoiceOver follows the highlight only if it is told the selection
        // moved — the keyboard-driven case, where no pointer event happens.
        if changed && isHighlighted {
            NSAccessibility.post(element: view, notification: .selectedChildrenChanged)
            NSAccessibility.post(element: view, notification: .focusedUIElementChanged)
        }
    }
}
