//
//  ExtensionManager.swift
//  Internet Browser
//

import AppKit
import WebKit

/// App-global owner of the single `WKWebExtensionController` and every loaded
/// WebExtension context. All open browser windows share one controller —
/// there is no per-window isolation in v1a. Extensions loaded here are kept
/// in memory only; nothing is persisted across app launches yet.
@MainActor
final class ExtensionManager: NSObject {
    static let shared = ExtensionManager()

    let controller = WKWebExtensionController()

    private(set) var loadedExtensions: [LoadedExtension] = []

    /// One stable `WKWebExtensionWindow` adapter per `BrowserViewModel`, so the
    /// same object identity is reused across delegate calls (`didOpenWindow`,
    /// `openWindowsFor`, etc.) instead of creating a new wrapper every query.
    private var windowAdapters: [ObjectIdentifier: ExtensionWindowAdapter] = [:]

    struct LoadedExtension: Identifiable {
        let id = UUID()
        let webExtension: WKWebExtension
        let context: WKWebExtensionContext

        @MainActor
        var displayName: String { webExtension.displayName ?? "Untitled Extension" }
    }

    private override init() {
        super.init()
        controller.delegate = self
    }

    // MARK: - Load / Unload

    /// Loads a WebExtension from a `.xpi`/`.zip` file or an unpacked directory,
    /// auto-granting exactly the permissions and host patterns it *requests*
    /// (v1a has no permission prompt yet — see the delegate's prompt methods
    /// below), then announces every already-open window/tab so content
    /// scripts inject into pages that were loaded before this call.
    ///
    /// Deliberately does NOT also grant `WKWebExtension.MatchPattern.allURLs()`
    /// — that would give every loaded extension universal host access
    /// regardless of what it actually declared needing.
    @discardableResult
    func loadExtension(from fileURL: URL) async throws -> LoadedExtension {
        let webExtension = try await WKWebExtension(resourceBaseURL: fileURL)
        let context = WKWebExtensionContext(for: webExtension)

        for pattern in webExtension.requestedPermissionMatchPatterns {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
        for permission in webExtension.requestedPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }

        try controller.load(context)

        let loaded = LoadedExtension(webExtension: webExtension, context: context)
        loadedExtensions.append(loaded)

        announceExistingWindowsAndTabs()

        return loaded
    }

    func unload(_ loaded: LoadedExtension) {
        try? controller.unload(loaded.context)
        loadedExtensions.removeAll { $0.id == loaded.id }
    }

    // MARK: - Window adapters

    func windowAdapter(for viewModel: BrowserViewModel) -> ExtensionWindowAdapter {
        let key = ObjectIdentifier(viewModel)
        if let existing = windowAdapters[key] {
            return existing
        }
        let adapter = ExtensionWindowAdapter(viewModel: viewModel)
        windowAdapters[key] = adapter
        return adapter
    }

    /// Windows extensions are allowed to see. v1a has no per-extension
    /// "allow in private browsing" opt-in (`WKWebExtensionContext.hasAccessToPrivateData`
    /// is left at its default `false` for every context), so private/incognito
    /// windows are excluded from every extension-facing API entirely, rather
    /// than relying solely on that flag — the same window/tab is also never
    /// wired to `configuration.webExtensionController` in `WebViewWrapper`.
    private var extensionVisibleViewModels: [BrowserViewModel] {
        BrowserViewModel.windowViewModels.values.filter { !$0.isPrivateMode }
    }

    /// Registers every currently open (non-private) window and tab with the
    /// controller. Needed right after loading a new extension, since content
    /// scripts only inject into tabs the controller already knows about —
    /// otherwise tabs opened before this extension was loaded would be skipped.
    private func announceExistingWindowsAndTabs() {
        for viewModel in extensionVisibleViewModels {
            let adapter = windowAdapter(for: viewModel)
            controller.didOpenWindow(adapter)
            for tab in viewModel.tabManager.tabs {
                controller.didOpenTab(tab)
            }
            if let active = viewModel.tabManager.focusedTab ?? viewModel.tabManager.selectedTab {
                controller.didActivateTab(active, previousActiveTab: nil)
            }
        }
    }

    // MARK: - Tab lifecycle notifications (called by TabManager)

    func tabOpened(_ tab: Tab) {
        controller.didOpenTab(tab)
    }

    func tabClosed(_ tab: Tab, windowIsClosing: Bool) {
        controller.didCloseTab(tab, windowIsClosing: windowIsClosing)
    }

    func tabActivated(_ tab: Tab, previous: Tab?) {
        controller.didActivateTab(tab, previousActiveTab: previous)
    }
}

// MARK: - WKWebExtensionControllerDelegate

extension ExtensionManager: WKWebExtensionControllerDelegate {
    func webExtensionController(
        _ controller: WKWebExtensionController,
        openWindowsFor context: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        extensionVisibleViewModels.map { windowAdapter(for: $0) }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        focusedWindowFor context: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        let keyWindow = NSApp.keyWindow
        let viewModels = extensionVisibleViewModels
        let focused = viewModels.first { $0.associatedWindow === keyWindow } ?? viewModels.first
        return focused.map { windowAdapter(for: $0) }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
    ) {
        let keyWindow = NSApp.keyWindow
        let viewModels = extensionVisibleViewModels
        guard let viewModel = (viewModels.first { $0.associatedWindow === keyWindow } ?? viewModels.first) else {
            completionHandler(nil, nil)
            return
        }
        let newTab = viewModel.tabManager.newTab(url: configuration.url)
        completionHandler(newTab, nil)
    }

    // v1a auto-allows every permission/URL/pattern prompt — a real prompt UI is a later chunk.

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        completionHandler(permissions, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        completionHandler(urls, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        completionHandler(matchPatterns, nil)
    }
}

// MARK: - ExtensionWindowAdapter

/// Exposes a `BrowserViewModel`'s tabs to WKWebExtension as a `WKWebExtensionWindow`,
/// without making `BrowserViewModel` itself an `NSObject` subclass.
final class ExtensionWindowAdapter: NSObject, WKWebExtensionWindow {
    weak var viewModel: BrowserViewModel?

    init(viewModel: BrowserViewModel) {
        self.viewModel = viewModel
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        viewModel?.tabManager.tabs ?? []
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        viewModel?.tabManager.focusedTab ?? viewModel?.tabManager.selectedTab
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool {
        viewModel?.isPrivateMode ?? false
    }
}
