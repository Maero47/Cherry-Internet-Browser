//
//  BrowserCommand.swift
//  Cherry Browser
//

import AppKit
import Foundation

/// Every user-invocable browser command, declared exactly once.
///
/// Cherry has ONE command system: the menu bar (`Internet_BrowserApp.body`) is
/// the single owner of every keyboard shortcut. A menu item posts its command
/// with `post()`, and the KEY window's `BrowserView` is the only thing that
/// runs it (`BrowserView.perform(_:)`). Nothing else in the app declares a
/// `keyboardShortcut`, so:
///
/// * a shortcut can never be declared twice (no ambiguous resolution),
/// * a menu item and its key equivalent can never drift apart,
/// * every shortcut has a real, VoiceOver-reachable menu item.
///
/// Commands that must work with no browser window open (New Window, New
/// Incognito Window, Load Extension…) are deliberately NOT in here — they're
/// app-level and call their handler directly from the menu.
enum BrowserCommand: String, CaseIterable {

    // MARK: Tabs

    case newTab
    case closeTab
    case reopenClosedTab
    case selectNextTab
    case selectPreviousTab
    case searchTabs
    case selectTab1
    case selectTab2
    case selectTab3
    case selectTab4
    case selectTab5
    case selectTab6
    case selectTab7
    case selectTab8
    case selectTab9

    // MARK: Navigation

    case goBack
    case goForward
    case reloadPage
    case stopLoading

    // MARK: Zoom

    case zoomIn
    case zoomOut
    case actualSize

    // MARK: Layout

    case toggleBookmarkBar
    case toggleVerticalTabs
    case toggleSplitView
    case focusAddressBar

    // MARK: Internal pages

    case showHistory
    case showBookmarks
    case showDownloads
    case showSettingsPage
    case addBookmark

    // MARK: Find & palette

    case findInPage
    case showCommandPalette

    // MARK: Tools

    case printPage
    case toggleReaderMode
    case captureScreenshot
    case toggleFocusMode
    case askThisPage
    case autoFillPassword

    // MARK: Develop

    case showWebInspector
    case showConsole
    case viewSource

    /// 1…9 for the `selectTabN` commands, `nil` for everything else.
    /// `BrowserViewModel.selectTab(at:)` treats 9 as "last tab".
    var tabIndex: Int? {
        switch self {
        case .selectTab1: return 1
        case .selectTab2: return 2
        case .selectTab3: return 3
        case .selectTab4: return 4
        case .selectTab5: return 5
        case .selectTab6: return 6
        case .selectTab7: return 7
        case .selectTab8: return 8
        case .selectTab9: return 9
        default: return nil
        }
    }
}

// MARK: - Delivery

extension Notification.Name {
    /// Carries a `BrowserCommand` from the menu bar to the key window's
    /// `BrowserView`. The only command channel in the app.
    static let browserCommand = Notification.Name("CherryBrowserCommand")
}

extension BrowserCommand {
    private static let userInfoKey = "command"

    /// Broadcasts this command. Every open window receives it; only the key
    /// window's `BrowserView` acts on it (see `BrowserView.isKeyBrowserWindow`).
    func post() {
        NotificationCenter.default.post(
            name: .browserCommand,
            object: nil,
            userInfo: [Self.userInfoKey: rawValue]
        )
    }

    /// Recovers the command from a `.browserCommand` notification.
    init?(notification: Notification) {
        guard let raw = notification.userInfo?[Self.userInfoKey] as? String,
              let command = BrowserCommand(rawValue: raw) else { return nil }
        self = command
    }
}

// MARK: - Routing

/// Decides which window a broadcast command belongs to.
enum CommandRouting {

    /// Whether the browser hosted by `window` should run a command, given the
    /// app's current `keyWindow`.
    ///
    /// Fails **closed** on a nil window. Writing this as
    /// `window === NSApp.keyWindow` looks equivalent but is not: Swift's `===`
    /// on optionals makes `nil === nil` **true**, so the guard would pass
    /// whenever the app has no key window and the view model isn't registered
    /// yet — `WindowRegistrar` assigns `associatedWindow` from a
    /// `DispatchQueue.main.async`, and a closed window's weak reference goes
    /// nil too. In that state a command would run in a window that is
    /// explicitly not key, and in EVERY such window if more than one existed:
    /// exactly the multi-window bug the check exists to prevent.
    @MainActor
    static func shouldRun(in window: NSWindow?, keyWindow: NSWindow?) -> Bool {
        guard let window, let keyWindow else { return false }
        return window === keyWindow
    }

    /// "The candidate hosted by the key window, or else the first candidate" —
    /// the pattern used to pick a target window for something that has to land
    /// *somewhere* (an extension's new tab, a Settings link opening in Cherry).
    ///
    /// Shared rather than spelled out per site for the same reason as
    /// `shouldRun`: the hand-written
    /// `first { $0.associatedWindow === keyWindow } ?? first` picks an
    /// UNREGISTERED window whenever there's no key window, because
    /// `nil === nil` is true — so instead of falling through to the
    /// deterministic first candidate it grabs an arbitrary one. Routing the
    /// match through `shouldRun` makes the fallback actually happen.
    @MainActor
    static func preferringKeyWindow<Candidate>(
        _ candidates: [Candidate],
        keyWindow: NSWindow?,
        window: (Candidate) -> NSWindow?
    ) -> Candidate? {
        candidates.first { shouldRun(in: window($0), keyWindow: keyWindow) } ?? candidates.first
    }
}
