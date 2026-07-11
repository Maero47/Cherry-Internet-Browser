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
    var verticalTabBarCollapsed: Bool {
        get { SettingsManager.shared.verticalTabBarCollapsed }
        set { SettingsManager.shared.verticalTabBarCollapsed = newValue }
    }

    let bookmarkRepository = BookmarkRepository.shared
    let historyRepository = HistoryRepository.shared
    let shortcutRepository = ShortcutRepository.shared
    let downloadRepository = DownloadRepository.shared
    let downloadManager = DownloadManager.shared
    let passwordManager = PasswordManager.shared
    let passwordRepository = PasswordRepository.shared

    var showAutoFillPopup: Bool = false

    // MARK: - Find in Page
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

    // MARK: - Screenshot toast
    var showScreenshotToast: Bool = false
    var screenshotToastMessage: String = ""

    // MARK: - Command Palette
    var showCommandPalette: Bool = false

    // MARK: - Video / Element Fullscreen
    var isVideoFullscreen: Bool = false

    // MARK: - Developer Tools
    var showDevToolsPanel: Bool = false

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
    private let instanceID = UUID()
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
        BrowserViewModel.viewModelRefs[instanceID] = WeakViewModelRef(self)
    }

    deinit {
        BrowserViewModel.viewModelRefs.removeValue(forKey: instanceID)
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

        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try to parse as URL first
        if let url = URL.fromUserInput(trimmedInput) {
            tab.loadURL(url)
        } else if trimmedInput.isLikelyURL {
            // It looks like a URL, try with https
            if let url = URL(string: "https://\(trimmedInput)") {
                tab.loadURL(url)
            } else {
                // Fall back to search
                performSearch(trimmedInput)
            }
        } else {
            // Treat as search query
            performSearch(trimmedInput)
        }
    }

    func performSearch(_ query: String) {
        guard let tab = currentTab,
              let searchURL = URL.searchURL(for: query, engine: searchEngine) else { return }
        tab.loadURL(searchURL)
    }

    func goBack() {
        currentTab?.goBack()
    }

    func goForward() {
        currentTab?.goForward()
    }

    func reload() {
        currentTab?.reload()
    }

    func stopLoading() {
        currentTab?.stopLoading()
    }

    func goHome() {
        newTab()
    }

    func showSettings() {
        guard let tab = currentTab else { return }
        tab.showSettingsPage = true
        tab.showHomePage = false
        tab.title = "Settings"
    }

    func toggleAdBlockForCurrentSite() {
        guard let tab = currentTab, let webView = tab.webView else { return }
        SettingsManager.shared.toggleAdBlockPause(for: tab.url)

        // Actually add/remove content blocker rules on the existing webview
        let controller = webView.configuration.userContentController
        let isPaused = SettingsManager.shared.isAdBlockPaused(for: tab.url)

        if isPaused {
            // Remove all content rule lists to disable ad blocking
            controller.removeAllContentRuleLists()
        } else {
            // Re-apply ad blocker rules
            AdBlockManager.shared.applyRules(to: webView.configuration)
        }

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

    /// Handle a tab dropped on the content area — detach to new window
    func handleContentAreaDrop() -> Bool {
        guard let draggedID = TabManager.draggedTabID else { return false }
        TabManager.draggedTabID = nil

        // Find the tab across all windows
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
        let hostingView = NSHostingView(rootView: newBrowserView)

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
        isPrivateMode.toggle()
        // Update all existing tabs and drop their web views so they are
        // recreated with the correct data store when next displayed.
        // (The data store is fixed in the WKWebViewConfiguration at creation,
        // so a plain reload can never switch between private and normal.)
        for tab in tabManager.tabs {
            tab.isPrivate = isPrivateMode
            tab.webView = nil
        }
        // The on-screen WKWebView is keyed by tab.id, so nilling webView alone
        // leaves the old view (with the old data store) visible. Replace the
        // current tab with a fresh one to force WebViewWrapper to rebuild.
        if let tab = currentTab, let url = tab.url {
            let fresh = tabManager.duplicateTab(tab)
            fresh.isPrivate = isPrivateMode
            fresh.loadURL(url)
            _ = tabManager.removeTab(tab)
        }
    }

    func openPrivateWindow() {
        let newBrowserView = BrowserView(isPrivate: true)
        let hostingView = NSHostingView(rootView: newBrowserView)

        let window = DetachedWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.isMovable = false
        window.backgroundColor = .windowBackgroundColor
        window.titlebarSeparatorStyle = .none
        window.title = "Private Browsing"

        BrowserViewModel.detachedWindows.append(window)

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { notification in
            guard let closedWindow = notification.object as? NSWindow else { return }
            BrowserViewModel.detachedWindows.removeAll { $0 === closedWindow }
        }

        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Vertical Tabs

    func toggleVerticalTabs() {
        useVerticalTabs.toggle()
    }

    func toggleVerticalTabBarCollapsed() {
        verticalTabBarCollapsed.toggle()
    }

    // MARK: - Bookmarks

    func toggleBookmarkBar() {
        showBookmarkBar.toggle()
    }

    func addBookmark(title: String, folder: String?, isInBookmarkBar: Bool) {
        guard let tab = currentTab, let url = tab.url else { return }
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
        sidebarContent = .downloads
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
        guard let tab = currentTab, let webView = tab.webView else { return }
        let credentials = passwordManager.matchingCredentials
        if credentials.count == 1 {
            passwordManager.fillCredentials(credentials[0], in: webView)
        } else {
            showAutoFillPopup = true
        }
    }

    func fillCredential(_ credential: PasswordItem) {
        guard let webView = currentTab?.webView else { return }
        passwordManager.fillCredentials(credential, in: webView)
        showAutoFillPopup = false
    }

    func generateAndFillPassword() {
        guard let webView = currentTab?.webView else { return }
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

    // MARK: - Find in Page

    private var findHelperInjected = false

    /// Injects the find helper JS once per page. Uses querySelectorAll to clear
    /// old marks so it never loses track of highlights even if called again.
    /// The presence check must live in JS: the helper is wiped by every
    /// navigation and is per-page, while this view model spans pages and tabs,
    /// so a Swift-side "already injected" flag goes stale and breaks find.
    private func injectFindHelperIfNeeded(in webView: WKWebView, completion: @escaping () -> Void) {
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
        webView.evaluateJavaScript(js) { [weak self] _, _ in
            self?.findHelperInjected = true
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
        guard let webView = currentTab?.webView, !findQuery.isEmpty else { return }
        webView.evaluateJavaScript("window.__cherryFind.next();") { [weak self] result, _ in
            guard let self, let dict = result as? [String: Any],
                  let c = dict["c"] as? Int, let t = dict["t"] as? Int else { return }
            self.findCurrentMatch = c
            self.findTotalMatches = t
        }
    }

    func findPrevious() {
        guard let webView = currentTab?.webView, !findQuery.isEmpty else { return }
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
        guard let webView = currentTab?.webView else { return }
        let escaped = escapeFindQuery(query)
        injectFindHelperIfNeeded(in: webView) { [weak self] in
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
        guard let webView = currentTab?.webView else { return }
        if findHelperInjected {
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
        findHelperInjected = false
    }

    // MARK: - Print / Save as PDF

    func printCurrentPage() {
        guard let webView = currentTab?.webView else { return }
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
        guard let webView = currentTab?.webView else { return }
        Task { @MainActor in
            if let content = await ReaderModeExtractor.extract(from: webView) {
                self.readerContent = content
                self.showReaderMode = true
            }
        }
    }

    // MARK: - Picture-in-Picture

    static var pipWindow: NSPanel?
    static var pipSourceTab: Tab?
    static var pipCloseObserver: Any?

    static func cleanupPiP() {
        // Remove the hide-UI CSS from the webView
        if let webView = pipSourceTab?.webView {
            webView.evaluateJavaScript("""
            (function() {
                var s = document.getElementById('__cherry-pip-style');
                if (s) s.remove();
            })();
            """, completionHandler: nil)
        }
        pipSourceTab = nil
        pipWindow = nil
        if let observer = pipCloseObserver {
            NotificationCenter.default.removeObserver(observer)
            pipCloseObserver = nil
        }
    }

    func togglePictureInPicture() {
        // If PiP window already open, close it and return webView to tab
        if let existing = BrowserViewModel.pipWindow {
            // Move webView back to the tab (SwiftUI will reclaim it via WebViewWrapper)
            existing.contentView = nil
            existing.close()
            BrowserViewModel.cleanupPiP()
            return
        }

        guard let tab = currentTab, let webView = tab.webView else { return }

        // Delay slightly so the menu fully dismisses
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }

            // Inject CSS to hide everything except video
            let hideJS = """
            (function() {
                var s = document.createElement('style');
                s.id = '__cherry-pip-style';
                var isYT = location.hostname.includes('youtube.com');
                if (isYT) {
                    s.textContent = `
                        #masthead, #below, #secondary, #comments, #related,
                        ytd-masthead, #guide, #guide-button, tp-yt-app-drawer,
                        ytd-mini-guide-renderer, #header, #page-manager > *:not(ytd-watch-flexy),
                        .ytp-chrome-top, .ytp-pause-overlay, .ytp-gradient-top,
                        ytd-watch-metadata, #meta, #info, #ticket-shelf,
                        #description, #actions, #menu, #subscribe-button,
                        .ytd-watch-flexy > #columns > #secondary,
                        #chat, #above-the-fold, #bottom-row {
                            display: none !important;
                        }
                        body { overflow: hidden !important; background: #000 !important; }
                        #player, #movie_player, .html5-main-video, video {
                            position: fixed !important; top: 0 !important; left: 0 !important;
                            width: 100vw !important; height: 100vh !important;
                            max-width: 100vw !important; max-height: 100vh !important;
                            object-fit: contain !important;
                        }
                        #columns { padding: 0 !important; margin: 0 !important; }
                        ytd-watch-flexy { padding: 0 !important; margin: 0 !important; }
                    `;
                } else {
                    s.textContent = `
                        body > *:not(video) { opacity: 0 !important; pointer-events: none !important; }
                        body { background: #000 !important; overflow: hidden !important; margin: 0 !important; }
                        video {
                            position: fixed !important; top: 0 !important; left: 0 !important;
                            width: 100vw !important; height: 100vh !important;
                            max-width: 100vw !important; max-height: 100vh !important;
                            object-fit: contain !important; z-index: 2147483647 !important;
                            opacity: 1 !important; pointer-events: auto !important;
                        }
                    `;
                }
                document.head.appendChild(s);
                var v = document.querySelector('video');
                var w = (v && v.videoWidth) || 640;
                var h = (v && v.videoHeight) || 360;
                return { w: w, h: h };
            })();
            """
            webView.evaluateJavaScript(hideJS) { [weak self] result, _ in
                guard let self else { return }
                let info = result as? [String: Any]
                let videoW = info?["w"] as? Int ?? 640
                let videoH = info?["h"] as? Int ?? 360

                // Detach webView from its current superview and put into floating panel
                webView.removeFromSuperview()

                let maxWidth: CGFloat = 480
                let aspect = videoH > 0 ? CGFloat(videoW) / CGFloat(videoH) : 16.0 / 9.0
                let pipWidth = min(maxWidth, CGFloat(videoW))
                let pipHeight = pipWidth / aspect

                let panel = NSPanel(
                    contentRect: NSRect(x: 0, y: 0, width: pipWidth, height: pipHeight),
                    styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow, .hudWindow],
                    backing: .buffered,
                    defer: false
                )
                panel.contentView = webView
                panel.isFloatingPanel = true
                panel.level = .floating
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                panel.titlebarAppearsTransparent = true
                panel.titleVisibility = .hidden
                panel.isMovableByWindowBackground = true
                panel.backgroundColor = .black
                panel.hasShadow = true
                panel.animationBehavior = .utilityWindow
                panel.aspectRatio = NSSize(width: aspect, height: 1)

                if let screen = NSScreen.main {
                    let screenFrame = screen.visibleFrame
                    let x = screenFrame.maxX - pipWidth - 20
                    let y = screenFrame.minY + 20
                    panel.setFrameOrigin(NSPoint(x: x, y: y))
                }

                BrowserViewModel.pipWindow = panel
                BrowserViewModel.pipSourceTab = tab

                BrowserViewModel.pipCloseObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification,
                    object: panel,
                    queue: .main
                ) { _ in
                    // Return webView to tab by removing hide CSS (SwiftUI will re-add it)
                    panel.contentView = nil
                    BrowserViewModel.cleanupPiP()
                }

                panel.makeKeyAndOrderFront(nil)
            }
        }
    }

    // MARK: - Command Palette

    func toggleCommandPalette() {
        showCommandPalette.toggle()
    }

    // MARK: - Developer Tools

    func toggleDevTools() {
        showDevToolsPanel.toggle()
    }

    /// Execute arbitrary JS in the active tab and return a formatted result string.
    func evaluateJSForDevTools(_ js: String, completion: @escaping (String?) -> Void) {
        guard let webView = currentTab?.webView else { completion(nil); return }
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
        guard let webView = currentTab?.webView else { return }
        let js = DevToolsManager.highlightScript(for: selector)
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Apply edited outer HTML to the element matching `selector` (base64-encoded).
    func applyHTMLInDevTools(selector: String, base64HTML: String,
                             completion: @escaping (String?) -> Void) {
        guard let webView = currentTab?.webView else { completion("no webview"); return }
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

    /// Restores the previous session if the setting is enabled and a saved session exists.
    func restoreSessionIfNeeded() {
        guard !isPrivateMode,
              SettingsManager.shared.restorePreviousSession,
              SessionRestoreManager.shared.hasSavedSession else { return }

        let entries = SessionRestoreManager.shared.loadSavedTabs()
        let selectedIndex = SessionRestoreManager.shared.loadSelectedIndex()
        SessionRestoreManager.shared.clearSession()

        guard !entries.isEmpty else { return }

        // Replace the default blank tab with the restored session
        let hadOnlyBlankTab = tabManager.tabs.count == 1 && tabManager.tabs.first?.url == nil

        for (i, entry) in entries.enumerated() {
            guard let url = URL(string: entry.urlString) else { continue }
            if i == 0 && hadOnlyBlankTab, let firstTab = tabManager.tabs.first {
                // Re-use the existing blank tab for the first restored URL
                firstTab.title = entry.title
                firstTab.showHomePage = false
                firstTab.loadURL(url)
            } else {
                let tab = tabManager.newTab(url: url)
                tab.title = entry.title
                tab.showHomePage = false
                tab.loadURL(url)
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
        SessionRestoreManager.shared.saveSession(tabs: tabManager.tabs, selectedIndex: selectedIndex)
    }

    // MARK: - Screenshot

    // MARK: - Save PDF

    func savePDF() {
        guard let webView = currentTab?.webView, let url = webView.url else { return }
        // Use WebKit's own networking stack and route through the existing
        // WKDownloadDelegate (WebViewWrapper.Coordinator) for save panel + history
        webView.startDownload(using: URLRequest(url: url)) { download in
            download.delegate = webView.navigationDelegate as? WKDownloadDelegate
        }
    }

    // MARK: - Screenshot

    func captureScreenshot() {
        guard let webView = currentTab?.webView else { return }
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
                    self.screenshotToastMessage = "Screenshot saved to Downloads"
                    self.showScreenshotToast = true
                    // Auto-dismiss after 3 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        self.showScreenshotToast = false
                    }
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

