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
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            // File menu
            CommandGroup(replacing: .newItem) {
                Button("New Tab") {
                    NotificationCenter.default.post(name: .newTab, object: nil)
                }
                .keyboardShortcut("t", modifiers: .command)

                Button("New Window") {
                    // Will open a new window
                }
                .keyboardShortcut("n", modifiers: .command)

                Divider()

                Button("Close Tab") {
                    NotificationCenter.default.post(name: .closeTab, object: nil)
                }
                .keyboardShortcut("w", modifiers: .command)

                Divider()

                Button("Load Extension…") {
                    loadExtensionFromOpenPanel()
                }
            }

            // Edit menu additions
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Find in Page...") {
                    NotificationCenter.default.post(name: .findInPage, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)

                Button("Command Palette...") {
                    NotificationCenter.default.post(name: .showCommandPalette, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)
            }

            // View menu
            CommandGroup(replacing: .toolbar) {
                Button("Reload Page") {
                    NotificationCenter.default.post(name: .reloadPage, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("Stop Loading") {
                    NotificationCenter.default.post(name: .stopLoading, object: nil)
                }
                .keyboardShortcut(".", modifiers: .command)

                Divider()

                Button("Actual Size") {
                    NotificationCenter.default.post(name: .actualSize, object: nil)
                }
                .keyboardShortcut("0", modifiers: .command)

                Button("Zoom In") {
                    NotificationCenter.default.post(name: .zoomIn, object: nil)
                }
                .keyboardShortcut("+", modifiers: .command)

                Button("Zoom Out") {
                    NotificationCenter.default.post(name: .zoomOut, object: nil)
                }
                .keyboardShortcut("-", modifiers: .command)

                Divider()

                Button("Show Downloads") {
                    NotificationCenter.default.post(name: .showDownloads, object: nil)
                }
                .keyboardShortcut("j", modifiers: [.command, .shift])

                Divider()

                Button("Auto-Fill Password") {
                    NotificationCenter.default.post(name: .autoFillPassword, object: nil)
                }
                .keyboardShortcut("\\", modifiers: .command)
            }

            // History menu
            CommandMenu("History") {
                Button("Back") {
                    NotificationCenter.default.post(name: .goBack, object: nil)
                }
                .keyboardShortcut("[", modifiers: .command)

                Button("Forward") {
                    NotificationCenter.default.post(name: .goForward, object: nil)
                }
                .keyboardShortcut("]", modifiers: .command)

                Divider()

                Button("Reopen Last Closed Tab") {
                    NotificationCenter.default.post(name: .reopenClosedTab, object: nil)
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])

                Divider()

                Button("Show All History") {
                    NotificationCenter.default.post(name: .showHistory, object: nil)
                }
                .keyboardShortcut("y", modifiers: .command)
            }

            // Bookmarks menu
            CommandMenu("Bookmarks") {
                Button("Add Bookmark") {
                    NotificationCenter.default.post(name: .addBookmark, object: nil)
                }
                .keyboardShortcut("d", modifiers: .command)

                Divider()

                Button("Show All Bookmarks") {
                    NotificationCenter.default.post(name: .showBookmarks, object: nil)
                }
                .keyboardShortcut("b", modifiers: [.command, .option])
            }

            // Developer menu
            CommandMenu("Develop") {
                Button("Show Web Inspector") {
                    NotificationCenter.default.post(name: .showWebInspector, object: nil)
                }
                .keyboardShortcut("i", modifiers: [.command, .option])

                Button("Show JavaScript Console") {
                    NotificationCenter.default.post(name: .showConsole, object: nil)
                }
                .keyboardShortcut("c", modifiers: [.command, .option])

                Divider()

                Button("View Page Source") {
                    NotificationCenter.default.post(name: .viewSource, object: nil)
                }
                .keyboardShortcut("u", modifiers: .command)
            }
        }

        // Settings window (Cmd+,)
        Settings {
            SettingsView()
        }
    }
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
    let target = viewModels.first { $0.associatedWindow === NSApp.keyWindow } ?? viewModels.first
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
        let browserView = BrowserView()
        let hostingView = NSHostingView(rootView: browserView)

        let window = DetachedWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        configureWindow(window)
        window.title = "Cherry"

        let delegate = DetachedWindowDelegate()
        window.delegate = delegate
        BrowserViewModel.detachedWindows.append(window)
        BrowserViewModel.detachedWindowDelegates.append(delegate)

        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func openIncognitoWindow() {
        let browserView = BrowserView(isPrivate: true)
        let hostingView = NSHostingView(rootView: browserView)

        let window = DetachedWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        configureWindow(window)
        window.title = "Incognito"

        let delegate = DetachedWindowDelegate()
        window.delegate = delegate
        BrowserViewModel.detachedWindows.append(window)
        BrowserViewModel.detachedWindowDelegates.append(delegate)

        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func configureWindow(_ window: NSWindow) {
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

// MARK: - Notification Names for menu commands

extension Notification.Name {
    static let newTab = Notification.Name("newTab")
    static let closeTab = Notification.Name("closeTab")
    static let reloadPage = Notification.Name("reloadPage")
    static let stopLoading = Notification.Name("stopLoading")
    static let goBack = Notification.Name("goBack")
    static let goForward = Notification.Name("goForward")
    static let reopenClosedTab = Notification.Name("reopenClosedTab")
    static let findInPage = Notification.Name("findInPage")
    static let zoomIn = Notification.Name("zoomIn")
    static let zoomOut = Notification.Name("zoomOut")
    static let actualSize = Notification.Name("actualSize")
    static let showHistory = Notification.Name("showHistory")
    static let showBookmarks = Notification.Name("showBookmarks")
    static let addBookmark = Notification.Name("addBookmark")
    static let showDownloads = Notification.Name("showDownloads")
    static let showWebInspector = Notification.Name("showWebInspector")
    static let showConsole = Notification.Name("showConsole")
    static let viewSource = Notification.Name("viewSource")
    static let autoFillPassword = Notification.Name("autoFillPassword")
    static let showCommandPalette = Notification.Name("showCommandPalette")
    static let siteBlocked = Notification.Name("CherrySiteBlocked")
    static let focusModeSessionEnded = Notification.Name("CherryFocusModeSessionEnded")
}
