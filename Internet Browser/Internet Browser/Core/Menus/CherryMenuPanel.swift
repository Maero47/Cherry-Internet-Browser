//
//  CherryMenuPanel.swift
//  Cherry Browser
//

import SwiftUI
import AppKit

/// The window one level of a Cherry-drawn menu lives in.
///
/// A borderless panel rather than an `NSPopover` (which always draws an arrow,
/// and a menu with an arrow is a different widget) and rather than a plain
/// `NSWindow` (which would take main-window status away from the browser
/// window and dim its title bar). It *does* take key status, on purpose:
/// VoiceOver follows the key window, and a menu VoiceOver cannot reach is not
/// a menu. It is added as a child window of the window that opened it, so the
/// browser window keeps its active appearance while the menu is up.
final class CherryMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentView: NSView) {
        super.init(
            contentRect: NSRect(origin: .zero, size: contentView.frame.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = true
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        // A menu is not a window you can Tab to or find in the Window menu.
        isExcludedFromWindowsMenu = true
        self.contentView = contentView
        // `AXMenu` rather than `AXWindow`: VoiceOver then announces this the
        // way it announces the menus it replaces.
        setAccessibilityRole(.menu)
        setAccessibilitySubrole(nil)
    }
}

/// The panel's content view: it draws nothing itself, hosts the SwiftUI menu,
/// and owns every interaction — pointer, keyboard and the accessibility tree.
///
/// Interaction is handled here rather than with SwiftUI gestures because a menu
/// has to be exactly right on the first event: no first-click-activates-window
/// swallowing, no gesture recogniser deciding a press was a drag, and hit
/// testing that agrees precisely with the arithmetic used to place submenus.
final class CherryMenuHostView: NSView {
    /// Called with a row index, or `nil` when the pointer is off every row.
    var onHover: ((Int?) -> Void)?
    var onClick: ((Int) -> Void)?
    var onKey: ((NSEvent) -> Bool)?
    /// The rows, so hit testing and the accessibility tree stay in step with
    /// what is drawn.
    var items: [CherryMenuItem] = []
    var highlightedIndex: Int?

    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The menu's background: AppKit's own `.menu` material, behind the SwiftUI
    /// rows rather than under them in SwiftUI's own layer.
    ///
    /// Two reasons it lives here. It is the material `NSMenu` uses, so a
    /// converted menu and a still-native one look like the same widget; and
    /// SwiftUI blends content drawn over a SwiftUI material, which shifted the
    /// accent highlight off its exact value.
    func installMenuMaterial() {
        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = CherryMenuMetrics.menuCornerRadius
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]
        effect.frame = bounds
        addSubview(effect, positioned: .below, relativeTo: nil)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - Pointer

    /// The row under a window-space point, using the same arithmetic that laid
    /// the rows out.
    func rowIndex(atWindowPoint point: NSPoint) -> Int? {
        let local = convert(point, from: nil)
        guard bounds.contains(local) else { return nil }
        // Rows are laid out from the top; the view's coordinates run from the
        // bottom.
        return CherryMenuLayout.rowIndex(atOffsetFromTop: bounds.maxY - local.y, in: items)
    }

    override func mouseMoved(with event: NSEvent) {
        onHover?(rowIndex(atWindowPoint: event.locationInWindow))
    }

    override func mouseDragged(with event: NSEvent) {
        onHover?(rowIndex(atWindowPoint: event.locationInWindow))
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(nil)
    }

    override func mouseUp(with event: NSEvent) {
        guard let index = rowIndex(atWindowPoint: event.locationInWindow) else { return }
        onClick?(index)
    }

    // A press inside the menu must never reach the window underneath.
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        // Swallowed rather than passed on: while a menu is up it owns the
        // keyboard, exactly as `NSMenu`'s tracking loop does. Calling super
        // here would beep and, worse, let a shortcut fire behind the menu.
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        onKey?(event) ?? false
    }

    // MARK: - Accessibility

    override func accessibilityRole() -> NSAccessibility.Role? { .menu }
    override func accessibilityLabel() -> String? { "Menu" }
    override func isAccessibilityElement() -> Bool { true }

    /// The rows, in the order they are drawn, with SwiftUI's own scaffolding
    /// left out — so VoiceOver's "3 of 11" counts menu rows and not view
    /// wrappers.
    override func accessibilityChildren() -> [Any]? {
        rowElements()
    }

    /// Publishes the highlighted row as the menu's selected child, so VoiceOver
    /// follows ↑/↓ — the keyboard case, where there is no pointer event to
    /// notice. Called after every highlight change; the rows carry the flag
    /// themselves too (`isAccessibilitySelected`), matching `NSMenu`.
    func publishSelection() {
        let selected = rowElements().filter(\.isHighlighted)
        setAccessibilitySelectedChildren(selected)
        NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
    }

    func rowElements() -> [CherryMenuItemAXView] {
        var found: [CherryMenuItemAXView] = []
        func walk(_ view: NSView) {
            if let row = view as? CherryMenuItemAXView { found.append(row) }
            view.subviews.forEach(walk)
        }
        walk(self)
        // Drawn top to bottom; view coordinates run bottom to top.
        return found.sorted { $0.convert($0.bounds, to: self).maxY > $1.convert($1.bounds, to: self).maxY }
    }
}
