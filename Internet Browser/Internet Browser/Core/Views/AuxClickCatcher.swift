//
//  AuxClickCatcher.swift
//  Cherry Browser
//

import SwiftUI
import AppKit

/// Adds middle-click ("open in a background tab") to a SwiftUI control, which
/// `Button` can't express — it only ever sees the primary mouse button.
///
/// Overlay it on the row you want clickable:
///
///     row.overlay { AuxClickCatcher { openInNewTab(item) } }
///
/// The view is transparent to every other event: `hitTest` claims the point
/// only while the current event is an "other" (middle/aux) mouse event, so
/// left-clicks, right-clicks and hovers still reach the control underneath.
struct AuxClickCatcher: NSViewRepresentable {
    let onMiddleClick: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = MiddleClickView()
        view.onMiddleClick = onMiddleClick
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? MiddleClickView)?.onMiddleClick = onMiddleClick
    }

    private final class MiddleClickView: NSView {
        var onMiddleClick: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
                return super.hitTest(point)
            default:
                // Invisible to everything else, so the SwiftUI button below
                // keeps its click, context menu and hover.
                return nil
            }
        }

        override func otherMouseUp(with event: NSEvent) {
            // buttonNumber 2 is the middle button; 3/4 are back/forward, which
            // must not open tabs.
            guard event.buttonNumber == 2 else {
                super.otherMouseUp(with: event)
                return
            }
            onMiddleClick?()
        }
    }
}

extension NSEvent {
    /// Whether the click being handled right now is a ⌘-click — i.e. "open
    /// this in a background tab", the web convention every browser follows.
    /// SwiftUI hands `Button` actions no event, so the row reads the modifier
    /// state at the moment the action runs.
    @MainActor
    static var isCommandClick: Bool {
        NSEvent.modifierFlags.contains(.command)
    }
}
