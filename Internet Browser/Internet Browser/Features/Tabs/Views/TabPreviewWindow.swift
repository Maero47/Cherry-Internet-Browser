//
//  TabPreviewWindow.swift
//  Internet Browser
//

import SwiftUI
import AppKit

/// Borderless, click-through window that shows a tab's hover preview.
///
/// This replaces the `.popover(isPresented:)` the tab item used to present.
/// On macOS a SwiftUI popover is *transient*: AppKit installs an event monitor
/// while it is up, and the first mouse-down anywhere outside the popover is
/// CONSUMED to dismiss it instead of being delivered to the view under the
/// cursor. So the completely natural gesture "hover a tab long enough to read
/// its title, then click it" threw the click away — including a click on the
/// tab's close button — which is exactly the "I have to click twice" report.
///
/// A window can't do that: `ignoresMouseEvents` makes every event pass straight
/// through to the app below, and it can never become key or main, so it neither
/// steals the click nor the window's focus. It also lives outside the SwiftUI
/// hierarchy, so — like `GhostTabWindow` — it isn't clipped to the tab bar's
/// 38 pt height (a plain `.overlay` would be).
final class TabPreviewWindow: NSWindow {
    /// Gap between the pointer and the top edge of the chip.
    private static let cursorGap: CGFloat = 18
    /// Keep-out margin from the screen edges when clamping.
    private static let screenMargin: CGFloat = 6

    init(tab: Tab) {
        let hostingView = cherryHostingView(TabPreviewChipView(tab: tab))
        let fitting = hostingView.fittingSize
        let size = NSSize(
            width: fitting.width > 0 ? fitting.width : TabPreviewChipView.width,
            height: fitting.height > 0 ? fitting.height : 64
        )
        hostingView.frame = NSRect(origin: .zero, size: size)

        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        level = .floating
        // The whole point: never intercept the mouse. Clicks, and the
        // mouse-moved events the tab's own `.onHover` tracking needs, both go
        // straight through to the browser window underneath.
        ignoresMouseEvents = true
        // A preview must not outlive the app losing focus (Cmd+Tab away with
        // the pointer parked on a tab would otherwise leave a floating chip
        // above the other app). `TabPreviewPresenter` owns that outright: it
        // observes deactivation and CLOSES the window. `hidesOnDeactivate`
        // stays off deliberately — it would only park the window off screen and
        // then restore it on reactivation, so the two mechanisms would race and
        // the survivor would be an AppKit implementation detail.
        hidesOnDeactivate = false
        isExcludedFromWindowsMenu = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .transient]
        contentView = hostingView
    }

    /// Never key, never main: a preview must not pull focus off the browser
    /// window it is describing. (This is about focus only — `TabManager`'s
    /// "does any window keep the app alive" check does NOT read `canBecomeMain`,
    /// which is visibility-coupled and so useless for minimised windows; it
    /// excludes this chip because a `.borderless` window is not titled.)
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Places the chip just below `point` (screen coordinates, origin
    /// bottom-left — i.e. straight from `NSEvent.mouseLocation`), horizontally
    /// centred on it and clamped into the screen's visible frame so a preview
    /// opened near an edge stays fully on screen. If it doesn't fit below the
    /// pointer it flips above it.
    func position(below point: NSPoint) {
        let size = frame.size
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        var origin = NSPoint(
            x: point.x - size.width / 2,
            y: point.y - size.height - Self.cursorGap
        )

        if let visible = screen?.visibleFrame {
            let margin = Self.screenMargin
            origin.x = min(max(origin.x, visible.minX + margin), max(visible.minX + margin, visible.maxX - size.width - margin))
            if origin.y < visible.minY + margin {
                origin.y = point.y + Self.cursorGap // flip above the pointer
            }
            origin.y = min(origin.y, max(visible.minY + margin, visible.maxY - size.height - margin))
        }

        setFrameOrigin(origin)
    }
}

/// Owns the single on-screen tab preview. One window at a time, and every
/// dismissal path (pointer leaves the tab, the tab is pressed, the tab bar goes
/// away) routes through `hide`, so a preview can never be left behind.
@MainActor
final class TabPreviewPresenter {
    static let shared = TabPreviewPresenter()

    private var window: TabPreviewWindow?
    /// The tab the visible preview belongs to — `hide(for:)` is a no-op for any
    /// other tab, so a stale hide from the tab the pointer just left can't kill
    /// the preview of the tab it just entered.
    private var ownerID: UUID?

    private init() {
        // Sole owner of deactivation dismissal. ⌘-Tab away from a visible
        // preview and back must not redisplay a chip with no pointer on the tab
        // and nothing left to dismiss it — `hide()` closes the window, so there
        // is nothing for AppKit to restore.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { TabPreviewPresenter.shared.hide() }
        }
    }

    func show(for tab: Tab, at screenPoint: NSPoint) {
        hide()
        let window = TabPreviewWindow(tab: tab)
        window.position(below: screenPoint)
        window.orderFrontRegardless()
        self.window = window
        ownerID = tab.id
    }

    func hide(for tabID: UUID) {
        guard ownerID == tabID else { return }
        hide()
    }

    func hide() {
        // `close()`, not `orderOut(nil)`: closing takes the window out of the
        // application's window list, not just off the screen, so nothing can
        // order it back in. Safe because `isReleasedWhenClosed` is false.
        window?.close()
        window = nil
        ownerID = nil
    }
}

/// The preview's content — the same information the old popover showed.
private struct TabPreviewChipView: View {
    static let width: CGFloat = 260

    let tab: Tab

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tab.displayTitle)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
            if let url = tab.url {
                Text(url.absoluteString)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if tab.isSleeping {
                Text("Tab is sleeping")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
        }
        .padding(8)
        .frame(width: Self.width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
        )
    }
}
