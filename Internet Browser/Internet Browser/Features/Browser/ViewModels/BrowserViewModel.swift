//
//  BrowserViewModel.swift
//  Cherry Browser
//

import SwiftUI
import WebKit
import Observation

enum SidebarContent {
    case none
    case history
    case bookmarks
    case downloads
}

@Observable
final class BrowserViewModel {
    var tabManager = TabManager()
    var searchEngine: SearchEngine { SettingsManager.shared.searchEngine }
    var showBookmarkBar: Bool {
        get { SettingsManager.shared.showBookmarkBar }
        set { SettingsManager.shared.showBookmarkBar = newValue }
    }
    var sidebarContent: SidebarContent = .none
    var showAddBookmark: Bool = false
    var isFullScreen: Bool = false
    var showTabSearch: Bool = false
    var isPrivateMode: Bool = false
    var showPrivateModeAlert: Bool = false
    var showDownloadToast: Bool = false
    var toastDownloadID: UUID?
    var toastIsCompleted: Bool = false
    var popupBlockedCount: Int = 0
    var toastDismissTask: Task<Void, Never>?
    var useVerticalTabs: Bool {
        get { SettingsManager.shared.useVerticalTabs }
        set { SettingsManager.shared.useVerticalTabs = newValue }
    }
    /// Per-window collapse state for the vertical tab bar. Seeded from the
    /// persisted preference and written back on change so NEW windows open
    /// with the last-used state — but toggling here never yanks the sidebar
    /// of other already-open windows (the old global-only state made every
    /// window collapse at once, which read as the bars desyncing/jumping).
    var verticalTabBarCollapsed: Bool = SettingsManager.shared.verticalTabBarCollapsed {
        didSet { SettingsManager.shared.verticalTabBarCollapsed = verticalTabBarCollapsed }
    }

    let bookmarkRepository = BookmarkRepository.shared
    let historyRepository = HistoryRepository.shared
    let shortcutRepository = ShortcutRepository.shared
    let downloadRepository = DownloadRepository.shared
    let downloadManager = DownloadManager.shared
    let passwordManager = PasswordManager.shared
    let passwordRepository = PasswordRepository.shared

    var showAutoFillPopup: Bool = false

    // MARK: - HTTP authentication
    /// The sign-in request waiting on THIS window's sheet, if any. One at a
    /// time: a second challenge arriving while a sheet is up would replace the
    /// question in front of the user without them having answered the first.
    var pendingAuthPrompt: HTTPAuthPrompt?

    // MARK: - Find in Page
    // M2a: kept as ONE window-global query/count pair (not per-pane state) —
    // there's only one find bar/input on screen, so a second query would need
    // its own UI to be reachable at all. All find operations below act on
    // `tabManager.focusedTab`, and `refreshFindForFocusChange()` re-runs the
    // shared query against whichever pane is now focused. Each pane's DOM
    // highlights are independent (tracked per-tab via `Tab.findHelperInjected`)
    // and are never touched by the other pane's search.
    var showFindInPage: Bool = false
    var findQuery: String = ""
    var findCurrentMatch: Int = 0
    var findTotalMatches: Int = 0
    private var findDebounceTask: Task<Void, Never>?

    // MARK: - Reader Mode
    var showReaderMode: Bool = false
    var readerContent: ReaderContent? = nil

    // MARK: - QR Code
    var showQRCode: Bool = false

    // MARK: - PDF detection
    var isViewingPDF: Bool = false

    // MARK: - Status toast
    // A brief bottom-of-window message. Was screenshot-only; now also carries
    // the "zoom doesn't apply here" reply, so the icon travels with the text.
    var showScreenshotToast: Bool = false
    var screenshotToastMessage: String = ""
    var screenshotToastIcon: String = "camera.fill"
    var screenshotToastIconColor: Color = .green
    @ObservationIgnored private var statusToastDismissTask: Task<Void, Never>?

    /// Shows `message` for three seconds. Re-showing while one is up replaces
    /// it and restarts the timer, rather than letting the first one's
    /// dismissal cut the second one short.
    func showStatusToast(_ message: String, icon: String = "camera.fill", iconColor: Color = .green) {
        screenshotToastMessage = message
        screenshotToastIcon = icon
        screenshotToastIconColor = iconColor
        showScreenshotToast = true

        statusToastDismissTask?.cancel()
        statusToastDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.showScreenshotToast = false
        }
    }

    // MARK: - Command Palette
    var showCommandPalette: Bool = false

    // MARK: - Video / Element Fullscreen
    var isVideoFullscreen: Bool = false

    // MARK: - Developer Tools
    var showDevToolsPanel: Bool = false

    // MARK: - Ask This Page
    var showAskThisPage: Bool = false {
        didSet {
            // A seed belongs to the ONE opening it was typed for. Clearing it
            // as the panel closes is what stops a homepage question from
            // reappearing in the composer the next time the panel is opened
            // from a page. Every close goes through this property, so there is
            // no second place to keep in step.
            if !showAskThisPage { askThisPageSeed = "" }
        }
    }
    var askThisPageTitle: String = ""
    var askThisPageText: String = ""
    /// Text the panel's composer should open pre-filled with — set by the
    /// homepage's Ask control, which routes what the user typed into the chat
    /// instead of the search engine. Empty means "open with an empty
    /// composer", which is every other way in. The panel consumes it once, on
    /// appear (see `AskThisPagePanel.seedDraft`).
    var askThisPageSeed: String = ""

    // MARK: - Address Bar Focus
    /// Bumped by the "Focus Address Bar" (⌘L) command. `BrowserContentView`
    /// watches it and forwards to its omnibox only when its pane is focused,
    /// so exactly one address bar takes focus in split view.
    private(set) var focusAddressBarTrigger: Int = 0

    func focusAddressBar() {
        focusAddressBarTrigger &+= 1
    }

    // Keep strong references to detached windows and their delegates
    static var detachedWindows: [NSWindow] = []
    static var detachedWindowDelegates: [DetachedWindowDelegate] = []

    // Registry of all active view models for cross-window tab transfer.
    // Weak boxes: a strong dictionary would keep every view model alive forever
    // (deinit could never run, so entries would never be removed) and closed
    // windows would stay valid transfer targets.
    final class WeakViewModelRef {
        weak var value: BrowserViewModel?
        init(_ value: BrowserViewModel) { self.value = value }
    }
    /// This window's identity, stable for as long as the window exists, unique
    /// across windows, and already the key of `viewModelRefs` — so id → view
    /// model is a dictionary lookup with no extra bookkeeping.
    ///
    /// Readable (it was `private let instanceID`) because the MCP bridge hands it
    /// to an external client as `window_id` and has to resolve one back.
    /// Deliberately not `NSWindow.windowNumber`, which AppKit recycles, nor an
    /// index into anything, which reorders.
    let windowID = UUID()
    private static var viewModelRefs: [UUID: WeakViewModelRef] = [:]
    static var windowViewModels: [UUID: BrowserViewModel] {
        viewModelRefs.compactMapValues { $0.value }
    }

    /// The NSWindow hosting this view model. Set by BrowserView on appear.
    weak var associatedWindow: NSWindow?

    init(withDefaultTab: Bool = true) {
        if !withDefaultTab {
            tabManager = TabManager(createDefaultTab: false)
        }
        BrowserViewModel.viewModelRefs[windowID] = WeakViewModelRef(self)
    }

    deinit {
        BrowserViewModel.viewModelRefs.removeValue(forKey: windowID)
    }

    var currentTab: Tab? {
        tabManager.selectedTab
    }

    var isSidebarVisible: Bool {
        sidebarContent != .none
    }

    // MARK: - Navigation

    func navigate(to input: String) {
        guard let tab = currentTab else { return }
        navigate(to: input, in: tab)
    }

    /// Pane-targeted variant so a specific split-view pane can navigate its own
    /// tab regardless of which tab is `currentTab`.
    func navigate(to input: String, in tab: Tab) {
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // cherry:// internal pages — must be detected before the URL/search
        // handling below: the cherry scheme isn't a recognized web-input
        // scheme, so it would otherwise fall through to a search.
        if trimmedInput.lowercased().hasPrefix("\(CherryPage.urlScheme):") {
            // cherry://newtab is the home page: it's the root state, not a
            // site-covering internal page, so route it to goHome.
            if CherryPage.isNewTabInput(trimmedInput) {
                goHome(for: tab)
                return
            }
            if let page = CherryPage(input: trimmedInput) {
                tab.openInternalPage(page)
                return
            }
            // Unknown cherry:// page (e.g. cherry://nope): fall through and
            // treat it as a search — there's no "page not found" internal page.
        }

        // Try to parse as URL first
        if let url = URL.fromUserInput(trimmedInput) {
            tab.loadURL(url)
        } else if trimmedInput.isLikelyURL {
            // It looks like a URL, try with https
            if let url = URL(string: "https://\(trimmedInput)") {
                tab.loadURL(url)
            } else {
                // Fall back to search
                performSearch(trimmedInput, in: tab)
            }
        } else {
            // Treat as search query
            performSearch(trimmedInput, in: tab)
        }
    }

    func performSearch(_ query: String) {
        guard let tab = currentTab else { return }
        performSearch(query, in: tab)
    }

    func performSearch(_ query: String, in tab: Tab) {
        guard let searchURL = URL.searchURL(for: query, engine: searchEngine) else { return }
        tab.loadURL(searchURL)
    }

    func goBack() {
        if let tab = currentTab {
            goBack(for: tab)
        }
    }

    func goBack(for tab: Tab) {
        // Back out of a failure surface goes back in the WEB VIEW's history,
        // which was never disturbed: the failed navigation either never
        // committed or was refused before it could. With nothing behind it,
        // Back lands on the new-tab page rather than on the failure it just
        // dismissed.
        if tab.isShowingFailure {
            tab.clearFailureState()
            if tab.canGoBack, tab.webView?.canGoBack == true {
                tab.goBack()
            } else {
                goHome(for: tab)
            }
            return
        }
        if tab.internalPage != nil {
            // Back out of an internal cherry:// page re-shows the site that
            // was showing: its WKWebView was kept alive the whole time, so
            // the content slot simply re-adopts it with back/forward history,
            // scroll position, and form state intact (no reload). If the tab
            // was sleeping, WebViewWrapper recreates the web view and loads
            // `tab.url` itself. With no site at all, fall back to the
            // home/new-tab state.
            tab.closeInternalPage()
            if tab.url == nil {
                goHome(for: tab)
            }
            return
        }
        tab.goBack()
    }

    func goForward() {
        if let tab = currentTab {
            goForward(for: tab)
        }
    }

    func goForward(for tab: Tab) {
        // Forward never re-enters internal pages, and it must not silently
        // navigate the hidden covered site while one is shown.
        guard tab.internalPage == nil else { return }
        tab.goForward()
    }

    func reload() {
        if let tab = currentTab {
            reload(for: tab)
        }
    }

    func reload(for tab: Tab) {
        // Reload on a failure surface is the same action as its Retry button.
        // `tab.reload()` would re-request whatever the web view last committed,
        // which is the previous page, not the address that failed.
        if tab.isShowingFailure {
            retryFailedLoad(for: tab)
            return
        }
        // Internal cherry:// pages are always-fresh SwiftUI views; reloading
        // would only act on the hidden covered site, which would be silent
        // and surprising — no-op instead.
        guard tab.internalPage == nil else { return }
        tab.reload()
    }

    // MARK: - Failed loads

    func retryFailedLoad(for tab: Tab) {
        tab.retryFailedLoad()
    }

    /// The certificate interstitial's primary action. Back where there is a
    /// back, home where there is not; either way the tab does not stay pointed
    /// at a site whose identity could not be checked.
    func leaveCertificateWarning(for tab: Tab) {
        tab.clearFailureState()
        if tab.canGoBack, tab.webView?.canGoBack == true {
            tab.goBack()
        } else {
            goHome(for: tab)
        }
    }

    /// The interstitial's deliberate escape hatch. The exception it records is
    /// the whole of what "Continue" means: this host, this port, in memory,
    /// and in a private window it is dropped with the window.
    func proceedPastCertificateWarning(for tab: Tab) {
        guard let warning = tab.certificateWarning else { return }
        CertificateExceptionStore.shared.allow(warning.exceptionKey, isPrivate: warning.isPrivate)
        tab.clearFailureState()
        tab.loadURL(warning.url)
    }

    /// Reads a saved credential for the HTTP authentication sheet, under
    /// whatever the password settings require. Never reached from a private
    /// window: the sheet does not build the control that calls it there.
    func revealSavedPassword(_ item: PasswordItem, completion: @escaping (String?) -> Void) {
        let deliver = { completion(PasswordRepository.shared.fetchPassword(for: item.id)) }
        guard SettingsManager.shared.requireTouchIDForAutoFill else {
            deliver()
            return
        }
        passwordManager.authenticateWithTouchID(
            reason: "Use the saved password for \(item.domain)"
        ) { success in
            if success { deliver() } else { completion(nil) }
        }
    }

    /// Called when a private window goes away, or leaves private mode. Private
    /// certificate exceptions are dropped once no private window is left to own
    /// them; normal ones are untouched.
    func forgetPrivateCertificateExceptionsIfLastPrivateWindow() {
        let anotherPrivateWindowRemains = BrowserViewModel.windowViewModels.values.contains {
            $0.windowID != self.windowID && $0.isPrivateMode
        }
        guard !anotherPrivateWindowRemains else { return }
        CertificateExceptionStore.shared.forgetPrivateExceptions()
    }

    // MARK: - Zoom

    /// Whether `tab` is showing a page zoom can act on. False on the new-tab
    /// page, on any `cherry://` internal page, and while the Reader overlay is
    /// up (it renders its own detached web view) — none of those are the
    /// tab's `WKWebView`, so zooming them is not a thing that can happen.
    ///
    /// Mirrors the condition `BrowserContentView` uses to decide whether to
    /// render `WebViewWrapper` at all.
    func canZoom(_ tab: Tab?) -> Bool {
        guard let tab, !showReaderMode else { return false }
        return tab.internalPage == nil && !tab.showHomePage && !tab.showSettingsPage
    }

    /// The zoom steps ⌘+ / ⌘- walk through, matching Chrome's ladder.
    /// `PageZoom.step(from:direction:)` owns the arithmetic so it can be
    /// unit-tested without a web view.
    ///
    /// Refuses — with a visible reason — when there's no web page to zoom.
    /// Recording the level anyway is worse than doing nothing: the keypress
    /// looks like a no-op and then silently changes the size of whatever page
    /// the user loads in that tab next.
    func zoomIn(for tab: Tab?) {
        guard canZoom(tab) else { reportZoomUnavailable(); return }
        applyZoom(PageZoom.step(from: currentZoom(for: tab), direction: 1), to: tab)
    }

    func zoomOut(for tab: Tab?) {
        guard canZoom(tab) else { reportZoomUnavailable(); return }
        applyZoom(PageZoom.step(from: currentZoom(for: tab), direction: -1), to: tab)
    }

    /// Actual Size is always allowed: it can only ever CLEAR a level, never
    /// leave a surprise behind, so it stays available on the new-tab page to
    /// undo a zoom set before navigating away.
    func resetZoom(for tab: Tab?) {
        applyZoom(PageZoom.defaultLevel, to: tab)
    }

    private func reportZoomUnavailable() {
        showStatusToast(
            "Zoom applies to web pages",
            icon: "magnifyingglass",
            iconColor: .secondary
        )
    }

    private func currentZoom(for tab: Tab?) -> Double {
        tab?.zoomLevel ?? PageZoom.defaultLevel
    }

    /// Records the level on the TAB, then pushes it to the live web view. Going
    /// through the tab means zooming works on a tab whose web view doesn't
    /// exist yet (sleeping, or just sent Home) and survives every web-view
    /// recreation instead of snapping back to 100%.
    private func applyZoom(_ level: Double, to tab: Tab?) {
        guard let tab else { return }
        tab.zoomLevel = level
        tab.applyZoomLevel()
    }

    func stopLoading() {
        currentTab?.stopLoading()
    }

    func stopLoading(for tab: Tab) {
        tab.stopLoading()
    }

    func goHome() {
        goHome(for: tabManager.focusedTab)
    }

    /// Takes a specific pane's tab home IN PLACE (like `goBack(for:)` acts on
    /// that tab), rather than spawning a new primary tab — so clicking Home in
    /// the secondary split pane returns THAT pane home instead of creating an
    /// unrelated tab in the primary pane.
    ///
    /// "Home" is Cherry's new-tab page by default; setting a custom homepage in
    /// General settings (`HomepagePreference`) sends it to that URL instead.
    func goHome(for tab: Tab?) {
        guard let tab else { return }
        // Release the old page like closeTab does, so its audio/JS/timers stop
        // instead of lingering invisibly behind the home page. End any
        // background-load mirroring first so a mid-load research tab's KVO is
        // invalidated (not left observing a released webview / writing
        // about:blank state back onto the tab).
        tab.endBackgroundLoadObservation()
        tab.webView?.stopLoading()
        tab.webView?.loadHTMLString("", baseURL: nil)
        tab.webView = nil
        tab.url = nil
        tab.title = "New Tab"
        // Reset nav state so Back/Forward don't stay enabled pointing at the
        // now-released page.
        tab.canGoBack = false
        tab.canGoForward = false
        tab.isLoading = false
        tab.loadingProgress = 0
        tab.showSettingsPage = false
        tab.internalPage = nil
        tab.clearFailureState()

        if let homepage = HomepagePreference.shared.homepageURL {
            tab.showHomePage = false
            tab.title = homepage.host ?? "Loading..."
            tab.loadURL(homepage)
        } else {
            tab.showHomePage = true
        }
    }

    // MARK: - Internal cherry:// Pages

    /// Navigates a tab to an internal `cherry://` page, making it the tab's
    /// location: the omnibox shows the page's URL, the web view is unloaded
    /// (connection dropped), and Back returns to the site that was showing.
    func openInternalPage(_ page: CherryPage, in tab: Tab? = nil) {
        guard let tab = tab ?? tabManager.focusedTab else { return }
        tab.openInternalPage(page)
    }

    func showSettings() {
        openInternalPage(.settings)
    }

    func toggleAdBlockForCurrentSite() {
        guard let tab = tabManager.focusedTab, let webView = tab.webView else { return }
        SettingsManager.shared.toggleAdBlockPause(for: tab.url)

        // Reinstall the whole set through the one function that owns it, rather
        // than editing the lists here. Removing them directly wiped the cookie
        // policy's block-cookies list off the web view with nothing to re-add
        // it — pausing ads on one site quietly stopped blocking cookies there
        // too.
        WebViewWrapper.applyContentRuleLists(to: webView.configuration, pageURL: tab.url)

        // Reload so the page reflects the change
        tab.reload()
    }

    // MARK: - Tab Management

    func newTab(url: URL? = nil) {
        let tab = tabManager.newTab(url: url)
        tab.isPrivate = isPrivateMode
        if let url = url {
            tab.loadURL(url)
        }
    }

    func newTabWithWebView(_ webView: WKWebView, url: URL?) {
        // Don't pass the URL to newTab — the adopted webView is already navigating
        // and the URL observer will pick up the real URL once navigation completes.
        // Passing a URL here would cause updateNSView to re-load it, interrupting the popup.
        let tab = tabManager.newTab(url: nil)
        tab.isPrivate = isPrivateMode
        tab.showHomePage = false
        tab.title = url?.host ?? "Loading..."
        tab.adoptWebView(webView)
    }

    func closeCurrentTab() {
        if let tab = currentTab {
            tabManager.closeTab(tab)
        }
    }

    func reopenClosedTab() {
        if let tab = tabManager.reopenLastClosedTab(), let url = tab.url {
            tab.loadURL(url)
        }
    }

    func duplicateCurrentTab() {
        if let tab = currentTab {
            let duplicate = tabManager.duplicateTab(tab)
            if let url = tab.url {
                duplicate.loadURL(url)
            }
        }
    }

    func selectNextTab() {
        tabManager.selectNextTab()
    }

    func selectPreviousTab() {
        tabManager.selectPreviousTab()
    }

    // MARK: - Split View

    /// Opens split view placing `tab` in the pane on the given `edge`.
    /// `.trailing` (right) → `tab` becomes the secondary (right) pane, current
    /// tab stays primary (left). `.leading` (left) → `tab` becomes primary
    /// (left) and the current tab is pushed to the secondary (right) pane.
    /// If `tab` is already the current tab the swap is meaningless, so
    /// `openSplit` picks a sensible secondary (adjacent or a fresh tab).
    func splitWith(tab: Tab, edge: Edge) {
        let id = tab.id
        if id == tabManager.selectedTabID {
            tabManager.openSplit(with: id)
        } else if edge == .leading {
            let previousPrimaryID = tabManager.selectedTabID
            tabManager.selectedTabID = id
            if let previousPrimaryID {
                tabManager.openSplit(with: previousPrimaryID)
            }
        } else {
            tabManager.openSplit(with: id)
        }
    }

    /// Toggles split view. Opening picks the tab after the current one as the
    /// secondary pane, or creates a new home-page tab when there's only one tab.
    func toggleSplitView() {
        if tabManager.isSplitActive {
            tabManager.closeSplit()
            return
        }
        guard let currentIndex = tabManager.selectedTabIndex else { return }
        if tabManager.tabs.count > 1 {
            let nextIndex = (currentIndex + 1) % tabManager.tabs.count
            tabManager.openSplit(with: tabManager.tabs[nextIndex].id)
        } else {
            let secondary = tabManager.newTab(switchTo: false)
            secondary.isPrivate = isPrivateMode
            tabManager.openSplit(with: secondary.id)
        }
    }

    func selectTab(at index: Int) {
        // Handle 1-9 keys for tab selection (1 = first tab, 9 = last tab)
        if index == 9 {
            tabManager.selectTab(at: tabManager.tabs.count - 1)
        } else {
            tabManager.selectTab(at: index - 1)
        }
    }

    // MARK: - Tab Transfer

    /// Transfer a tab from any window to a target viewModel
    static func transferTab(tabID: UUID, to targetViewModel: BrowserViewModel) -> Bool {
        // Find the source viewModel that owns this tab
        for (_, vm) in windowViewModels {
            if vm === targetViewModel { continue }
            if let tab = vm.tabManager.tabs.first(where: { $0.id == tabID }) {
                // Remove from source (preserving webview)
                _ = vm.tabManager.removeTab(tab)
                // Add to target
                targetViewModel.tabManager.addExistingTab(tab)
                return true
            }
        }
        return false
    }

    /// Handle a tab dropped on the content area.
    ///
    /// `edge` is `.leading`/`.trailing` when the drop landed in a content-area
    /// edge zone (open split view) or `nil` for the middle (existing
    /// detach-to-new-window behavior, unchanged).
    ///
    /// Arrangement when opening split from an edge drop: dropping on the
    /// RIGHT edge keeps the current tab primary (left) and puts the dragged
    /// tab in the secondary (right) pane — it lands where you dropped it.
    /// Dropping on the LEFT edge does the mirror: the dragged tab becomes
    /// primary (left) and the current tab is pushed to secondary (right).
    ///
    /// Split-from-edge-drop is only wired up for a tab dragged from THIS
    /// window — `openSplit` operates on this window's `TabManager`, and a
    /// tab living in another window's `TabManager` can't be placed into a
    /// split pane here without first transferring it. For M2c, a cross-window
    /// drag on an edge zone simply falls through to the existing detach path
    /// below (same as a middle drop) rather than transferring + splitting.
    func handleContentAreaDrop(edge: Edge? = nil) -> Bool {
        guard let draggedID = TabManager.draggedTabID else { return false }

        if let edge, let tab = tabManager.tabs.first(where: { $0.id == draggedID }) {
            TabManager.draggedTabID = nil
            splitWith(tab: tab, edge: edge)
            return true
        }

        TabManager.draggedTabID = nil

        // Find the tab across all windows (existing detach-to-new-window path
        // — also the fallback for edge drops when the dragged tab belongs to
        // another window).
        for (_, vm) in BrowserViewModel.windowViewModels {
            if let tab = vm.tabManager.tabs.first(where: { $0.id == draggedID }) {
                guard vm.tabManager.tabs.count > 1 else { return false }
                vm.detachTab(tab)
                return true
            }
        }
        return false
    }

    // MARK: - Tab Search

    func toggleTabSearch() {
        showTabSearch.toggle()
    }

    // MARK: - Tab Detach

    func detachTab(_ tab: Tab) {
        let title = tab.title

        let mouseLocation = NSEvent.mouseLocation

        // If the cursor is over an existing browser window, always re-attach there
        // (even when this is the only remaining tab — removeTab closes the source window).
        for (_, targetVM) in BrowserViewModel.windowViewModels {
            guard targetVM !== self else { continue }
            guard let targetWindow = targetVM.associatedWindow, targetWindow.isVisible else { continue }
            guard targetWindow.frame.contains(mouseLocation) else { continue }
            _ = tabManager.removeTab(tab)
            targetVM.tabManager.addExistingTab(tab)
            targetWindow.makeKeyAndOrderFront(nil)
            return
        }

        // No existing window under cursor — only create a new window if this isn't the last tab
        guard tabManager.tabs.count > 1 else { return }

        // Tear off into a new window
        _ = tabManager.removeTab(tab)

        // Create a new window with the existing tab (no reload)
        let newBrowserView = BrowserView(existingTab: tab)
        let hostingView = cherryHostingView(newBrowserView)

        let windowWidth: CGFloat = 1000
        let windowHeight: CGFloat = 700

        let window = DetachedWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.isMovable = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.titlebarSeparatorStyle = .none
        window.title = title

        // Position so the tab bar appears under the cursor (tab bar is at the very top of the window).
        // macOS screen coordinates: origin is bottom-left, so frame.maxY is the top of the window.
        let tabBarHeight: CGFloat = 36
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let mouseLocation = NSEvent.mouseLocation
            // Horizontally: center window on cursor
            var originX = mouseLocation.x - windowWidth / 2
            // Vertically: place window so cursor lands ~midway through the tab bar
            var originY = mouseLocation.y - windowHeight + tabBarHeight / 2
            originX = max(screenFrame.minX, min(originX, screenFrame.maxX - windowWidth))
            originY = max(screenFrame.minY, min(originY, screenFrame.maxY - windowHeight))
            window.setFrameOrigin(NSPoint(x: originX, y: originY))
        } else {
            window.center()
        }

        let delegate = DetachedWindowDelegate()
        window.delegate = delegate

        BrowserViewModel.detachedWindows.append(window)
        BrowserViewModel.detachedWindowDelegates.append(delegate)

        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Private Browsing

    func requestTogglePrivateMode() {
        showPrivateModeAlert = true
    }

    func confirmTogglePrivateMode() {
        let wasPrivate = isPrivateMode
        // Snapshot BEFORE any tab gets mutated/replaced below — these are the
        // exact Tab instances (if any) the extension controller was told
        // about via didOpenTab, and going private must close exactly those.
        let previousTabs = tabManager.tabs

        isPrivateMode.toggle()

        if !wasPrivate && isPrivateMode {
            // BrowserViewModel isn't formally @MainActor-isolated but is only
            // ever driven from the main thread, same rationale as TabManager's
            // notifyExtensionManager helper.
            MainActor.assumeIsolated {
                ExtensionManager.shared.windowBecamePrivate(self, tabs: previousTabs)
            }
        }

        // Update all existing tabs and drop their web views so they are
        // recreated with the correct data store when next displayed.
        // (The data store is fixed in the WKWebViewConfiguration at creation,
        // so a plain reload can never switch between private and normal.)
        for tab in tabManager.tabs {
            tab.isPrivate = isPrivateMode
            // Background tabs showing an internal cherry:// page keep their
            // covered site's web view (like sleep() spares them), so the
            // preserved history survives the toggle. Trade-off: that web view
            // keeps its pre-toggle data store until the next navigation
            // replaces it.
            if tab.internalPage == nil {
                // A mid-load background research tab may still be mirroring
                // its webview — invalidate that KVO before dropping the
                // webview so no stale isLoading/url writes land on the tab.
                tab.endBackgroundLoadObservation()
                tab.webView = nil
            }
        }
        // The on-screen WKWebView(s) are keyed by tab.id, so nilling webView
        // alone leaves the old view (with the old data store) visible.
        // Hard-replace every tab actually on screen right now — the primary
        // tab, and the secondary pane's tab too when split view is active —
        // to force WebViewWrapper to rebuild each with the new data store.
        if let primary = currentTab {
            hardReplaceOnScreenTab(primary)
        }
        if tabManager.isSplitActive, let secondary = tabManager.secondarySelectedTab {
            hardReplaceOnScreenTab(secondary)
        }

        if wasPrivate && !isPrivateMode {
            // Leaving private browsing drops this window's certificate
            // exceptions with it. They were only ever for the private session,
            // and the window is no longer in one.
            forgetPrivateCertificateExceptionsIfLastPrivateWindow()
            // Announce the now-finalized (post hard-replace) tab set, since
            // this window was excluded from every extension-facing API while
            // private and so was never previously known to the controller.
            MainActor.assumeIsolated {
                ExtensionManager.shared.windowBecameNormal(self)
            }
        }
    }

    /// Replaces `tab` in place with a fresh `Tab` carrying the same URL, so
    /// `WebViewWrapper` (keyed by `tab.id`) tears down and rebuilds its
    /// `WKWebView` with the current data store. Unlike `duplicateTab`, this
    /// fixes up `selectedTabID`/`secondarySelectedTabID` in place rather than
    /// always reassigning `selectedTabID` — so replacing the SECONDARY pane's
    /// tab doesn't wrongly promote it to primary.
    private func hardReplaceOnScreenTab(_ tab: Tab) {
        guard let url = tab.url, let index = tabManager.tabs.firstIndex(of: tab) else { return }
        let fresh = Tab(url: url, title: tab.title)
        fresh.isPrivate = isPrivateMode
        tabManager.tabs[index] = fresh
        fresh.loadURL(url)
        if tabManager.selectedTabID == tab.id { tabManager.selectedTabID = fresh.id }
        if tabManager.secondarySelectedTabID == tab.id { tabManager.secondarySelectedTabID = fresh.id }
    }

    /// Used by the command palette. File ▸ New Incognito Window (⌘⇧N) calls
    /// `openBrowserWindow(isPrivate:)` directly, because it has to work with no
    /// browser window open at all — this is the same single implementation.
    func openPrivateWindow() {
        openBrowserWindow(isPrivate: true)
    }

    // MARK: - Vertical Tabs

    func toggleVerticalTabs() {
        useVerticalTabs.toggle()
    }

    func toggleVerticalTabBarCollapsed() {
        // Same transaction the sidebar's own collapse button uses, so a
        // programmatic toggle animates identically instead of snapping.
        withAnimation(.easeInOut(duration: 0.22)) {
            verticalTabBarCollapsed.toggle()
        }
    }

    // MARK: - Bookmarks

    func toggleBookmarkBar() {
        showBookmarkBar.toggle()
    }

    func addBookmark(title: String, folder: String?, isInBookmarkBar: Bool) {
        guard let tab = tabManager.focusedTab, let url = tab.url else { return }
        bookmarkRepository.addBookmark(
            url: url,
            title: title,
            favicon: tab.favicon,
            folder: folder,
            isInBookmarkBar: isInBookmarkBar
        )
    }

    func isCurrentPageBookmarked() -> Bool {
        guard let url = currentTab?.url else { return false }
        return bookmarkRepository.isBookmarked(url: url)
    }

    func openBookmark(_ bookmark: Bookmark) {
        if let tab = currentTab {
            tab.loadURL(bookmark.url)
        } else {
            newTab(url: bookmark.url)
        }
        bookmarkRepository.incrementVisitCount(for: bookmark)
    }

    /// Pane-targeted variant used by the full-page cherry://bookmarks view,
    /// so a bookmark opened from a split pane's page loads in THAT pane.
    func openBookmark(_ bookmark: Bookmark, in tab: Tab) {
        tab.loadURL(bookmark.url)
        bookmarkRepository.incrementVisitCount(for: bookmark)
    }

    /// "Open in New Tab" / ⌘-click / middle-click on a bookmark. Opens in the
    /// BACKGROUND (the current tab keeps focus), like every other browser.
    func openBookmarkInNewTab(_ bookmark: Bookmark) {
        openInBackgroundTab(bookmark.url, title: bookmark.title, favicon: bookmark.favicon)
        bookmarkRepository.incrementVisitCount(for: bookmark)
    }

    /// Shared by the bookmark and history "Open in New Tab" paths.
    ///
    /// Background tabs stay LAZY: only the displayed tab gets a
    /// `WebViewWrapper`, and the wrapper is what creates the web view, so
    /// there's nothing to load into yet and the page loads when the tab is
    /// first selected. (Eager loading is possible — `TabManager`'s research
    /// tabs do it — but it needs an off-screen host window and a hand-built
    /// configuration, which is a lot of machinery to spend on ⌘-clicking a
    /// bookmark, and it would let a stack of middle-clicks load in parallel
    /// behind the user's back.)
    ///
    /// What matters is that the tab is IDENTIFIABLE while it waits: the
    /// bookmark's / history entry's own title and favicon are seeded here, the
    /// same way session restore seeds a restored-but-unloaded tab, so
    /// ⌘-clicking three rows gives three labelled tabs rather than three
    /// indistinguishable "New Tab"s. The page's real title and icon take over
    /// via KVO once it loads.
    private func openInBackgroundTab(_ url: URL, title: String, favicon: NSImage?) {
        let tab = tabManager.newTab(url: url, switchTo: false)
        tab.isPrivate = isPrivateMode
        tab.showHomePage = false
        if !title.isEmpty {
            tab.title = title
        } else {
            tab.title = url.host ?? url.absoluteString
        }
        tab.favicon = favicon
    }

    // MARK: - Sidebar

    func toggleHistory() {
        if sidebarContent == .history {
            sidebarContent = .none
        } else {
            sidebarContent = .history
        }
    }

    func toggleBookmarks() {
        if sidebarContent == .bookmarks {
            sidebarContent = .none
        } else {
            sidebarContent = .bookmarks
        }
    }

    func toggleDownloads() {
        if sidebarContent == .downloads {
            sidebarContent = .none
        } else {
            sidebarContent = .downloads
        }
    }

    func dismissDownloadToast() {
        withAnimation(.spring(duration: 0.3)) {
            showDownloadToast = false
        }
    }

    func showDownloadsFromToast() {
        openInternalPage(.downloads)
        dismissDownloadToast()
    }

    func closeSidebar() {
        sidebarContent = .none
    }

    // MARK: - Passwords

    func toggleAutoFillPopup() {
        showAutoFillPopup.toggle()
    }

    func autoFillCurrentPage() {
        guard let tab = tabManager.focusedTab, let webView = tab.webView else { return }
        let credentials = passwordManager.matchingCredentials
        if credentials.count == 1 {
            passwordManager.fillCredentials(credentials[0], in: webView)
        } else {
            showAutoFillPopup = true
        }
    }

    func fillCredential(_ credential: PasswordItem) {
        guard let webView = tabManager.focusedTab?.webView else { return }
        passwordManager.fillCredentials(credential, in: webView)
        showAutoFillPopup = false
    }

    func generateAndFillPassword() {
        guard let webView = tabManager.focusedTab?.webView else { return }
        let settings = SettingsManager.shared
        let generated = PasswordGenerator.generate(
            length: settings.passwordGeneratorLength,
            includeSymbols: settings.passwordGeneratorIncludeSymbols
        )
        let js = PasswordAutoFillScripts.autoFillScript(username: "", password: generated)
        webView.evaluateJavaScript(js, completionHandler: nil)
        showAutoFillPopup = false

        // Copy to clipboard so user can paste it if needed
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(generated, forType: .string)
    }

    func openHistoryItem(_ item: HistoryItem) {
        if let tab = currentTab {
            tab.loadURL(item.url)
        } else {
            newTab(url: item.url)
        }
    }

    /// Pane-targeted variant used by the full-page cherry://history view.
    func openHistoryItem(_ item: HistoryItem, in tab: Tab) {
        tab.loadURL(item.url)
    }

    /// "Open in New Tab" / ⌘-click / middle-click on a history row.
    func openHistoryItemInNewTab(_ item: HistoryItem) {
        openInBackgroundTab(item.url, title: item.title, favicon: item.favicon)
    }

    // MARK: - Find in Page

    /// Injects the find helper JS once per page. Uses querySelectorAll to clear
    /// old marks so it never loses track of highlights even if called again.
    /// The presence check must live in JS: the helper is wiped by every
    /// navigation and is per-page, while this view model spans pages and tabs,
    /// so a Swift-side "already injected" flag goes stale and breaks find.
    /// `findHelperInjected` lives on the `Tab`, not this view model, so each
    /// split-view pane's page tracks its own injection state independently.
    private func injectFindHelperIfNeeded(in webView: WKWebView, for tab: Tab, completion: @escaping () -> Void) {
        let js = """
        if (!window.__cherryFind) window.__cherryFind = {
            marks: [],
            current: -1,
            clear: function() {
                // Always query DOM directly so we never lose old marks
                document.querySelectorAll('mark[data-cherry-find]').forEach(function(m) {
                    var parent = m.parentNode;
                    if (parent) {
                        parent.replaceChild(document.createTextNode(m.textContent), m);
                        parent.normalize();
                    }
                });
                this.marks = [];
                this.current = -1;
            },
            _isVisible: function(el) {
                // Walk up the DOM tree checking visibility
                while (el && el !== document.body) {
                    if (el.nodeType !== 1) { el = el.parentNode; continue; }
                    if (el.hidden || el.getAttribute('aria-hidden') === 'true') return false;
                    var s = window.getComputedStyle(el);
                    if (s.display === 'none' || s.visibility === 'hidden' || s.opacity === '0') return false;
                    // Check if element has zero dimensions (off-screen/collapsed)
                    if (el.offsetWidth === 0 && el.offsetHeight === 0 && s.overflow === 'hidden') return false;
                    el = el.parentNode;
                }
                return true;
            },
            highlight: function(query) {
                this.clear();
                if (!query || query.length === 0) return 0;
                var lowerQ = query.toLowerCase();
                var skip = {'SCRIPT':1,'STYLE':1,'NOSCRIPT':1,'TEXTAREA':1,'TEMPLATE':1,'SVG':1,'INPUT':1,'SELECT':1};
                var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
                    acceptNode: function(node) {
                        var p = node.parentElement;
                        if (!p) return NodeFilter.FILTER_REJECT;
                        if (skip[p.tagName]) return NodeFilter.FILTER_REJECT;
                        return NodeFilter.FILTER_ACCEPT;
                    }
                });
                var nodes = [];
                while (walker.nextNode()) nodes.push(walker.currentNode);
                var self = this;
                nodes.forEach(function(node) {
                    var text = node.textContent;
                    if (!text || text.trim().length === 0) return;
                    var lower = text.toLowerCase();
                    var idx = lower.indexOf(lowerQ);
                    if (idx === -1) return;
                    // Check if the parent element is actually visible on screen
                    if (!self._isVisible(node.parentElement)) return;
                    var frag = document.createDocumentFragment();
                    var last = 0;
                    while (idx !== -1) {
                        if (idx > last) frag.appendChild(document.createTextNode(text.substring(last, idx)));
                        var mark = document.createElement('mark');
                        mark.setAttribute('data-cherry-find', '1');
                        mark.style.cssText = 'background:#FDFF00;color:#000;padding:0;margin:0;border-radius:2px;';
                        mark.textContent = text.substring(idx, idx + query.length);
                        frag.appendChild(mark);
                        self.marks.push(mark);
                        last = idx + query.length;
                        idx = lower.indexOf(lowerQ, last);
                    }
                    if (last < text.length) frag.appendChild(document.createTextNode(text.substring(last)));
                    node.parentNode.replaceChild(frag, node);
                });
                if (this.marks.length > 0) { this.current = 0; this._focus(); }
                return this.marks.length;
            },
            next: function() {
                if (this.marks.length === 0) return {c:0,t:0};
                this._unfocus();
                this.current = (this.current + 1) % this.marks.length;
                this._focus();
                return {c: this.current + 1, t: this.marks.length};
            },
            prev: function() {
                if (this.marks.length === 0) return {c:0,t:0};
                this._unfocus();
                this.current = (this.current - 1 + this.marks.length) % this.marks.length;
                this._focus();
                return {c: this.current + 1, t: this.marks.length};
            },
            _focus: function() {
                var m = this.marks[this.current];
                if (!m) return;
                m.style.background = '#FF9632';
                m.scrollIntoView({block:'center',behavior:'smooth'});
            },
            _unfocus: function() {
                var m = this.marks[this.current];
                if (!m) return;
                m.style.background = '#FDFF00';
            }
        };
        true;
        """
        webView.evaluateJavaScript(js) { [weak tab] _, _ in
            tab?.findHelperInjected = true
            completion()
        }
    }

    func toggleFindInPage() {
        showFindInPage.toggle()
        if !showFindInPage {
            dismissFind()
        }
    }

    private func escapeFindQuery(_ query: String) -> String {
        query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    func findNext() {
        guard let webView = tabManager.focusedTab?.webView, !findQuery.isEmpty else { return }
        webView.evaluateJavaScript("window.__cherryFind.next();") { [weak self] result, _ in
            guard let self, let dict = result as? [String: Any],
                  let c = dict["c"] as? Int, let t = dict["t"] as? Int else { return }
            self.findCurrentMatch = c
            self.findTotalMatches = t
        }
    }

    func findPrevious() {
        guard let webView = tabManager.focusedTab?.webView, !findQuery.isEmpty else { return }
        webView.evaluateJavaScript("window.__cherryFind.prev();") { [weak self] result, _ in
            guard let self, let dict = result as? [String: Any],
                  let c = dict["c"] as? Int, let t = dict["t"] as? Int else { return }
            self.findCurrentMatch = c
            self.findTotalMatches = t
        }
    }

    func performFind() {
        findDebounceTask?.cancel()

        guard !findQuery.isEmpty else {
            clearFindHighlights()
            findCurrentMatch = 0
            findTotalMatches = 0
            return
        }

        let query = findQuery
        findDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self, self.findQuery == query else { return }
            self.executeHighlightFind(query: query)
        }
    }

    private func executeHighlightFind(query: String) {
        guard let tab = tabManager.focusedTab, let webView = tab.webView else { return }
        let escaped = escapeFindQuery(query)
        injectFindHelperIfNeeded(in: webView, for: tab) { [weak self] in
            let js = "window.__cherryFind.highlight('\(escaped)');"
            webView.evaluateJavaScript(js) { [weak self] result, _ in
                guard let self else { return }
                if let count = result as? Int {
                    self.findTotalMatches = count
                    self.findCurrentMatch = count > 0 ? 1 : 0
                } else {
                    self.findTotalMatches = 0
                    self.findCurrentMatch = 0
                }
            }
        }
    }

    private func clearFindHighlights() {
        guard let tab = tabManager.focusedTab, let webView = tab.webView else { return }
        if tab.findHelperInjected {
            webView.evaluateJavaScript(
                "window.__cherryFind.clear();", completionHandler: nil)
        }
    }

    func dismissFind() {
        findDebounceTask?.cancel()
        clearFindHighlights()
        findQuery = ""
        findCurrentMatch = 0
        findTotalMatches = 0
        tabManager.focusedTab?.findHelperInjected = false
    }

    /// Called when focus switches between split-view panes while find is
    /// open. A single `findQuery`/count pair is shared by the bar (see the
    /// M2a design note in the class doc), so on focus change we zero the
    /// counts immediately (they belonged to the previous pane) and re-run
    /// the search against the newly-focused pane's tab. This never touches
    /// the other pane's DOM, so its highlights stay intact.
    func refreshFindForFocusChange() {
        guard showFindInPage else { return }
        findCurrentMatch = 0
        findTotalMatches = 0
        performFind()
    }

    // MARK: - Print / Save as PDF

    func printCurrentPage() {
        guard let webView = tabManager.focusedTab?.webView else { return }
        guard let window = webView.window ?? NSApp.keyWindow else { return }
        let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
        printInfo.isHorizontallyCentered = true
        printInfo.isVerticallyCentered = false
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.topMargin = 36
        printInfo.bottomMargin = 36
        printInfo.leftMargin = 36
        printInfo.rightMargin = 36
        let printOp = webView.printOperation(with: printInfo)
        printOp.showsPrintPanel = true
        printOp.showsProgressPanel = true
        // Initialize WKPrintingView frame to paper size to prevent the
        // "frame was not initialized before knowsPageRange:" crash
        let paperSize = printInfo.paperSize
        printOp.view?.frame = NSRect(x: 0, y: 0, width: paperSize.width, height: paperSize.height)
        printOp.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    // MARK: - Reader Mode

    func toggleReaderMode() {
        if showReaderMode {
            showReaderMode = false
            readerContent = nil
            return
        }
        guard let webView = tabManager.focusedTab?.webView else { return }
        Task { @MainActor in
            if let content = await ReaderModeExtractor.extract(from: webView) {
                self.readerContent = content
                self.showReaderMode = true
            }
        }
    }

    // MARK: - Ask This Page

    func toggleAskThisPage() {
        if showAskThisPage {
            showAskThisPage = false
            return
        }
        // The question is "is there something ON SCREEN to ground on", not "is
        // there a web view". `Tab.openInternalPage` deliberately KEEPS the web
        // view — the covered site's back/forward list and scroll position have
        // to survive — so on a cherry:// page there is a live, readable web
        // view showing a page the user is not looking at. Same shape as
        // `AskThisPagePanel.refreshSnapshot`, which is what keeps the panel's
        // live snapshot and this opening snapshot answering the same question.
        guard let tab = tabManager.focusedTab,
              tab.internalPage == nil, !tab.showHomePage,
              let webView = tab.webView else {
            // Nothing readable on screen. Open on an EMPTY snapshot: that is
            // exactly what `AskThisPagePanel.isGeneralChat` reads as "nothing
            // to ground on", so the panel lands in general chat. This used to
            // `return`, which made the toolbar button, the ⋯ entry, ⌘⇧K and
            // the command palette all do NOTHING on the home page.
            askThisPageTitle = ""
            askThisPageText = ""
            showAskThisPage = true
            return
        }
        let fallbackTitle = currentTab?.title ?? "This Page"
        Task { @MainActor in
            if let content = await PageAIService.extractPageText(from: webView) {
                self.askThisPageTitle = content.title.isEmpty ? fallbackTitle : content.title
                self.askThisPageText = content.text
            } else {
                self.askThisPageTitle = fallbackTitle
                self.askThisPageText = ""
            }
            self.showAskThisPage = true
        }
    }

    /// The homepage's Ask control: open the panel with what the user typed
    /// waiting in its composer (empty text simply opens general chat).
    ///
    /// Deliberately not `toggleAskThisPage()`: this control's promise is "take
    /// this to the AI", so pressing it must never be the thing that CLOSES the
    /// panel. With the panel already open the running conversation is left
    /// exactly as it is — the seed is consumed once, when the panel appears,
    /// so it can't reach in and overwrite a draft the user is typing there.
    ///
    /// Returns whether the question was TAKEN. `false` means nothing at all
    /// happened to it, and the caller still owns it: the homepage clears its
    /// search field only on `true`, so a question typed behind an already-open
    /// panel is never destroyed by a press that did nothing.
    @discardableResult
    func askCherryAI(seed: String) -> Bool {
        guard !showAskThisPage else { return false }
        askThisPageSeed = seed
        toggleAskThisPage()
        return true
    }

    // MARK: - Picture-in-Picture

    /// Finds the best `<video>` on the page (including same-origin iframes) and
    /// toggles its native WebKit presentation mode between "picture-in-picture"
    /// and "inline". This never touches the WKWebView itself — the page keeps
    /// rendering and the tab stays fully interactive — because WebKit renders
    /// the PiP video into its own OS-level floating window on macOS.
    ///
    /// `webkitSetPresentationMode` (the legacy WebKit-proprietary PiP API) is
    /// used in preference to the standard `element.requestPictureInPicture()`.
    /// Unlike the standard API, which strictly requires a live DOM user
    /// gesture on its call stack, WebKit's legacy presentation-mode API does
    /// not enforce that check — the same reason PiP bookmarklets
    /// (`javascript:video.webkitSetPresentationMode(...)`) work when typed
    /// into Safari's address bar, which is likewise outside any DOM gesture.
    /// That means this call is safe to make directly from `evaluateJavaScript`
    /// in response to a native toolbar/menu click. The standard API is kept
    /// as a fallback for players where the WebKit-specific one is unavailable;
    /// any failure (including a gesture rejection on that fallback path) is
    /// logged via `console.error`, which this app already forwards to the
    /// in-app DevTools console.
    private static let pipToggleScript = """
    (function() {
        function isVisible(el) {
            if (!el) return false;
            var rect = el.getBoundingClientRect();
            if (rect.width === 0 || rect.height === 0) return false;
            var style = window.getComputedStyle(el);
            if (style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') return false;
            return true;
        }
        function collectVideos(doc, out) {
            doc.querySelectorAll('video').forEach(function(v) { out.push(v); });
            doc.querySelectorAll('iframe').forEach(function(f) {
                try {
                    if (f.contentDocument) collectVideos(f.contentDocument, out);
                } catch (e) {
                    // Cross-origin iframe — inaccessible, skip it.
                }
            });
        }
        function currentMode(v) {
            if (typeof v.webkitPresentationMode === 'string') return v.webkitPresentationMode;
            return document.pictureInPictureElement === v ? 'picture-in-picture' : 'inline';
        }
        function exit(v) {
            if (typeof v.webkitSetPresentationMode === 'function') {
                v.webkitSetPresentationMode('inline');
            } else if (document.exitPictureInPicture) {
                document.exitPictureInPicture().catch(function(e) {
                    console.error('Cherry PiP: exit failed', e && e.message);
                });
            }
        }
        function enter(v) {
            try {
                if (typeof v.webkitSetPresentationMode === 'function' &&
                    (typeof v.webkitSupportsPresentationMode !== 'function' ||
                     v.webkitSupportsPresentationMode('picture-in-picture'))) {
                    v.webkitSetPresentationMode('picture-in-picture');
                    return true;
                }
                if (typeof v.requestPictureInPicture === 'function') {
                    v.requestPictureInPicture().catch(function(e) {
                        console.error('Cherry PiP: enter failed', e && e.message);
                    });
                    return true;
                }
            } catch (e) {
                console.error('Cherry PiP: enter threw', e && e.message);
            }
            return false;
        }

        var videos = [];
        collectVideos(document, videos);
        if (videos.length === 0) {
            console.error('Cherry PiP: no video element found on page');
            return false;
        }

        // If a video is already in PiP, toggling means exiting it.
        var active = videos.find(function(v) { return currentMode(v) === 'picture-in-picture'; });
        if (active) {
            exit(active);
            return true;
        }

        // Otherwise pick the most prominent candidate: currently playing and
        // visible first, falling back to the largest video on the page.
        var best = null, bestScore = -1;
        videos.forEach(function(v) {
            var visible = isVisible(v);
            var area = Math.max(v.clientWidth * v.clientHeight, (v.videoWidth || 0) * (v.videoHeight || 0));
            var playing = !v.paused && !v.ended && v.readyState > 2;
            var score = (playing ? 1000000 : 0) + (visible ? 500000 : 0) + area;
            if (score > bestScore) { bestScore = score; best = v; }
        });
        if (!best) {
            console.error('Cherry PiP: no suitable video candidate');
            return false;
        }
        return enter(best);
    })();
    """

    func togglePictureInPicture() {
        guard let webView = tabManager.focusedTab?.webView else { return }
        webView.evaluateJavaScript(BrowserViewModel.pipToggleScript, completionHandler: nil)
    }

    // MARK: - Command Palette

    func toggleCommandPalette() {
        showCommandPalette.toggle()
    }

    // MARK: - Developer Tools

    func toggleDevTools() {
        showDevToolsPanel.toggle()
    }

    /// Execute arbitrary JS in the focused pane's tab and return a formatted result string.
    func evaluateJSForDevTools(_ js: String, completion: @escaping (String?) -> Void) {
        guard let webView = tabManager.focusedTab?.webView else { completion(nil); return }
        webView.evaluateJavaScript(js) { result, error in
            DispatchQueue.main.async {
                if let error {
                    completion("Error: \(error.localizedDescription)")
                    return
                }
                switch result {
                case let s as String:   completion("\"\(s)\"")
                case let n as Double:
                    completion(n.truncatingRemainder(dividingBy: 1) == 0
                               ? String(Int(n)) : String(n))
                case let b as Bool:     completion(b ? "true" : "false")
                case let d as [String: Any]:
                    if let data = try? JSONSerialization.data(withJSONObject: d, options: .prettyPrinted),
                       let str  = String(data: data, encoding: .utf8) { completion(str) }
                    else { completion(String(describing: d)) }
                case let a as [Any]:
                    if let data = try? JSONSerialization.data(withJSONObject: a, options: .prettyPrinted),
                       let str  = String(data: data, encoding: .utf8) { completion(str) }
                    else { completion(String(describing: a)) }
                case .none:             completion("undefined")
                default:                completion(String(describing: result!))
                }
            }
        }
    }

    /// Flash a blue outline around the element matching `selector`.
    func highlightElementInDevTools(selector: String) {
        guard let webView = tabManager.focusedTab?.webView else { return }
        let js = DevToolsManager.highlightScript(for: selector)
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Apply edited outer HTML to the element matching `selector` (base64-encoded).
    func applyHTMLInDevTools(selector: String, base64HTML: String,
                             completion: @escaping (String?) -> Void) {
        guard let webView = tabManager.focusedTab?.webView else { completion("no webview"); return }
        let js = DevToolsManager.applyScript(selector: selector, base64HTML: base64HTML)
        webView.evaluateJavaScript(js) { result, _ in
            DispatchQueue.main.async { completion(result as? String) }
        }
    }

    // MARK: - Focus Mode

    var showFocusBlock: Bool = false
    var focusBlockedHost: String = ""
    var focusBlockedURL: URL? = nil

    func toggleFocusMode() {
        FocusModeManager.shared.toggleFocusMode()
    }

    // MARK: - View Source

    var showViewSource: Bool = false
    var viewSourceHTML: String = ""

    func fetchAndShowViewSource() {
        guard let webView = currentTab?.webView else { return }
        webView.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] result, _ in
            guard let self, let html = result as? String else { return }
            Task { @MainActor in
                self.viewSourceHTML = html
                self.showViewSource = true
            }
        }
    }

    // MARK: - Session Restore

    /// Session restore must only ever run for the first window of the process.
    /// Windows created later (detached tabs, dock-menu windows) also hit
    /// onAppear; without this guard they would restore a session saved when an
    /// earlier window closed during this run, importing its tabs.
    private static var sessionRestoreAttempted = false

    /// Restores the previous session if the setting is enabled and a saved session exists.
    func restoreSessionIfNeeded() {
        guard !BrowserViewModel.sessionRestoreAttempted else { return }
        BrowserViewModel.sessionRestoreAttempted = true
        guard !isPrivateMode,
              SettingsManager.shared.restorePreviousSession,
              SessionRestoreManager.shared.hasSavedSession else { return }

        let entries = SessionRestoreManager.shared.loadSavedTabs()
        let savedGroups = SessionRestoreManager.shared.loadSavedGroups()
        let selectedIndex = SessionRestoreManager.shared.loadSelectedIndex()
        SessionRestoreManager.shared.clearSession()

        guard !entries.isEmpty else { return }

        // Recreate groups first so restored tabs can be assigned to them.
        var groupsByID: [UUID: TabGroup] = [:]
        for savedGroup in savedGroups {
            let color = TabGroupColor(rawValue: savedGroup.colorRawValue) ?? .blue
            groupsByID[savedGroup.id] = tabManager.restoreGroup(
                id: savedGroup.id,
                name: savedGroup.name,
                color: color,
                isCollapsed: savedGroup.isCollapsed,
                isLocked: savedGroup.isLocked
            )
        }

        // Replace the default blank tab with the restored session
        let hadOnlyBlankTab = tabManager.tabs.count == 1 && tabManager.tabs.first?.url == nil

        for (i, entry) in entries.enumerated() {
            guard let url = URL(string: entry.urlString) else { continue }
            let restoredTab: Tab
            if i == 0 && hadOnlyBlankTab, let firstTab = tabManager.tabs.first {
                // Re-use the existing blank tab for the first restored URL
                firstTab.title = entry.title
                firstTab.showHomePage = false
                firstTab.loadURL(url)
                restoredTab = firstTab
            } else {
                let tab = tabManager.newTab(url: url)
                tab.title = entry.title
                tab.showHomePage = false
                tab.loadURL(url)
                restoredTab = tab
            }
            if let groupID = entry.groupID {
                restoredTab.group = groupsByID[groupID]
            }
            // Restore page zoom. Written before the web view exists, which is
            // fine — `Tab.applyZoomLevel()` pushes it as soon as one does.
            // Sessions saved before zoom was persisted decode as nil and stay
            // at 100%. Clamped to the ladder's bounds so a hand-edited or
            // corrupt value can't produce an unreadable page.
            if let zoomLevel = entry.zoomLevel {
                restoredTab.zoomLevel = PageZoom.clamped(zoomLevel)
            }
        }

        // Select the previously active tab
        let clampedIndex = min(selectedIndex, tabManager.tabs.count - 1)
        tabManager.selectTab(at: clampedIndex)
    }

    /// Saves the current session for restore on next launch.
    func saveSessionForRestore() {
        guard !isPrivateMode else { return }
        let selectedIndex = tabManager.tabs.firstIndex(where: { $0.id == tabManager.selectedTabID })
        SessionRestoreManager.shared.saveSession(tabs: tabManager.tabs, groups: tabManager.tabGroups, selectedIndex: selectedIndex)
    }

    // MARK: - Screenshot

    // MARK: - Save PDF

    func savePDF() {
        guard let webView = tabManager.focusedTab?.webView, let url = webView.url else { return }
        // Use WebKit's own networking stack and route through the existing
        // WKDownloadDelegate (WebViewWrapper.Coordinator) for save panel + history
        webView.startDownload(using: URLRequest(url: url)) { download in
            download.delegate = webView.navigationDelegate as? WKDownloadDelegate
        }
    }

    // MARK: - Screenshot

    func captureScreenshot() {
        guard let webView = tabManager.focusedTab?.webView else { return }
        let config = WKSnapshotConfiguration()
        webView.takeSnapshot(with: config) { image, error in
            guard let image = image, error == nil else { return }
            // Convert to PNG
            guard let tiffData = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let pngData = bitmap.representation(using: .png, properties: [:]) else { return }

            // Save to Downloads
            let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let filename = "Screenshot_\(formatter.string(from: Date())).png"
            let fileURL = downloadsURL.appendingPathComponent(filename)

            do {
                try pngData.write(to: fileURL)
                DispatchQueue.main.async {
                    self.showStatusToast("Screenshot saved to Downloads", icon: "camera.fill")
                }
            } catch {
                // Silently fail
            }
        }
    }
}

// MARK: - Detached Window

/// Custom NSWindow subclass for detached tabs
class DetachedWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        self.isReleasedWhenClosed = false
    }
}

/// Delegate that cleans up detached window references when the window closes
class DetachedWindowDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let closedWindow = notification.object as? NSWindow else { return }
        // Defer cleanup to avoid mutating state during notification
        DispatchQueue.main.async {
            BrowserViewModel.detachedWindows.removeAll { $0 === closedWindow }
            BrowserViewModel.detachedWindowDelegates.removeAll { $0 === closedWindow.delegate as? DetachedWindowDelegate }
        }
    }
}

