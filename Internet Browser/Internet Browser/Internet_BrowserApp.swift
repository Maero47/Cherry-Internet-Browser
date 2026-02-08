//
//  Internet_BrowserApp.swift
//  Internet Browser
//
//  Created by Mehmet Ali Dede on 7.02.2026.
//

import SwiftUI
import AppKit

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
            }

            // Edit menu additions
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Find in Page...") {
                    NotificationCenter.default.post(name: .findInPage, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
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
    }
}

// MARK: - App Delegate to configure windows

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        for window in NSApplication.shared.windows {
            configureWindow(window)
        }

        // Listen for fullscreen transitions to keep tab bar visible
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

    func applicationDidBecomeActive(_ notification: Notification) {
        for window in NSApplication.shared.windows {
            configureWindow(window)
        }
    }

    private func configureWindow(_ window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .windowBackgroundColor
        window.titlebarSeparatorStyle = .none

        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isHidden = false
    }

    @objc private func windowDidEnterFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        // In fullscreen, prevent the toolbar/titlebar from auto-hiding over our content
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
    static let showWebInspector = Notification.Name("showWebInspector")
    static let showConsole = Notification.Name("showConsole")
    static let viewSource = Notification.Name("viewSource")
}
