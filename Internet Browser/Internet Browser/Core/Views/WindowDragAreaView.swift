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
/// This ensures isMovable = false is set AFTER SwiftUI creates the window.
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
        window.isMovable = false
        window.isMovableByWindowBackground = false
    }
}
