//
//  ExtensionManager.swift
//  Internet Browser
//

import AppKit
import WebKit
import Observation

/// One row of the persisted extension index (`Extensions/index.json`) —
/// enough to reload the extension's managed copy and re-create its context
/// (keyed by the same stable `id`) on a later launch, without depending on
/// the user's original file/folder location.
struct PersistedExtensionRecord: Codable {
    let id: String
    var displayName: String
    var packageFileName: String
    var enabled: Bool
}

/// App-global owner of the single `WKWebExtensionController` and every
/// installed WebExtension context. All open browser windows share one
/// controller — there is no per-window isolation in v1a. Every extension
/// loaded via `loadExtension(from:)` is copied into an app-managed directory
/// and its record persisted, so `reloadPersistedExtensions()` can bring it
/// back on the next launch (see `Features/Extensions/`).
@MainActor
@Observable
final class ExtensionManager: NSObject {
    static let shared = ExtensionManager()

    /// The controller every extension context is loaded into, built on the
    /// DEFAULT (persistent, non-unique) configuration — exactly what plain
    /// `WKWebExtensionController()` uses, so every extension's existing
    /// WebKit-side storage stays where it was — with one thing added:
    /// Cherry's user-agent product token.
    ///
    /// WebKit builds every extension popup, options page and background page
    /// from `configuration.webViewConfiguration`, which is a SEPARATE
    /// configuration from the one tabs get. Left untouched it carries no
    /// `applicationNameForUserAgent` at all, so extension pages presented a
    /// bare `AppleWebKit/605.1.15` user agent with no product token while
    /// every tab in the same window presented Safari's. Extensions that sniff
    /// the user agent to decide which browser they are running in matched
    /// nothing and took their "unknown browser" path — measured on Bitwarden,
    /// whose popup threw inside Angular's dependency injection and never left
    /// its loading shell until the token was there.
    ///
    /// The configuration is read-modify-written rather than replaced: the
    /// property is `copy`, so mutating the value the getter hands back is not
    /// enough on its own, and building a blank `WKWebViewConfiguration`
    /// instead would discard whatever else WebKit had defaulted into it.
    /// `init(configuration:)` copies, so this is the only chance to set it.
    let controller: WKWebExtensionController

    /// Every extension the app knows about, whether or not it's currently
    /// loaded into the controller — a disabled extension has `context ==
    /// nil` but is still listed here (and in the persisted index) so the
    /// management UI can show and re-enable it. Backs `loadedExtensions`.
    private(set) var installedExtensions: [InstalledExtension] = []

    /// The enabled/active subset of `installedExtensions` — what the toolbar
    /// (`NavigationBarView`, `ExtensionToolbarButton`) cares about, since only
    /// a loaded context has an `action(for:)`/popup to show.
    var loadedExtensions: [LoadedExtension] {
        installedExtensions.compactMap { installed in
            guard let webExtension = installed.webExtension, let context = installed.context else { return nil }
            return LoadedExtension(id: installed.id, webExtension: webExtension, context: context)
        }
    }

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
        /// Same value as the owning `InstalledExtension.id` / persisted
        /// record id / `context.uniqueIdentifier` — one stable identity
        /// shared across the whole extension's lifetime.
        let id: String
        let webExtension: WKWebExtension
        let context: WKWebExtensionContext

        @MainActor
        var displayName: String { webExtension.displayName ?? "Untitled Extension" }
    }

    /// One entry in the management UI / persisted index: an extension the
    /// app has installed, whether currently enabled (loaded) or not.
    ///
    /// `webExtension` is `nil` only transiently, during launch-time reload,
    /// between the placeholder being seeded (from the persisted record
    /// alone) and its `WKWebExtension(resourceBaseURL:)` init resolving —
    /// see `reloadPersistedExtensions()`. `context` is `nil` whenever the
    /// extension is disabled OR its `webExtension` hasn't loaded yet.
    struct InstalledExtension: Identifiable {
        var record: PersistedExtensionRecord
        var webExtension: WKWebExtension?
        var context: WKWebExtensionContext?

        /// Why this extension's package could not be loaded at all, if it
        /// could not. Set only by launch-time reload, which has no caller to
        /// throw to — the interactive "Load Extension…" path throws instead,
        /// and never produces an installed entry.
        var loadFailure: String?

        var id: String { record.id }
        var enabled: Bool { record.enabled }

        /// What Cherry can honestly say about this extension's package —
        /// crucially, whether a manifest entry WebKit dropped is a warning
        /// against a running extension or an actual load failure. See
        /// `ExtensionPackageStatus`.
        @MainActor
        var packageStatus: ExtensionPackageStatus {
            ExtensionPackageStatus.of(
                hasPackage: webExtension != nil,
                droppedEntries: webExtension.map(ExtensionManager.droppedEntries(of:)) ?? [],
                loadFailure: loadFailure
            )
        }

        @MainActor
        var displayName: String { webExtension?.displayName ?? record.displayName }

        @MainActor
        var version: String? { webExtension?.version }

        @MainActor
        var icon: NSImage? { webExtension?.icon(for: NSSize(width: 32, height: 32)) }
    }

    private override init() {
        controller = Self.makeController()
        super.init()
        controller.delegate = self
    }

    /// Builds `controller` — see the property's own documentation for why the
    /// user agent has to be attached here and nowhere later.
    private static func makeController() -> WKWebExtensionController {
        let configuration = WKWebExtensionController.Configuration.default()
        // `null_resettable`: the getter always hands back a configuration, but
        // it imports as an optional, so the empty case is spelled out rather
        // than force-unwrapped.
        let webViewConfiguration = configuration.webViewConfiguration ?? WKWebViewConfiguration()
        BrowserUserAgent.apply(to: webViewConfiguration)
        configuration.webViewConfiguration = webViewConfiguration
        return WKWebExtensionController(configuration: configuration)
    }

    // MARK: - What the parser dropped

    /// The parts of `webExtension`'s manifest WebKit could not use, in its
    /// own words — one string per entry in `WKWebExtension.errors`, which is
    /// the parse-time list of pieces it skipped while loading the rest of the
    /// extension. An extension with entries here is LOADED; see
    /// `ExtensionPackageStatus`.
    @MainActor
    static func droppedEntries(of webExtension: WKWebExtension) -> [String] {
        webExtension.errors.map(describe(_:))
    }

    /// A user-readable account of one WebKit error. WebKit puts the specific
    /// part ("content_scripts entry has no specified matches") sometimes in
    /// the description and sometimes in the failure reason or the debug
    /// description, so all three are gathered — a warning that doesn't say
    /// WHAT was dropped isn't worth showing.
    static func describe(_ error: any Error) -> String {
        let nsError = error as NSError
        var parts = [nsError.localizedDescription]
        for extra in [nsError.localizedFailureReason, nsError.userInfo[NSDebugDescriptionErrorKey] as? String] {
            guard let extra, !extra.isEmpty, !parts.contains(where: { $0.contains(extra) }) else { continue }
            parts.append(extra)
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Persistence

    /// `Application Support/<bundle id, or "Cherry">/Extensions/` — created
    /// on first access. Each installed extension gets its own `<id>/`
    /// subfolder holding a COPY of its package (never the user's original
    /// file/folder, which may move or be deleted before the next launch),
    /// plus one shared `index.json` listing every installed extension's
    /// `PersistedExtensionRecord`.
    /// Internal rather than private so tests can check that a FAILED load
    /// leaves nothing behind in it.
    static let extensionsDirectory: URL = {
        let fileManager = FileManager.default
        let base = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fileManager.temporaryDirectory
        let appDirectoryName = Bundle.main.bundleIdentifier ?? "Cherry"
        let directory = base
            .appendingPathComponent(appDirectoryName, isDirectory: true)
            .appendingPathComponent("Extensions", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    private static var indexFileURL: URL { extensionsDirectory.appendingPathComponent("index.json") }

    private static func managedPackageURL(for record: PersistedExtensionRecord) -> URL {
        extensionsDirectory
            .appendingPathComponent(record.id, isDirectory: true)
            .appendingPathComponent(record.packageFileName)
    }

    private static func loadPersistedRecords() -> [PersistedExtensionRecord] {
        guard let data = try? Data(contentsOf: indexFileURL) else { return [] }
        return (try? JSONDecoder().decode([PersistedExtensionRecord].self, from: data)) ?? []
    }

    private func persistRecords() {
        guard let data = try? JSONEncoder().encode(installedExtensions.map(\.record)) else { return }
        try? data.write(to: Self.indexFileURL, options: .atomic)
    }

    /// Copies `sourceURL` (a `.xpi`/`.zip` file OR an unpacked extension
    /// directory) into `id`'s managed subfolder and returns the copy's URL —
    /// everything downstream (the `WKWebExtension` itself, and every future
    /// launch's reload) reads from this managed copy, never the original.
    private func copyIntoManagedDirectory(from sourceURL: URL, id: String) throws -> URL {
        let fileManager = FileManager.default
        let extensionDirectory = Self.extensionsDirectory.appendingPathComponent(id, isDirectory: true)
        try fileManager.createDirectory(at: extensionDirectory, withIntermediateDirectories: true)
        let destination = extensionDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: sourceURL, to: destination)
        return destination
    }

    /// Creates a context for `webExtension` keyed by the stable `id` (rather
    /// than the SDK's own random default) — `WKWebExtensionContext.uniqueIdentifier`
    /// is what WebKit uses to key that extension's own persisted storage
    /// under the controller's default (persistent) configuration, so reusing
    /// the same `id` across launches is what keeps that storage intact —
    /// auto-grants every requested permission/host pattern (no prompt UI yet
    /// — see the delegate's prompt methods below), then loads it.
    ///
    /// Deliberately does NOT also grant `WKWebExtension.MatchPattern.allURLs()`
    /// — that would give every loaded extension universal host access
    /// regardless of what it actually declared needing.
    private func makeLoadedContext(for webExtension: WKWebExtension, id: String) throws -> WKWebExtensionContext {
        let context = WKWebExtensionContext(for: webExtension)
        context.uniqueIdentifier = id

        for pattern in webExtension.requestedPermissionMatchPatterns {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
        for permission in webExtension.requestedPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }

        try controller.load(context)
        return context
    }

    /// Runs the "announce every already-open window/tab" sweep exactly once
    /// — shared by the very first `loadExtension` call and launch-time
    /// reload, so content scripts inject into tabs that were open before any
    /// extension finished loading. See `didAnnounceInitialState`.
    private func announceInitialStateIfNeeded() {
        guard !didAnnounceInitialState else { return }
        announceExistingWindowsAndTabs()
        didAnnounceInitialState = true
    }

    private func clearPendingPopupAnchors(for context: WKWebExtensionContext) {
        let contextID = ObjectIdentifier(context)
        pendingPopupAnchors = pendingPopupAnchors.filter { $0.key.context != contextID }
    }

    // MARK: - Load / Unload

    /// Loads a WebExtension the user picked (via "Load Extension…" — the
    /// File menu or the management UI) from a `.xpi`/`.zip` file or an
    /// unpacked directory: copies it into the managed extensions directory,
    /// persists its record (enabled by default), loads its context, then
    /// announces every already-open window/tab so content scripts inject
    /// into pages that were loaded before this call.
    @discardableResult
    func loadExtension(from fileURL: URL) async throws -> LoadedExtension {
        let id = UUID().uuidString
        let packageURL = try copyIntoManagedDirectory(from: fileURL, id: id)

        // The managed copy is made BEFORE WebKit is asked to parse it, so a
        // package WebKit refuses would otherwise leave its copy in the
        // extensions directory forever with no record in `index.json`
        // pointing at it — an orphan nothing can enable, disable or remove.
        // A failed load leaves nothing behind.
        let webExtension: WKWebExtension
        let context: WKWebExtensionContext
        do {
            webExtension = try await WKWebExtension(resourceBaseURL: packageURL)
            context = try makeLoadedContext(for: webExtension, id: id)
        } catch {
            try? FileManager.default.removeItem(
                at: Self.extensionsDirectory.appendingPathComponent(id, isDirectory: true)
            )
            throw error
        }

        let record = PersistedExtensionRecord(
            id: id,
            displayName: webExtension.displayName ?? packageURL.deletingPathExtension().lastPathComponent,
            packageFileName: packageURL.lastPathComponent,
            enabled: true
        )
        installedExtensions.append(InstalledExtension(record: record, webExtension: webExtension, context: context))
        persistRecords()
        announceInitialStateIfNeeded()

        return LoadedExtension(id: id, webExtension: webExtension, context: context)
    }

    /// Reloads every persisted extension from its managed copy — called once
    /// early at app launch (see `AppDelegate.applicationDidFinishLaunching`).
    ///
    /// Runs in two passes so `installedExtensions` (and therefore whatever
    /// `persistRecords()` writes) is NEVER a partial view of `index.json`:
    ///
    /// 1. Synchronous pass, no `await` anywhere in it: seeds one placeholder
    ///    `InstalledExtension` per persisted record whose managed copy still
    ///    exists (`webExtension`/`context` both `nil` for now). By the time
    ///    this method reaches its first `await`, `installedExtensions`
    ///    already holds the FULL persisted set — so if the user triggers
    ///    Load/toggle/Remove from the Settings UI while pass 2 is still
    ///    mid-flight, that call's `persistRecords()` write includes every
    ///    record, not just the ones pass 2 has gotten to yet. (Without this,
    ///    a concurrent `persistRecords()` mid-loop would overwrite
    ///    `index.json` with only the records processed so far — silently
    ///    dropping the rest and orphaning their managed directories.)
    /// 2. Async pass: loads each placeholder's `WKWebExtension`, and — if
    ///    still enabled at that point — its context, UPDATING the existing
    ///    entry in place (matched by persisted `id`) rather than appending a
    ///    new one. A record whose managed copy has gone missing is skipped
    ///    in pass 1 (silently, rather than crashing launch); a record whose
    ///    `WKWebExtension` init fails is left as a context-less placeholder.
    ///
    ///    Never carries a numeric array index across the `await
    ///    WKWebExtension(resourceBaseURL:)` suspension point — a concurrent
    ///    `remove(extensionID:)` (the user clicking Remove in the Settings UI
    ///    while THIS record is still loading) can shrink/reorder
    ///    `installedExtensions` during that await, so an index captured
    ///    before it would either write into a different, unrelated entry
    ///    after the array shifted, or be out of bounds and crash. Instead,
    ///    the array is re-searched BY `id` once execution resumes after the
    ///    await, and skipped entirely if that id is no longer present — at
    ///    that point no context has been created yet, so there's nothing to
    ///    unload.
    func reloadPersistedExtensions() async {
        let records = Self.loadPersistedRecords()

        for record in records {
            guard FileManager.default.fileExists(atPath: Self.managedPackageURL(for: record).path) else { continue }
            installedExtensions.append(InstalledExtension(record: record, webExtension: nil, context: nil))
        }

        for record in records {
            // Cheap early-out: skip the (potentially slow) WKWebExtension
            // load entirely if this record was already removed before we
            // even got to it. Not load-bearing for correctness — the
            // re-resolve below is — just avoids wasted work.
            guard installedExtensions.contains(where: { $0.id == record.id }) else { continue }

            let webExtension: WKWebExtension
            do {
                webExtension = try await WKWebExtension(resourceBaseURL: Self.managedPackageURL(for: record))
            } catch {
                // Nobody to throw to here (this runs at launch, not from a
                // user action), and a silently blank row would look exactly
                // like an extension that loaded — so the reason is recorded
                // on the entry and the settings pane says it.
                if let index = installedExtensions.firstIndex(where: { $0.id == record.id }) {
                    installedExtensions[index].loadFailure = Self.describe(error)
                }
                continue
            }

            // Re-resolve by id AFTER the await, never reuse an index from
            // before it (see doc comment above).
            guard let index = installedExtensions.firstIndex(where: { $0.id == record.id }) else { continue }

            installedExtensions[index].webExtension = webExtension
            if installedExtensions[index].record.enabled {
                installedExtensions[index].context = try? makeLoadedContext(for: webExtension, id: record.id)
            }
        }

        if installedExtensions.contains(where: { $0.context != nil }) {
            announceInitialStateIfNeeded()
        }
    }

    /// Enables or disables an installed extension: loads/unloads its context
    /// with the controller and persists the flag, so a disabled extension is
    /// remembered as disabled (not reloaded) on the next launch.
    func setEnabled(_ enabled: Bool, forExtensionID id: String) {
        guard let index = installedExtensions.firstIndex(where: { $0.id == id }),
              installedExtensions[index].enabled != enabled else { return }

        installedExtensions[index].record.enabled = enabled

        if enabled {
            // If `webExtension` hasn't finished loading yet (this entry is
            // still a launch-time-reload placeholder — see
            // `reloadPersistedExtensions()`), there's nothing to load a
            // context FOR yet. That method's async pass re-reads this
            // record's (now-updated) `enabled` flag once the extension
            // itself finishes loading and creates the context then.
            if let webExtension = installedExtensions[index].webExtension,
               let context = try? makeLoadedContext(for: webExtension, id: id) {
                installedExtensions[index].context = context
                announceInitialStateIfNeeded()
            }
        } else if let context = installedExtensions[index].context {
            try? controller.unload(context)
            clearPendingPopupAnchors(for: context)
            installedExtensions[index].context = nil
        }

        persistRecords()
    }

    /// Unloads (if currently loaded), deletes the managed copy, and drops
    /// the persisted record for good — the extension is gone and stays gone
    /// across future launches.
    func remove(extensionID id: String) {
        guard let index = installedExtensions.firstIndex(where: { $0.id == id }) else { return }

        if let context = installedExtensions[index].context {
            try? controller.unload(context)
            clearPendingPopupAnchors(for: context)
        }
        installedExtensions.remove(at: index)
        try? FileManager.default.removeItem(at: Self.extensionsDirectory.appendingPathComponent(id, isDirectory: true))
        persistRecords()
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
        let focused = CommandRouting.preferringKeyWindow(
            extensionVisibleViewModels,
            keyWindow: NSApp.keyWindow,
            window: { $0.associatedWindow }
        )
        return focused.map { windowAdapter(for: $0) }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
    ) {
        // Argument form, not a trailing closure: a trailing closure inside a
        // `guard let … else` condition doesn't parse.
        guard let viewModel = CommandRouting.preferringKeyWindow(
            extensionVisibleViewModels,
            keyWindow: NSApp.keyWindow,
            window: { $0.associatedWindow }
        ) else {
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
