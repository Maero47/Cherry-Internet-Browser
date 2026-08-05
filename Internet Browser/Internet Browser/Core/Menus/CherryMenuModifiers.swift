//
//  CherryMenuModifiers.swift
//  Cherry Browser
//

import SwiftUI
import AppKit

// MARK: - Context menus

extension View {
    /// The Cherry-drawn replacement for `.contextMenu`.
    ///
    /// Same shape as the modifier it replaces — a list of rows, built where the
    /// row's data is in scope — but the menu follows the accent, because Cherry
    /// draws it. See `CherryMenuController` for why `.contextMenu` could not.
    ///
    /// The items closure runs at click time, not at layout time, so rows that
    /// depend on state ("Pin Tab" vs "Unpin Tab") are right for the moment the
    /// menu opens.
    func cherryContextMenu(@CherryMenuBuilder _ items: @escaping () -> [CherryMenuItem]) -> some View {
        overlay { CherryContextMenuCatcher(items: items) }
    }
}

/// Turns a secondary click on the view underneath into a Cherry-drawn menu.
///
/// Overlaid rather than wrapped, and invisible to `hitTest` for every event
/// except the ones that mean "context menu" — the same trick `AuxClickCatcher`
/// uses, for the same reason: the control below must keep its click, its hover
/// and its drag.
private struct CherryContextMenuCatcher: NSViewRepresentable {
    let items: () -> [CherryMenuItem]

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.items = items
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.items = items
    }

    final class CatcherView: NSView {
        var items: (() -> [CherryMenuItem])?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            switch event.type {
            case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
                return super.hitTest(point)
            case .leftMouseDown, .leftMouseUp:
                // Control-click is the one-button spelling of a secondary
                // click, and macOS delivers it as a left click. Every other
                // left click belongs to the control underneath.
                return event.modifierFlags.contains(.control) ? super.hitTest(point) : nil
            default:
                return nil
            }
        }

        /// AppKit routes both a right click and a Control-click here, so this
        /// one override covers both gestures. Returning `nil` means "no
        /// `NSMenu`" — Cherry has already opened its own.
        override func menu(for event: NSEvent) -> NSMenu? {
            present()
            return nil
        }

        override func rightMouseDown(with event: NSEvent) {
            present()
        }

        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { present() } else { super.mouseDown(with: event) }
        }

        private func present() {
            guard let items = items?(), !items.isEmpty else { return }
            MainActor.assumeIsolated {
                CherryMenuController.shared.present(
                    items,
                    placement: .point(NSEvent.mouseLocation),
                    parentWindow: window
                )
            }
        }
    }
}

// MARK: - Menus hung off a control

/// A button that opens a Cherry-drawn menu under itself — the replacement for
/// SwiftUI's `Menu`.
///
/// Reports `isOpen` back to the label so a control can look pressed while its
/// menu is up, which `Menu` did for free and a plain `Button` does not.
struct CherryMenuButton<Label: View>: View {
    private let items: () -> [CherryMenuItem]
    private let label: (Bool) -> Label
    private let accessibilityTitle: String

    @State private var isOpen = false
    @State private var anchor = CherryMenuAnchor()

    init(
        accessibilityTitle: String = "",
        @CherryMenuBuilder items: @escaping () -> [CherryMenuItem],
        @ViewBuilder label: @escaping (Bool) -> Label
    ) {
        self.accessibilityTitle = accessibilityTitle
        self.items = items
        self.label = label
    }

    var body: some View {
        Button {
            open()
        } label: {
            label(isOpen)
        }
        .buttonStyle(.plain)
        // SwiftUI can only publish this as `AXButton`; `Menu` published
        // `AXMenuButton`, and that is the role that tells an assistive client
        // "this opens a menu" rather than "this does something". Restored with
        // a real `NSView`, the same way the menu's own rows are.
        .accessibilityHidden(true)
        .background { CherryMenuButtonAccessibility(title: accessibilityTitle, onPress: open) }
        .background { CherryMenuAnchorReader(anchor: anchor) }
    }

    private func open() {
        let rows = items()
        guard !rows.isEmpty, let frame = anchor.screenFrame else { return }
        isOpen = true
        CherryMenuController.shared.present(
            rows,
            placement: .below(frame),
            parentWindow: anchor.window
        ) {
            isOpen = false
        }
    }
}

/// Publishes a menu-opening control as `AXMenuButton` — the role `Menu`
/// published before the conversion.
private struct CherryMenuButtonAccessibility: NSViewRepresentable {
    let title: String
    let onPress: () -> Void

    func makeNSView(context: Context) -> MenuButtonAXView {
        let view = MenuButtonAXView()
        view.title = title
        view.onPress = onPress
        return view
    }

    func updateNSView(_ view: MenuButtonAXView, context: Context) {
        view.title = title
        view.onPress = onPress
    }

    final class MenuButtonAXView: NSView {
        var title: String = ""
        var onPress: (() -> Void)?

        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .menuButton }
        override func accessibilityTitle() -> String? { title.isEmpty ? nil : title }
        override func accessibilityPerformPress() -> Bool { onPress?(); return true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Where a control is on screen, so the menu it owns can hang off it.
///
/// SwiftUI can give a view's frame in a coordinate space, but not in screen
/// coordinates — and a menu is placed against the screen, because that is what
/// it has to avoid falling off. A one-pixel `NSView` in the background answers
/// the question exactly, including on a second display.
@MainActor
@Observable
final class CherryMenuAnchor {
    weak var view: NSView?

    var window: NSWindow? { view?.window }

    var screenFrame: CGRect? {
        guard let view, let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

struct CherryMenuAnchorReader: NSViewRepresentable {
    let anchor: CherryMenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        MainActor.assumeIsolated { anchor.view = view }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        MainActor.assumeIsolated { anchor.view = view }
    }

    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
