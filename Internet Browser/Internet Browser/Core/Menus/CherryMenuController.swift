//
//  CherryMenuController.swift
//  Cherry Browser
//

import SwiftUI
import AppKit

/// Where a menu is being opened from.
enum CherryMenuPlacement {
    /// A secondary click: the menu's top-left corner goes at this screen point.
    case point(CGPoint)
    /// A control: the menu hangs under this screen rect, flipping above it when
    /// there is no room below.
    case below(CGRect)
}

/// Presents Cherry's own menus.
///
/// Cherry draws these itself instead of handing them to `NSMenu` for one
/// reason: `NSMenu`'s highlight comes from the app's compile-time `AccentColor`
/// asset by way of a system material, so it could not follow the accent the
/// user picks in Cherry's Settings — it was cherry red whatever they chose.
/// Drawing the rows ourselves puts the highlight on `SettingsManager
/// .accentColor`, the same value `CherryWindowRoot` feeds to `.tint`.
///
/// Everything `NSMenu` gave away free has to be paid for here, and is:
/// `CherryMenuGeometry` flips at the screen edges, `CherryMenuHostView`
/// publishes an `AXMenu` of `AXMenuItem`s for VoiceOver, and this type owns the
/// keyboard (↑/↓/Home/End/Page, Return, Space, ←/→ through submenus, Escape,
/// type-select) and dismissal.
///
/// One session at a time, application-wide, which is also how menus behave.
@MainActor
final class CherryMenuController {
    static let shared = CherryMenuController()
    private var session: CherryMenuSession?

    var isPresenting: Bool { session != nil }

    private init() {}

    func present(
        _ items: [CherryMenuItem],
        placement: CherryMenuPlacement,
        accent: Color? = nil,
        parentWindow: NSWindow?,
        onDismiss: (() -> Void)? = nil
    ) {
        // Opening a menu closes whatever was open, so two can never be up.
        dismiss()
        let items = items.tidiedSeparators()
        guard !items.isEmpty else { onDismiss?(); return }
        // The same value `CherryWindowRoot` puts in `.tint`. Read here rather
        // than defaulted in the signature so every caller gets the accent as it
        // is at the moment the menu opens.
        let accent = accent ?? SettingsManager.shared.accentColor
        let session = CherryMenuSession(accent: accent, parentWindow: parentWindow) { [weak self] in
            self?.session = nil
            onDismiss?()
        }
        self.session = session
        session.open(items: items, placement: placement)
    }

    func dismiss() {
        session?.dismiss()
        session = nil
    }
}

// MARK: - Session

/// One open menu, including any submenus it has spawned.
@MainActor
final class CherryMenuSession {
    private struct Level {
        let panel: CherryMenuPanel
        let host: CherryMenuHostView
        let model: CherryMenuLevelModel
        /// The row in the level above that opened this one.
        let openedByRow: Int?
    }

    private let accent: Color
    private weak var parentWindow: NSWindow?
    private let onEnded: () -> Void

    private var levels: [Level] = []
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var pendingSubmenu: DispatchWorkItem?
    private var typeSelectBuffer = ""
    private var typeSelectExpiry = Date.distantPast
    /// The pointer position when the menu opened, so the click that opened it
    /// is not mistaken for the click that chooses a row.
    private var openedAt: CGPoint = .zero
    private var isEnding = false

    /// How long the pointer must rest on a row before its submenu opens, and
    /// how long a submenu survives the pointer moving off its parent row.
    /// Matched to AppKit's feel: long enough to cross a row on the way
    /// somewhere else, short enough not to feel stuck.
    private let submenuOpenDelay: TimeInterval = 0.22
    private let submenuCloseDelay: TimeInterval = 0.25

    init(accent: Color, parentWindow: NSWindow?, onEnded: @escaping () -> Void) {
        self.accent = accent
        self.parentWindow = parentWindow
        self.onEnded = onEnded
    }

    // MARK: Opening

    func open(items: [CherryMenuItem], placement: CherryMenuPlacement) {
        openedAt = NSEvent.mouseLocation
        pushLevel(items: items, openedByRow: nil) { size, visible in
            switch placement {
            case .point(let point):
                return CherryMenuGeometry.contextFrame(size: size, at: point, in: visible)
            case .below(let anchor):
                return CherryMenuGeometry.anchoredFrame(size: size, below: anchor, in: visible)
            }
        }
        installMonitors()
    }

    private func pushLevel(
        items: [CherryMenuItem],
        openedByRow: Int?,
        frame: (CGSize, CGRect) -> CGRect
    ) {
        let model = CherryMenuLevelModel(items: items, accent: accent)
        let host = CherryMenuHostView()
        host.items = items

        let visible = screenFrame()
        let size = CGSize(
            width: CherryMenuLayout.width(of: items),
            height: min(CherryMenuLayout.contentHeight(of: items), CherryMenuGeometry.maxHeight(in: visible))
        )
        let target = frame(size, visible)

        let hosting = NSHostingView(rootView: CherryMenuContentView(model: model, maxHeight: target.height))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        host.frame = NSRect(origin: .zero, size: target.size)
        host.installMenuMaterial()
        host.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: host.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])

        let panel = CherryMenuPanel(contentView: host)
        panel.setFrame(target, display: false)

        let index = levels.count
        host.onHover = { [weak self] row in self?.hover(row, atLevel: index) }
        host.onClick = { [weak self] row in self?.click(row, atLevel: index) }
        host.onKey = { [weak self] event in self?.handleKey(event) ?? false }

        levels.append(Level(panel: panel, host: host, model: model, openedByRow: openedByRow))

        // A child of the window that opened it, so the browser window keeps its
        // active look while the menu holds key status for VoiceOver's sake.
        parentWindow?.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(host)
        NSAccessibility.post(element: panel, notification: .created)
    }

    private func screenFrame() -> CGRect {
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(point) }
            ?? parentWindow?.screen
            ?? NSScreen.main
        return screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    // MARK: Pointer

    private func hover(_ row: Int?, atLevel level: Int) {
        guard level < levels.count else { return }
        // Moving back into a shallower level closes everything below it — but
        // only after a grace period, so travelling diagonally across the parent
        // row into a submenu does not slam it shut on the way.
        setHighlight(row, atLevel: level)
        pendingSubmenu?.cancel()

        guard let row, levels[level].model.items.indices.contains(row) else {
            scheduleCollapse(below: level)
            return
        }
        let item = levels[level].model.items[row]

        if item.hasSubmenu, item.isEnabled {
            if levels.count > level + 1, levels[level + 1].openedByRow == row { return }
            let work = DispatchWorkItem { [weak self] in self?.openSubmenu(row: row, atLevel: level) }
            pendingSubmenu = work
            DispatchQueue.main.asyncAfter(deadline: .now() + submenuOpenDelay, execute: work)
        } else if levels.count > level + 1 {
            scheduleCollapse(below: level)
        }
    }

    private func scheduleCollapse(below level: Int) {
        guard levels.count > level + 1 else { return }
        let work = DispatchWorkItem { [weak self] in self?.collapse(below: level) }
        pendingSubmenu = work
        DispatchQueue.main.asyncAfter(deadline: .now() + submenuCloseDelay, execute: work)
    }

    private func click(_ row: Int, atLevel level: Int) {
        guard level < levels.count else { return }
        collapse(below: level)
        setHighlight(row, atLevel: level)
        activate(row: row, atLevel: level)
    }

    // MARK: Highlight

    private func setHighlight(_ row: Int?, atLevel level: Int) {
        guard level < levels.count else { return }
        let model = levels[level].model
        let resolved = row.flatMap { model.items[$0].isSelectable ? $0 : nil }
        guard model.highlightedIndex != resolved else { return }
        model.highlightedIndex = resolved
        levels[level].host.highlightedIndex = resolved
        // SwiftUI redraws on the next pass; the accessibility tree is told
        // after it, once the row views carry the new flag.
        let host = levels[level].host
        DispatchQueue.main.async { host.publishSelection() }
    }

    private func activate(row: Int, atLevel level: Int) {
        guard level < levels.count else { return }
        let item = levels[level].model.items[row]
        guard item.isSelectable else { return }
        switch item.kind {
        case .action(let perform):
            dismiss()
            // After the menu is gone, so an action that opens a sheet or a
            // panel is not fighting a window that is still on screen.
            perform()
        case .submenu:
            openSubmenu(row: row, atLevel: level, focusFirstRow: true)
        case .separator:
            break
        }
    }

    // MARK: Submenus

    private func openSubmenu(row: Int, atLevel level: Int, focusFirstRow: Bool = false) {
        guard level < levels.count else { return }
        let parent = levels[level]
        let item = parent.model.items[row]
        guard item.hasSubmenu, item.isEnabled else { return }

        if levels.count > level + 1 {
            if levels[level + 1].openedByRow == row {
                if focusFirstRow { highlightEdge(first: true, atLevel: level + 1) }
                return
            }
            collapse(below: level)
        }

        let children = item.submenuItems.tidiedSeparators()
        guard !children.isEmpty else { return }
        let rowTop = parent.panel.frame.maxY - CherryMenuLayout.offsetFromTop(ofRow: row, in: parent.model.items)
        let parentFrame = parent.panel.frame
        pushLevel(items: children, openedByRow: row) { size, visible in
            CherryMenuGeometry.submenuFrame(size: size, rowTop: rowTop, parent: parentFrame, in: visible)
        }
        if focusFirstRow { highlightEdge(first: true, atLevel: levels.count - 1) }
    }

    /// Closes every level deeper than `level`.
    private func collapse(below level: Int) {
        pendingSubmenu?.cancel()
        while levels.count > level + 1, let last = levels.popLast() {
            close(last)
        }
        if let top = levels.last {
            top.panel.makeKeyAndOrderFront(nil)
            top.panel.makeFirstResponder(top.host)
        }
    }

    private func close(_ level: Level) {
        level.panel.parent?.removeChildWindow(level.panel)
        level.panel.orderOut(nil)
        level.panel.contentView = nil
    }

    // MARK: Keyboard

    @discardableResult
    private func handleKey(_ event: NSEvent) -> Bool {
        guard !levels.isEmpty else { return false }
        let level = levels.count - 1

        // ⌘. is the old, still-supported way to cancel.
        if event.modifierFlags.contains(.command) {
            if event.charactersIgnoringModifiers == "." { dismiss(); return true }
            return true
        }

        switch event.keyCode {
        case 126: move(by: -1, atLevel: level); return true              // ↑
        case 125: move(by: 1, atLevel: level); return true               // ↓
        case 116: move(by: -5, atLevel: level); return true              // Page Up
        case 121: move(by: 5, atLevel: level); return true               // Page Down
        case 115: highlightEdge(first: true, atLevel: level); return true  // Home
        case 119: highlightEdge(first: false, atLevel: level); return true // End
        case 36, 76, 49:                                                  // Return, Enter, Space
            if let row = levels[level].model.highlightedIndex { activate(row: row, atLevel: level) }
            return true
        case 53: dismiss(); return true                                   // Escape
        case 124:                                                         // →
            if let row = levels[level].model.highlightedIndex,
               levels[level].model.items[row].hasSubmenu {
                openSubmenu(row: row, atLevel: level, focusFirstRow: true)
            }
            return true
        case 123:                                                         // ←
            if level > 0 { collapse(below: level - 1) } else { dismiss() }
            return true
        default:
            return typeSelect(event, atLevel: level)
        }
    }

    private func move(by delta: Int, atLevel level: Int) {
        let model = levels[level].model
        var index = model.highlightedIndex
        let step = delta > 0 ? 1 : -1
        for _ in 0..<abs(delta) {
            guard let next = CherryMenuKeyboard.nextIndex(from: index, direction: step, items: model.items) else { break }
            index = next
        }
        setHighlight(index, atLevel: level)
    }

    private func highlightEdge(first: Bool, atLevel level: Int) {
        guard level < levels.count else { return }
        let items = levels[level].model.items
        setHighlight(first ? CherryMenuKeyboard.firstIndex(in: items) : CherryMenuKeyboard.lastIndex(in: items), atLevel: level)
    }

    /// Typing letters jumps to the row that starts with them, and typing the
    /// same letter again cycles through the rows that do — what `NSMenu` does,
    /// and the thing a keyboard user reaches for before the arrow keys.
    private func typeSelect(_ event: NSEvent, atLevel level: Int) -> Bool {
        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty,
              characters.allSatisfy({ !$0.isNewline && !$0.isWhitespace }),
              characters.rangeOfCharacter(from: .alphanumerics) != nil else { return true }

        let now = Date()
        if now > typeSelectExpiry { typeSelectBuffer = "" }
        typeSelectBuffer += characters
        typeSelectExpiry = now.addingTimeInterval(0.9)

        let items = levels[level].model.items
        let current = levels[level].model.highlightedIndex
        // A repeated single letter means "the next one that starts with it";
        // a genuine prefix means "the first one that starts with it".
        let repeated = typeSelectBuffer.count > 1 && Set(typeSelectBuffer.lowercased()).count == 1
        if repeated, let match = CherryMenuKeyboard.typeSelectIndex(prefix: characters, from: current, items: items) {
            setHighlight(match, atLevel: level)
        } else if let match = CherryMenuKeyboard.typeSelectIndex(prefix: typeSelectBuffer, from: nil, items: items) {
            setHighlight(match, atLevel: level)
        }
        return true
    }

    // MARK: Monitors

    private func installMonitors() {
        // Keyboard, before anything else in the app sees it. While a menu is up
        // it owns the keyboard, which is what `NSMenu`'s modal tracking loop
        // amounts to; without this a shortcut could fire behind the menu.
        let keys = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] event in
            guard let self, !self.levels.isEmpty else { return event }
            self.handleKey(event)
            return nil
        })
        monitors.append(contentsOf: [keys].compactMap { $0 })

        let pressTypes: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        let presses = NSEvent.addLocalMonitorForEvents(matching: pressTypes, handler: { [weak self] event in
            guard let self, !self.levels.isEmpty else { return event }
            if let window = event.window, self.levels.contains(where: { $0.panel === window }) { return event }
            // Dismissed *and* swallowed: the click that closes a menu does not
            // also press whatever was underneath it, exactly as with `NSMenu`.
            self.dismiss()
            return nil
        })
        monitors.append(contentsOf: [presses].compactMap { $0 })

        let outside = NSEvent.addGlobalMonitorForEvents(matching: pressTypes, handler: { [weak self] _ in
            self?.dismiss()
        })
        monitors.append(contentsOf: [outside].compactMap { $0 })

        // Press-drag-release: press the ⋯ button, drag down the menu, let go on
        // a row. The drag never reaches the panel's own tracking area, so it is
        // followed here.
        let drags = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged], handler: { [weak self] event in
            self?.trackDrag(to: NSEvent.mouseLocation)
            return event
        })
        let releases = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp], handler: { [weak self] event in
            self?.endDrag(at: NSEvent.mouseLocation)
            return event
        })
        monitors.append(contentsOf: [drags, releases].compactMap { $0 })

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CherryMenuController.shared.dismiss() }
        })
        if let parentWindow {
            observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: parentWindow, queue: .main) { _ in
                MainActor.assumeIsolated { CherryMenuController.shared.dismiss() }
            })
            // Following a window that moves is not worth the complexity; a menu
            // that has come unstuck from its window is worse than one that
            // closed.
            observers.append(center.addObserver(forName: NSWindow.willMoveNotification, object: parentWindow, queue: .main) { _ in
                MainActor.assumeIsolated { CherryMenuController.shared.dismiss() }
            })
        }
    }

    private func level(containing screenPoint: CGPoint) -> Int? {
        levels.lastIndex { $0.panel.frame.contains(screenPoint) }
    }

    private func trackDrag(to screenPoint: CGPoint) {
        guard let index = level(containing: screenPoint) else { return }
        let window = levels[index].panel
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        hover(levels[index].host.rowIndex(atWindowPoint: windowPoint), atLevel: index)
    }

    private func endDrag(at screenPoint: CGPoint) {
        // The release that ends the click which *opened* the menu is not a
        // choice. Anything further away is a real press-drag-release.
        guard hypot(screenPoint.x - openedAt.x, screenPoint.y - openedAt.y) > 5 else { return }
        guard let index = level(containing: screenPoint) else { return }
        let window = levels[index].panel
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        guard let row = levels[index].host.rowIndex(atWindowPoint: windowPoint) else { return }
        click(row, atLevel: index)
    }

    // MARK: Ending

    func dismiss() {
        guard !isEnding else { return }
        isEnding = true
        pendingSubmenu?.cancel()
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        while let last = levels.popLast() { close(last) }
        parentWindow?.makeKeyAndOrderFront(nil)
        onEnded()
    }
}
