//
//  Internet_BrowserApp.swift
//  Internet Browser
//
//  Created by Mehmet Ali Dede on 7.02.2026.
//

import SwiftUI
import AppKit
import WebKit
import UniformTypeIdentifiers

@main
struct Internet_BrowserApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            BrowserView()
                .cherryWindowRoot()
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            // ONE command system: every shortcut in Cherry is declared here and
            // nowhere else. `CommandItem` posts a `BrowserCommand` that the KEY
            // window's BrowserView runs, so the menu item and its key equivalent
            // are always the same code path (see BrowserCommand).
            //
            // App menu: Cmd+, opens cherry://settings in the key window's
            // focused tab (Chrome-style in-tab settings) instead of the old
            // separate native Settings window.
            CommandGroup(replacing: .appSettings) {
                CommandItem("Settings…", .showSettingsPage, ",")
            }

            CommandGroup(replacing: .newItem) { fileMenuItems }
            // `replacing:` rather than a plain File-menu item, so Cherry's
            // Print is THE print command and SwiftUI's stock one can't sit
            // beside it holding the same ⌘P.
            CommandGroup(replacing: .printItem) {
                CommandItem("Print…", .printPage, "p")
            }
            CommandGroup(after: .pasteboard) { editMenuItems }
            CommandGroup(replacing: .toolbar) { viewMenuItems }

            CommandMenu("Tabs") { tabsMenuItems }
            CommandMenu("History") { historyMenuItems }
            CommandMenu("Bookmarks") { bookmarksMenuItems }
            CommandMenu("Tools") { toolsMenuItems }
            CommandMenu("Develop") { developMenuItems }
        }

    }

    // Split into per-menu builders so each stays readable and the
    // `commands` result builder stays well under the type-checker's limits.

    @ViewBuilder
    private var fileMenuItems: some View {
        CommandItem("New Tab", .newTab, "t")

        // App-level, not a BrowserCommand: these must work even when every
        // browser window is closed, so they never go through the key-window
        // routing that all the other commands use.
        Button("New Window") {
            openBrowserWindow(isPrivate: false)
        }
        .keyboardShortcut("n", modifiers: .command)

        Button("New Incognito Window") {
            openBrowserWindow(isPrivate: true)
        }
        .keyboardShortcut("n", modifiers: [.command, .shift])

        Divider()

        CommandItem("Close Tab", .closeTab, "w")

        Divider()

        Button("Load Extension…") {
            loadExtensionFromOpenPanel()
        }
    }

    @ViewBuilder
    private var editMenuItems: some View {
        Divider()
        CommandItem("Find in Page…", .findInPage, "f")
        CommandItem("Command Palette…", .showCommandPalette, "k")
        Divider()
        CommandItem("Auto-Fill Password", .autoFillPassword, "\\")
    }

    @ViewBuilder
    private var viewMenuItems: some View {
        CommandItem("Reload Page", .reloadPage, "r")
        CommandItem("Stop Loading", .stopLoading, ".")

        Divider()

        CommandItem("Actual Size", .actualSize, "0")
        // Two entries, ONE command: `+` is ⌘⇧= on most layouts, so binding it
        // alone leaves the ⌘= that Chrome, Safari and Firefox all accept doing
        // nothing. SwiftUI can't hang an alternate key equivalent off a single
        // item, so the alias is its own row — the command is still declared
        // once, only the key equivalent is doubled.
        CommandItem("Zoom In", .zoomIn, "=")
        CommandItem("Zoom In", .zoomIn, "+")
        CommandItem("Zoom Out", .zoomOut, "-")

        Divider()

        CommandItem("Toggle Bookmark Bar", .toggleBookmarkBar, "b", [.command, .shift])
        CommandItem("Toggle Vertical Tab Bar", .toggleVerticalTabs, "v", [.command, .option])
        CommandItem("Toggle Split View", .toggleSplitView, "\\", [.command, .shift])

        Divider()

        CommandItem("Toggle Reader", .toggleReaderMode, "r", [.command, .shift])
        CommandItem("Focus Address Bar", .focusAddressBar, "l")

        Divider()

        CommandItem("Show Downloads", .showDownloads, "j", [.command, .shift])
    }

    @ViewBuilder
    private var tabsMenuItems: some View {
        CommandItem("Show Next Tab", .selectNextTab, .tab, .control)
        CommandItem("Show Previous Tab", .selectPreviousTab, .tab, [.control, .shift])

        Divider()

        // Cmd+1…Cmd+8 select that tab; Cmd+9 selects the LAST tab, matching
        // Safari/Chrome (see BrowserViewModel.selectTab(at:)).
        ForEach(1...9, id: \.self) { index in
            if let command = BrowserCommand(rawValue: "selectTab\(index)") {
                CommandItem(
                    index == 9 ? "Show Last Tab" : "Show Tab \(index)",
                    command,
                    KeyEquivalent(Character(String(index)))
                )
            }
        }

        Divider()

        CommandItem("Search Tabs…", .searchTabs, "a", [.command, .shift])
    }

    @ViewBuilder
    private var historyMenuItems: some View {
        CommandItem("Back", .goBack, "[")
        CommandItem("Forward", .goForward, "]")

        Divider()

        CommandItem("Reopen Last Closed Tab", .reopenClosedTab, "t", [.command, .shift])

        Divider()

        CommandItem("Show All History", .showHistory, "y")
    }

    @ViewBuilder
    private var bookmarksMenuItems: some View {
        CommandItem("Add Bookmark…", .addBookmark, "d")

        Divider()

        CommandItem("Show All Bookmarks", .showBookmarks, "b", [.command, .option])
    }

    @ViewBuilder
    private var toolsMenuItems: some View {
        // ⌘⌥4, not ⌘⇧4: macOS reserves ⇧⌘3/4/5/6 (and their ⌃ variants) for
        // system screen capture and consumes them before the app ever sees the
        // event, so the old binding could never fire. ⌘⌥4 keeps the "4" muscle
        // memory and is unclaimed both by the system and by Cherry. ⌘⇧S was the
        // other candidate, rejected because it's universally Save As — the kind
        // of latent collision this whole task exists to remove.
        CommandItem("Take Screenshot", .captureScreenshot, "4", [.command, .option])
        CommandItem("Toggle Focus Mode", .toggleFocusMode, "f", [.command, .shift])
        CommandItem("Ask This Page", .askThisPage, "k", [.command, .shift])
    }

    @ViewBuilder
    private var developMenuItems: some View {
        CommandItem("Show Web Inspector", .showWebInspector, "i", [.command, .option])
        CommandItem("Show JavaScript Console", .showConsole, "c", [.command, .option])

        Divider()

        CommandItem("View Page Source", .viewSource, "u")
    }
}

// MARK: - Menu Item

/// A menu item that posts a `BrowserCommand`. Every shortcut-bearing item in
/// Cherry's menu bar is one of these, so the shortcut, the title and the action
/// are declared together exactly once.
private struct CommandItem: View {
    let title: String
    let command: BrowserCommand
    let key: KeyEquivalent
    let modifiers: EventModifiers

    init(
        _ title: String,
        _ command: BrowserCommand,
        _ key: KeyEquivalent,
        _ modifiers: EventModifiers = .command
    ) {
        self.title = title
        self.command = command
        self.key = key
        self.modifiers = modifiers
    }

    var body: some View {
        Button(title) { command.post() }
            .keyboardShortcut(key, modifiers: modifiers)
    }
}

// MARK: - Opening Windows

/// The single implementation of "open another browser window". Used by File ▸
/// New Window / New Incognito Window (⌘N / ⌘⇧N), the Dock menu, and
/// `BrowserViewModel.openPrivateWindow()` — previously three near-identical
/// copies, one of which (the ⌘N menu item) was an empty closure.
@MainActor
func openBrowserWindow(isPrivate: Bool) {
    let hostingView = cherryHostingView(BrowserView(isPrivate: isPrivate))

    let window = DetachedWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )
    window.contentView = hostingView
    configureBrowserWindow(window)
    window.title = isPrivate ? "Incognito" : "Cherry"

    let delegate = DetachedWindowDelegate()
    window.delegate = delegate
    BrowserViewModel.detachedWindows.append(window)
    BrowserViewModel.detachedWindowDelegates.append(delegate)

    window.center()
    window.makeKeyAndOrderFront(nil)
}

/// Applies Cherry's chrome-less window look. Shared by `AppDelegate` (for the
/// `WindowGroup` windows) and `openBrowserWindow(isPrivate:)`.
@MainActor
func configureBrowserWindow(_ window: NSWindow) {
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.isMovableByWindowBackground = false
    window.isMovable = false
    window.backgroundColor = .clear
    window.isOpaque = false
    window.titlebarSeparatorStyle = .none

    window.standardWindowButton(.closeButton)?.isHidden = false
    window.standardWindowButton(.miniaturizeButton)?.isHidden = false
    window.standardWindowButton(.zoomButton)?.isHidden = false

    // The caret/selection colour for every text field in this window; see
    // AccentTextSelection. Here rather than per field, for the same reason
    // the tint lives at the window root.
    AccentTextSelection.apply(to: window)
}

// MARK: - Load Extension…

/// Opens a file/folder picker for a `.xpi`/`.zip` WebExtension or an unpacked
/// extension directory, then loads it into the app-global `ExtensionManager`
/// (same flow the Extensions settings page's "Load Extension…" button uses).
/// Success/failure is reported via a plain alert.
@MainActor
func loadExtensionFromOpenPanel() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Load"
    panel.message = "Choose a WebExtension folder, or a .xpi/.zip file"
    if let xpiType = UTType(filenameExtension: "xpi") {
        panel.allowedContentTypes = [xpiType, .zip]
    } else {
        panel.allowedContentTypes = [.zip]
    }

    guard panel.runModal() == .OK, let url = panel.url else { return }

    Task { @MainActor in
        do {
            let loaded = try await ExtensionManager.shared.loadExtension(from: url)
            presentExtensionAlert(title: "Extension Loaded", message: loaded.displayName, style: .informational)
        } catch {
            presentExtensionAlert(title: "Couldn't Load Extension", message: error.localizedDescription, style: .warning)
        }
    }
}

/// Opens `url` in a new tab of an existing (non-private) Cherry browser
/// window — used by the Settings links to addons.mozilla.org, so browsing for
/// themes/add-ons happens in Cherry itself. Prefers the key window's browser;
/// falls back to any open one, and only hands off to the default system
/// browser if no Cherry browser window exists at all (e.g. every window was
/// closed while Settings stayed open).
@MainActor
func openInNewCherryTab(_ url: URL) {
    let viewModels = BrowserViewModel.windowViewModels.values.filter { !$0.isPrivateMode }
    let target = CommandRouting.preferringKeyWindow(
        Array(viewModels),
        keyWindow: NSApp.keyWindow,
        window: { $0.associatedWindow }
    )
    guard let target else {
        NSWorkspace.shared.open(url)
        return
    }
    target.tabManager.newTab(url: url)
    target.associatedWindow?.makeKeyAndOrderFront(nil)
}

@MainActor
private func presentExtensionAlert(title: String, message: String, style: NSAlert.Style) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = style
    alert.runModal()
}

// MARK: - App Delegate to configure windows

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Pre-compile ad blocker rules so they're ready before the first tab loads.
        // This ensures consent platform whitelists and Cloudflare exceptions are active
        // from the very first page load.
        if SettingsManager.shared.adBlockEnabled {
            Task { @MainActor in
                await AdBlockManager.shared.ensureRulesCompiled()
            }
        }

        // Reload every persisted+enabled extension as early as possible so
        // their content scripts are ready to inject once the first window's
        // tabs get announced (`ExtensionManager.windowOpened`, called from
        // `WindowRegistrar`, re-fires on every SwiftUI update pass — so it
        // still picks up the window even if this finishes slightly later).
        Task { @MainActor in
            await ExtensionManager.shared.reloadPersistedExtensions()
        }

        for window in NSApplication.shared.windows {
            configureWindow(window)
        }

        // AppKit hands the shared field editor from control to control and
        // reconfigures it on the way (`NSCell.setUpFieldEditorAttributes`), so
        // re-assert the accent caret/selection each time editing starts rather
        // than trusting the once-per-window pass to survive.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textDidBeginEditing(_:)),
            name: NSControl.textDidBeginEditingNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidEnterFullScreen(_:)),
            name: NSWindow.didEnterFullScreenNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidExitFullScreen(_:)),
            name: NSWindow.didExitFullScreenNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Save session for all non-private windows
        for (_, vm) in BrowserViewModel.windowViewModels {
            guard !vm.isPrivateMode else { continue }
            vm.saveSessionForRestore()
            break  // Only save the primary (first) window's session
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        for window in NSApplication.shared.windows {
            guard window.contentView != nil else { continue }
            configureWindow(window)
        }
    }

    // MARK: - Dock Menu

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()

        let newWindowItem = NSMenuItem(title: "New Window", action: #selector(openNewWindow), keyEquivalent: "")
        newWindowItem.target = self
        menu.addItem(newWindowItem)

        let incognitoItem = NSMenuItem(title: "New Incognito Window", action: #selector(openIncognitoWindow), keyEquivalent: "")
        incognitoItem.target = self
        menu.addItem(incognitoItem)

        return menu
    }

    @objc private func openNewWindow() {
        openBrowserWindow(isPrivate: false)
    }

    @objc private func openIncognitoWindow() {
        openBrowserWindow(isPrivate: true)
    }

    private func configureWindow(_ window: NSWindow) {
        configureBrowserWindow(window)
    }

    /// `NSControl` puts the field editor it is about to use in the
    /// notification's user info under `"NSFieldEditor"` (an AppKit string key
    /// with no Swift symbol).
    @objc private func textDidBeginEditing(_ notification: Notification) {
        guard let editor = notification.userInfo?["NSFieldEditor"] as? NSTextView else { return }
        MainActor.assumeIsolated { AccentTextSelection.apply(to: editor) }
    }

    @objc private func windowDidEnterFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
    }

    @objc private func windowDidExitFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        configureWindow(window)
    }
}

// MARK: - Notification Names

// The per-command notifications this file used to declare are gone: every user
// command now travels as a `BrowserCommand` over `.browserCommand`. What's left
// are the three EVENTS the browser reports to itself — they're not commands, so
// they have no menu item and no shortcut.

extension Notification.Name {
    /// Posted by `WebViewWrapper` from a page's "Inspect Element" context menu,
    /// to surface the dev tools panel on the element it just selected.
    static let showConsole = Notification.Name("showConsole")
    /// Posted by `WebViewWrapper` when Focus Mode blocks a navigation.
    static let siteBlocked = Notification.Name("CherrySiteBlocked")
    /// Posted by `FocusModeManager` when a focus session ends.
    static let focusModeSessionEnded = Notification.Name("CherryFocusModeSessionEnded")
}
