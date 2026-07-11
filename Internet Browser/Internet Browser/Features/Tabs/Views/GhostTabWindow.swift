//
//  GhostTabWindow.swift
//  Internet Browser
//

import SwiftUI
import AppKit

/// Borderless, click-through NSWindow that shows a floating chip for a tab being
/// torn off the tab bar. A SwiftUI `.overlay` is clipped to its own window's bounds,
/// so it disappears the moment the cursor leaves the source window; this window lives
/// outside that hierarchy and can be positioned anywhere on screen, over any window.
final class GhostTabWindow: NSWindow {
    private static let chipSize = NSSize(width: 180, height: 36)

    init(tab: Tab) {
        let hostingView = NSHostingView(rootView: GhostTabChipView(tab: tab))
        hostingView.frame = NSRect(origin: .zero, size: Self.chipSize)

        super.init(
            contentRect: NSRect(origin: .zero, size: Self.chipSize),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        level = .floating
        // Must never intercept the mouse: the drag gesture and the eventual
        // window-under-cursor lookup both rely on real events reaching the app below.
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = hostingView
    }

    /// Centers the ghost on the given point, expressed in macOS screen coordinates
    /// (origin bottom-left) — i.e. straight from `NSEvent.mouseLocation`.
    func move(toScreenPoint point: NSPoint) {
        setFrameOrigin(NSPoint(x: point.x - frame.width / 2, y: point.y - frame.height / 2))
    }
}

/// Minimal tab chip rendered inside the floating ghost window.
private struct GhostTabChipView: View {
    let tab: Tab

    var body: some View {
        HStack(spacing: 6) {
            faviconView
                .frame(width: 14, height: 14)
            Text(tab.displayTitle)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: 180, height: 36, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppConstants.UI.tabCornerRadius)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppConstants.UI.tabCornerRadius)
                .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var faviconView: some View {
        if let favicon = tab.favicon {
            Image(nsImage: favicon)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "globe")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}
