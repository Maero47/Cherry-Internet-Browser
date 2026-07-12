//
//  ExtensionManager.swift
//  Internet Browser
//

import AppKit
import WebKit
import Observation

/// App-global owner of the single `WKWebExtensionController` and every loaded
/// WebExtension context. All open browser windows share one controller —
/// there is no per-window isolation in v1a. Extensions loaded here are kept
/// in memory only; nothing is persisted across app launches yet.
@MainActor
@Observable
final class ExtensionManager: NSObject {
    static let shared = ExtensionManager()

    let controller = WKWebExtensionController()

    private(set) var loadedExtensions: [LoadedExtension] = []

    /// Bumped on every `didUpdateAction` delegate call, for ANY extension
    /// context. `WKWebExtension.Action` values themselves aren't Observable —
    /// toolbar button views read this property (even though its value is
    /// unused) so SwiftUI re-renders them and re-fetches `action(for:)`
    /// whenever an extension changes its icon/badge/enabled state.
    private(set) var actionUpdateTick: Int = 0

    /// The toolbar button view to anchor the next popup presentation to, keyed
    /// by extension context AND tab. Set immediately before
    /// `performAction(for:tab:anchorView:)` calls into `context.performAction(for:)`,
    /// consumed by the `presentActionPopup` delegate callback that follows it
    /// synchronously. The controller (and every extension context) is shared
    /// across all windows, so keying by context alone would let a click in one
    /// window's button get overwritten by a click on the same extension's
    /// button in another window before either popup callback fires — the tab
    /// disambiguates which window's button actually triggered this popup.
    @ObservationIgnored
    private var pendingPopupAnchors: [PopupAnchorKey: NSView] = [:]

    /// Key for `pendingPopupAnchors`. `tab` is `nil` only for a default
    /// (no-tab) action, which can't collide across windows the way per-tab
    /// actions can.
    private struct PopupAnchorKey: Hashable {
        let context: ObjectIdentifier
        let tab: ObjectIdentifier?
    }

    /// One stable `WKWebExtensionWindow` adapter per `BrowserViewModel`, so the
    /// same object identity is reused across delegate calls (`didOpenWindow`,
    /// `openWindowsFor`, etc.) instead of creating a new wrapper every query.
    private var windowAdapters: [ObjectIdentifier: ExtensionWindowAdapter] = [:]

    /// Windows the controller has actually been told about via `didOpenWindow`
    /// (as opposed to merely having an adapter allocated). Every window must be
    /// announced exactly once per its lifetime, independent of how many
    /// extensions load — this tracks that so `windowOpened`/`windowClosed` and
    /// the initial-state announce (see `didAnnounceInitialState`) can't
    /// double-announce or double-close the same window.
    private var announcedWindows: Set<ObjectIdentifier> = []

    /// Whether `announceExistingWindowsAndTabs()` has already run once. It
    /// must run exactly once, on the FIRST `loadExtension` call, to register
    /// whatever windows/tabs already existed at that point — re-running it on
    /// every subsequent load would re-announce tabs the controller already
    /// knows about, which `didOpenTab`'s contract forbids. Windows/tabs
    /// created after this flips true are covered by `windowOpened`/`tabOpened`.
    private var didAnnounceInitialState = false

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

        // Only ever run once, on the very first extension load — see
        // `didAnnounceInitialState`. A second (or later) extension's content
        // scripts still reach already-open tabs, because `didOpenTab`/
        // `didOpenWindow` register a tab/window with the controller itself,
        // not with any one extension context.
        if !didAnnounceInitialState {
            announceExistingWindowsAndTabs()
            didAnnounceInitialState = true
        }

        return loaded
    }

    func unload(_ loaded: LoadedExtension) {
        try? controller.unload(loaded.context)
        loadedExtensions.removeAll { $0.id == loaded.id }
        let contextID = ObjectIdentifier(loaded.context)
        pendingPopupAnchors = pendingPopupAnchors.filter { $0.key.context != contextID }
    }

    // MARK: - Toolbar action + popup

    /// The extension's action for `tab` (or its default action if `tab` is
    /// `nil`), reflecting that tab's icon/badge/enabled state.
    func action(for loaded: LoadedExtension, tab: Tab?) -> WKWebExtension.Action? {
        loaded.context.action(for: tab)
    }

    /// Fires a toolbar button click: marks a user gesture on `tab` and either
    /// triggers the extension's action event or, if the action has a popup,
    /// requests it — which arrives back through the `presentActionPopup`
    /// delegate below. `anchorView` (the button's own NSView) is remembered
    /// so that callback knows where to anchor the popover. Only recorded when
    /// this action will actually present a popup — otherwise (a pure
    /// background/event action) `presentActionPopup` never fires and the
    /// entry would never get cleaned up. Falls back to the key window's
    /// content view if `anchorView` is nil (e.g. the button's backing
    /// `NSView` hadn't attached yet on a very first click), so the popup
    /// still appears near the toolbar instead of silently failing.
    func performAction(for loaded: LoadedExtension, tab: Tab?, anchorView: NSView?) {
        if let action = loaded.context.action(for: tab), action.presentsPopup {
            let key = PopupAnchorKey(context: ObjectIdentifier(loaded.context), tab: tab.map(ObjectIdentifier.init))
            pendingPopupAnchors[key] = anchorView ?? NSApp.keyWindow?.contentView
        }
        loaded.context.performAction(for: tab)
    }

    /// Presents `action`'s popup anchored to `anchor`. Prefers the
    /// ready-to-show `popupPopover` the SDK builds; falls back to wrapping
    /// `popupWebView` in a fresh `NSPopover` if that's unavailable.
    private func presentPopover(for action: WKWebExtension.Action, anchoredTo anchor: NSView) {
        guard anchor.window != nil else { return }

        // WebKit hands back a popover/popup web view with a ZERO contentSize —
        // shown as-is it looks empty even though the popup HTML is loaded. Give
        // it a non-zero starting size; WebKit then lays the popup web view out
        // and auto-fits the popover to the popup's real content. (Verified: a
        // zero-size popover renders blank; seeding a size makes it appear.)
        let defaultPopupSize = CGSize(width: 380, height: 520)

        let popover: NSPopover
        if let ready = action.popupPopover {
            if ready.contentSize.width < 1 || ready.contentSize.height < 1 {
                ready.contentSize = defaultPopupSize
            }
            popover = ready
        } else if let webView = action.popupWebView {
            let contentController = NSViewController()
            contentController.view = webView
            let fresh = NSPopover()
            fresh.contentViewController = contentController
            fresh.behavior = .transient
            let size = webView.frame.size
            fresh.contentSize = size == .zero ? CGSize(width: 320, height: 420) : size
            popover = fresh
        } else {
            return
        }

        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
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

    /// The `BrowserViewModel` whose `tabManager.tabs` contains `tab`, restricted
    /// to extension-visible (non-private) windows that have ALREADY been
    /// announced to the controller via `didOpenWindow` (i.e. present in
    /// `announcedWindows`) — shared by `windowAdapter(owningTab:)` and
    /// `isTabSelected(_:)`. `Tab` has no back-reference to its owning
    /// `BrowserViewModel`/`TabManager`, so this is the only way to go from a
    /// tab back to its window.
    ///
    /// A window registers in `BrowserViewModel.windowViewModels` synchronously
    /// in `init`, but only reaches `announcedWindows` later, once
    /// `windowOpened`/`announceWindow` actually calls `didOpenWindow`. Gating
    /// here keeps this lookup from ever handing WebKit a `WKWebExtensionWindow`
    /// it hasn't been told about yet — during that gap the tab's window simply
    /// isn't resolvable, matching how the tab itself isn't visible to
    /// `tabs.query` until announced either.
    private func owningViewModel(for tab: Tab) -> BrowserViewModel? {
        extensionVisibleViewModels.first { viewModel in
            announcedWindows.contains(ObjectIdentifier(viewModel)) &&
                viewModel.tabManager.tabs.contains { $0 === tab }
        }
    }

    /// The SAME `ExtensionWindowAdapter` already announced for `tab`'s window
    /// (see `windowAdapter(for:)`) — never a second adapter for the same
    /// window, so object identity stays consistent with what the controller
    /// was told via `didOpenWindow`. Backs `Tab.window(for:)`. Returns `nil`
    /// for a private window or a detached/transient tab that isn't in any
    /// open window's tab list.
    func windowAdapter(owningTab tab: Tab) -> ExtensionWindowAdapter? {
        owningViewModel(for: tab).map(windowAdapter(for:))
    }

    /// Whether `tab` is its window's active tab — the primary selection, or
    /// (in split view) the secondary pane's selection, since both panes are
    /// simultaneously on-screen and either can be the one an extension means
    /// by "active". Backs `Tab.isSelected(for:)`; kept in sync with
    /// `ExtensionWindowAdapter.activeTab(for:)`, which resolves to
    /// `focusedTab` (itself always either `selectedTab` or
    /// `secondarySelectedTab`).
    func isTabSelected(_ tab: Tab) -> Bool {
        guard let viewModel = owningViewModel(for: tab) else { return false }
        return viewModel.tabManager.selectedTab === tab || viewModel.tabManager.secondarySelectedTab === tab
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
    /// controller. Runs exactly once (see `didAnnounceInitialState`) — needed
    /// right after the FIRST extension loads, since content scripts only
    /// inject into tabs the controller already knows about, and otherwise
    /// tabs opened before any extension was loaded would be skipped forever.
    private func announceExistingWindowsAndTabs() {
        for viewModel in extensionVisibleViewModels {
            announceWindow(viewModel)
        }
    }

    /// Tells the controller about one window and its current tabs, exactly
    /// once. Shared by the initial-state announce and `windowOpened`.
    private func announceWindow(_ viewModel: BrowserViewModel) {
        let key = ObjectIdentifier(viewModel)
        guard !announcedWindows.contains(key) else { return }
        announcedWindows.insert(key)

        let adapter = windowAdapter(for: viewModel)
        controller.didOpenWindow(adapter)
        for tab in viewModel.tabManager.tabs {
            controller.didOpenTab(tab)
        }
        if let active = viewModel.tabManager.focusedTab ?? viewModel.tabManager.selectedTab {
            controller.didActivateTab(active, previousActiveTab: nil)
        }
    }

    // MARK: - Window lifecycle notifications (called by BrowserView)

    /// A browser window became visible. No-op for private windows (see
    /// `extensionVisibleViewModels`) and for windows that existed before the
    /// first extension load — those are covered by `announceExistingWindowsAndTabs`
    /// instead, so this only fires for windows opened *after* that point.
    func windowOpened(_ viewModel: BrowserViewModel) {
        guard didAnnounceInitialState, !viewModel.isPrivateMode else { return }
        announceWindow(viewModel)
    }

    /// A browser window closed — tells the controller (only if it was ever
    /// announced) and drops the cached adapter so `windowAdapters` doesn't
    /// grow unboundedly across the app's lifetime.
    func windowClosed(_ viewModel: BrowserViewModel) {
        let key = ObjectIdentifier(viewModel)
        if announcedWindows.remove(key) != nil, let adapter = windowAdapters[key] {
            // Announce each still-open tab as removed BEFORE the window, so
            // extensions get tabs.onRemoved for them (closing a multi-tab
            // window via the red button / Cmd+Q never routes through
            // TabManager.closeTab per tab). In the tab-by-tab close path the
            // manager is already empty here, so this loop is a no-op — no
            // double-close. Private tabs were never announced; skip them.
            for tab in viewModel.tabManager.tabs where !tab.isPrivate {
                controller.didCloseTab(tab, windowIsClosing: true)
            }
            controller.didCloseWindow(adapter)
        }
        windowAdapters.removeValue(forKey: key)
    }

    // MARK: - Private-mode toggle reconciliation (called by BrowserViewModel)

    /// A window just switched from normal to private browsing. If it had
    /// been announced to the controller, tell the controller its tabs and
    /// itself are gone — otherwise the controller (and any extension that
    /// already saw `didOpenTab`/`didOpenWindow` for it) would keep believing
    /// a now-private, now-excluded window is still open forever. Must be
    /// called with the tab list as it stood BEFORE any tab identity swap
    /// (e.g. `BrowserViewModel.hardReplaceOnScreenTab`) — those are the exact
    /// `Tab` instances that were actually announced via `didOpenTab`.
    func windowBecamePrivate(_ viewModel: BrowserViewModel, tabs: [Tab]) {
        let key = ObjectIdentifier(viewModel)
        guard announcedWindows.remove(key) != nil, let adapter = windowAdapters[key] else { return }
        for tab in tabs {
            controller.didCloseTab(tab, windowIsClosing: true)
        }
        controller.didCloseWindow(adapter)
        windowAdapters.removeValue(forKey: key)
    }

    /// A window just switched from private to normal browsing — announce it
    /// (and its current tabs) exactly like a freshly opened window, since it
    /// was excluded from every extension-facing API while private and so was
    /// never previously known to the controller. No-ops until at least one
    /// extension has loaded (matches `windowOpened`).
    func windowBecameNormal(_ viewModel: BrowserViewModel) {
        guard didAnnounceInitialState else { return }
        announceWindow(viewModel)
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

    /// An action's icon/badge/label/enabled state changed — bump the tick so
    /// every toolbar button view (which reads it) re-renders and re-fetches
    /// its own `action(for:)`.
    func webExtensionController(
        _ controller: WKWebExtensionController,
        didUpdate action: WKWebExtension.Action,
        forExtensionContext context: WKWebExtensionContext
    ) {
        actionUpdateTick &+= 1
    }

    /// The extension requested its popup be shown (via `performAction(for:)`
    /// or its own scripts). Anchor it to whichever button view was recorded
    /// right before the triggering `performAction` call — resolved via
    /// `action.associatedTab` (not just the context, which is shared across
    /// every window) so a click in one window can't steal the anchor for a
    /// still-pending popup request from another window.
    func webExtensionController(
        _ controller: WKWebExtensionController,
        presentActionPopup action: WKWebExtension.Action,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        defer { completionHandler(nil) }
        let key = PopupAnchorKey(context: ObjectIdentifier(context), tab: (action.associatedTab as? Tab).map(ObjectIdentifier.init))
        guard let anchor = pendingPopupAnchors.removeValue(forKey: key) else { return }
        presentPopover(for: action, anchoredTo: anchor)
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
