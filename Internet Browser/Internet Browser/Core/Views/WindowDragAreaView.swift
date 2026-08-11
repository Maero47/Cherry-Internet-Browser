//
//  WindowDragAreaView.swift
//  Internet Browser
//

import SwiftUI
import AppKit

// MARK: - Window Drag Area (AppKit-based, no coordinate feedback issues)

/// An NSView that handles window dragging via mouseDragged events.
/// Unlike SwiftUI DragGesture, this doesn't suffer from coordinate feedback
/// when the window moves under the cursor.
struct WindowDragAreaView: NSViewRepresentable {
    func makeNSView(context: Context) -> DragAreaNSView {
        let view = DragAreaNSView()
        return view
    }

    func updateNSView(_ nsView: DragAreaNSView, context: Context) {}
}

class DragAreaNSView: NSView {
    private var initialMouseLocation: NSPoint = .zero
    private var initialWindowOrigin: NSPoint = .zero

    /// The window is system-movable (the green button's arrangement menu
    /// requires it — see `configureBrowserWindow`), so without this AppKit
    /// would ALSO server-drag the window from this view while `mouseDragged`
    /// below moves it manually: two movers, double-speed dragging. This view
    /// owns its drags alone.
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard let window = self.window else {
            super.mouseDown(with: event)
            return
        }
        // Capture initial positions in screen coordinates
        initialMouseLocation = NSEvent.mouseLocation
        initialWindowOrigin = window.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window = self.window else { return }
        let currentMouse = NSEvent.mouseLocation
        let deltaX = currentMouse.x - initialMouseLocation.x
        let deltaY = currentMouse.y - initialMouseLocation.y
        window.setFrameOrigin(NSPoint(
            x: initialWindowOrigin.x + deltaX,
            y: initialWindowOrigin.y + deltaY
        ))
    }

    // Double-click to zoom (standard macOS behavior)
    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 {
            self.window?.zoom(nil)
        }
        super.mouseUp(with: event)
    }
}

// MARK: - Window Configurator

/// Invisible view that configures the hosting NSWindow from within the SwiftUI hierarchy.
/// This ensures the movability flags are set AFTER SwiftUI creates the window.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = WindowConfiguratorNSView()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

class WindowConfiguratorNSView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window = self.window else { return }
        // The same pair `configureBrowserWindow` sets, and for the same
        // reason: system-movable (or the green button's arrangement menu is
        // withheld), background drags off. This runs after SwiftUI installs
        // the content, so it must agree with the window-side configuration —
        // it used to force `isMovable = false`, which would quietly undo the
        // arrangement-menu fix on every browser window.
        window.isMovable = true
        window.isMovableByWindowBackground = false
    }
}
