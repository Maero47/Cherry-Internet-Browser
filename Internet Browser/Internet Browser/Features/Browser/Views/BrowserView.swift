//
//  BrowserView.swift
//  Cherry Browser
//

import SwiftUI
import UniformTypeIdentifiers

struct BrowserView: View {
    @State private var viewModel: BrowserViewModel
    /// Which content-area edge zone (if any) a dragged tab currently hovers,
    /// so the drop indicator bar can be shown/hidden during the drag.
    @State private var dragHoverEdge: Edge? = nil

    /// The action-permission authority, observed so this window raises the
    /// consent sheet the moment a request for one of its tabs arrives.
    @State private var actionSessions = WebActionSessionStore.shared

    /// `presentsSetupWizardIfFirstRun` is passed true only by
    /// `openBrowserWindow` — a window that is actually presented. The
    /// `WindowGroup` scene builds a `BrowserView()` too (never shown, see
    /// `Internet_BrowserApp`), and letting it try would consume the wizard's
    /// once-per-session claim on a window nobody sees.
    init(initialURL: URL? = nil, isPrivate: Bool = false, presentsSetupWizardIfFirstRun: Bool = false) {
        let vm = BrowserViewModel()
        vm.isPrivateMode = isPrivate
        if let tab = vm.tabManager.selectedTab {
            tab.isPrivate = isPrivate
            if let url = initialURL {
                tab.url = url
                tab.showHomePage = false
                tab.title = url.host ?? "Loading..."
            }
        }
        if presentsSetupWizardIfFirstRun {
            vm.attachSetupWizardIfEligible()
        }
        _viewModel = State(initialValue: vm)
    }

    /// Init with an existing tab (preserves webView state, no reload)
    init(existingTab: Tab) {
        let vm = BrowserViewModel(withDefaultTab: false)
        vm.isPrivateMode = existingTab.isPrivate
        vm.tabManager.addExistingTab(existingTab)
        _viewModel = State(initialValue: vm)
    }

    var body: some View {
        configuredLayout
            // The first-run setup wizard, over the launch window only (the
            // one window whose view model won the presentation claim). A
            // sheet cannot re-open the window bring-up bug: the flag below
            // flips a runloop turn AFTER `openBrowserWindow` has completed
            // frame → configure → show (`attachSetupWizardIfEligible`), so
            // the sheet only ever presents over an already-shown window, and
            // it never touches this window's frame. Dismissing it by ANY
            // route funnels through `showSetupWizard`'s didSet, which writes
            // the first-run marker — so Escape is a skip, not a loophole.
            .sheet(isPresented: $viewModel.showSetupWizard) {
                SetupWizardView(onFinish: { viewModel.showSetupWizard = false })
            }
            .sheet(isPresented: $viewModel.showAddBookmark) {
                // The focused pane's tab, not always the primary — so bookmarking
                // from the secondary pane saves THAT pane's page.
                if let tab = viewModel.tabManager.focusedTab, let url = tab.url {
                    AddBookmarkView(
                        url: url,
                        pageTitle: tab.title,
                        favicon: tab.favicon
                    ) { title, folder, isInBar in
                        viewModel.addBookmark(title: title, folder: folder, isInBookmarkBar: isInBar)
                    }
                }
            }
            // The action-session prompt, on the tab's OWN window rather than as a
            // global alert: the sheet names a tab, and a permission dialog that
            // appears over a different window than the one it is about is a
            // dialog the user answers about the wrong thing.
            //
            // Dismissing it any other way — Escape, clicking away — is a decline.
            // The safe answer has to be the reflexive one.
            .sheet(item: Binding(
                get: { actionSessions.pendingRequest(forTabIn: viewModel.tabManager.tabIDs) },
                set: { newValue in
                    guard newValue == nil,
                          let request = actionSessions.pendingRequest(
                              forTabIn: viewModel.tabManager.tabIDs
                          )
                    else { return }
                    actionSessions.decline(request.id)
                }
            )) { request in
                WebActionConsentSheet(
                    request: request,
                    onAllow: { actionSessions.allow(request.id) },
                    onDecline: { actionSessions.decline(request.id) }
                )
            }
            // HTTP authentication, on the tab's own window for the same reason
            // the consent sheet above is. Dismissing it any other way (Escape,
            // clicking away) declines the challenge, which leaves the tab on
            // the page it was already showing.
            .sheet(item: Binding(
                get: { viewModel.pendingAuthPrompt },
                set: { newValue in
                    guard newValue == nil, let prompt = viewModel.pendingAuthPrompt else { return }
                    prompt.resolve(.cancel)
                    viewModel.pendingAuthPrompt = nil
                }
            )) { prompt in
                HTTPAuthSheet(
                    prompt: prompt,
                    // A private window neither reads the vault nor writes to it.
                    savedCredentials: prompt.isPrivate
                        ? []
                        : viewModel.passwordRepository.credentials(for: prompt.url),
                    revealSaved: { item, completion in
                        viewModel.revealSavedPassword(item, completion: completion)
                    },
                    onSubmit: { user, password, remember in
                        prompt.resolve(.credential(user: user, password: password, remember: remember))
                    },
                    onCancel: { prompt.resolve(.cancel) }
                )
            }
            .alert(
                viewModel.isPrivateMode ? "Exit Incognito Mode?" : "Enter Incognito Mode?",
                isPresented: $viewModel.showPrivateModeAlert
            ) {
                Button(viewModel.isPrivateMode ? "Exit" : "Enter", role: viewModel.isPrivateMode ? .destructive : nil) {
                    viewModel.confirmTogglePrivateMode()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if viewModel.isPrivateMode {
                    Text("Exiting incognito mode will restore normal browsing. Your tabs will reload with standard browsing data.")
                } else {
                    Text("In incognito mode, your browsing history, cookies, and site data won't be saved after you close the window.")
                }
            }
            .overlay { tabSearchOverlay }
            .overlay(alignment: .topTrailing) { downloadToastOverlay }
            .overlay(alignment: .top) { savePasswordOverlay }
            .overlay(alignment: .bottom) { findInPageOverlay }
            .overlay { readerModeOverlay }
            .overlay { qrCodeOverlay }
            .overlay(alignment: .bottom) { screenshotToastOverlay }
            .overlay { commandPaletteOverlay }
            .overlay(alignment: .trailing) { viewSourceOverlay }
            .overlay(alignment: .trailing) { askThisPageOverlay }
            .overlay { focusBlockOverlay }
            .animation(.spring(duration: 0.3), value: viewModel.passwordManager.showSavePrompt)
            .animation(.spring(duration: 0.3), value: viewModel.showDownloadToast)
            .animation(.spring(duration: 0.3), value: viewModel.showFindInPage)
            .animation(.spring(duration: 0.3), value: viewModel.showReaderMode)
            .animation(.spring(duration: 0.3), value: viewModel.showQRCode)
            .animation(.spring(duration: 0.3), value: viewModel.showScreenshotToast)
            .animation(.spring(duration: 0.25), value: viewModel.showCommandPalette)
            .animation(.spring(duration: 0.25), value: viewModel.showDevToolsPanel)
            .animation(.spring(duration: 0.3), value: viewModel.showViewSource)
            .animation(.spring(duration: 0.3), value: viewModel.showAskThisPage)
            .animation(.spring(duration: 0.25), value: viewModel.showFocusBlock)
            .onChange(of: viewModel.showQRCode) { _, newValue in
                // When the QR popup is dismissed, the WKWebView has lost first responder
                // because the full-screen dimmed overlay captured all input while it was
                // visible. Restore focus after the spring animation finishes (~0.35 s).
                guard !newValue else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    if let webView = viewModel.tabManager.focusedTab?.webView {
                        NSApp.keyWindow?.makeFirstResponder(webView)
                    }
                }
            }
            .onChange(of: viewModel.findQuery) { _, _ in
                viewModel.performFind()
            }
            .onChange(of: viewModel.tabManager.focusedPaneIsSecondary) { _, _ in
                // Cmd+F targets the focused pane, so when focus switches
                // panes mid-search, re-run against the newly-focused tab
                // instead of leaving the bar showing the old pane's counts.
                viewModel.refreshFindForFocusChange()
            }
            .onChange(of: viewModel.downloadManager.downloadStartedTrigger) { _, _ in
                guard let id = viewModel.downloadManager.latestDownloadID else { return }
                viewModel.toastDismissTask?.cancel()
                viewModel.toastIsCompleted = false
                viewModel.toastDownloadID = id
                viewModel.showDownloadToast = true
            }
            .onChange(of: viewModel.downloadManager.downloadCompletedTrigger) { _, _ in
                guard let id = viewModel.downloadManager.lastCompletedDownloadID else { return }
                viewModel.toastIsCompleted = true
                viewModel.toastDownloadID = id
                viewModel.toastDismissTask?.cancel()
                viewModel.toastDismissTask = Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        viewModel.showDownloadToast = false
                    }
                }
            }
    }

    // Split from body to keep the modifier chain short enough for the Swift type-checker
    private var configuredLayout: some View {
        // No `.frame(minWidth:)` here on purpose. A minimum expressed on the
        // CONTENT is invisible to the hand-built windows (⌘N, incognito,
        // detached tabs), so those windows could be dragged narrower than it —
        // and the content then pinned at the minimum inside a narrower window,
        // laying out the whole chrome (homepage included) against a width the
        // window didn't have: the search field ran off the right edge and the
        // clock sat off-centre. The minimum lives on the WINDOW instead
        // (`BrowserWindowMinimum`, applied by `configureBrowserWindow` and
        // kept in step with split view below), where AppKit can actually
        // enforce it, and the content always lays out at the width the window
        // really has.
        menuRoutedLayout
            .ignoresSafeArea(.all, edges: .top)
            .background(Color(nsColor: .windowBackgroundColor))
            .background { WindowConfigurator() }
            .background { WindowRegistrar(viewModel: viewModel) }
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.return) { .ignored }
            .background { escapeShortcut }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { _ in
                viewModel.isFullScreen = true
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in
                viewModel.isFullScreen = false
            }
            .onReceive(NotificationCenter.default.publisher(for: .showConsole)) { _ in
                // Not a command: WebViewWrapper posts this from the page's
                // "Inspect Element" context menu, which is always in the key
                // window — the guard keeps every OTHER window's dev tools panel
                // from popping open alongside it.
                guard isKeyBrowserWindow else { return }
                viewModel.showDevToolsPanel = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .siteBlocked)) { notification in
                let host = notification.userInfo?["host"] as? String ?? ""
                let urlString = notification.userInfo?["url"] as? String ?? ""
                viewModel.focusBlockedHost = host
                viewModel.focusBlockedURL = URL(string: urlString)
                viewModel.showFocusBlock = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .focusModeSessionEnded)) { _ in
                viewModel.showFocusBlock = false
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                viewModel.saveSessionForRestore()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
                guard let closing = notification.object as? NSWindow,
                      closing === viewModel.associatedWindow else { return }
                ExtensionManager.shared.windowClosed(viewModel)
                guard !viewModel.isPrivateMode else {
                    // A certificate exception made in a private window dies
                    // with private browsing, not with the process.
                    viewModel.forgetPrivateCertificateExceptionsIfLastPrivateWindow()
                    return
                }
                viewModel.saveSessionForRestore()
            }
            .onAppear {
                viewModel.restoreSessionIfNeeded()
            }
            .onChange(of: viewModel.tabManager.isSplitActive) { _, isSplit in
                applyWindowMinimum(splitActive: isSplit)
            }
    }

    /// Split view needs two 400pt panes plus chrome, so its window floor is
    /// wider. Raised when the split opens — growing the window if it is
    /// currently narrower, so the panes are laid out inside the window rather
    /// than past its edge — and lowered again when it closes.
    private func applyWindowMinimum(splitActive: Bool) {
        guard let window = viewModel.associatedWindow else { return }
        let minimum = BrowserWindowMinimum.contentSize(splitActive: splitActive)
        window.contentMinSize = minimum
        if window.frame.width < minimum.width {
            var frame = window.frame
            frame.size.width = minimum.width
            window.setFrame(frame, display: true, animate: true)
        }
    }

    // MARK: - Extracted Sub-Views

    /// Menu-bar commands are broadcast app-wide, so only the key window's
    /// browser reacts — otherwise every open window would run the command
    /// (e.g. navigate its tab to an internal page) at once.
    ///
    /// `CommandRouting.shouldRun` rather than a bare `===` so an unregistered
    /// or closed window fails CLOSED; see its doc comment for why the obvious
    /// spelling is wrong.
    private var isKeyBrowserWindow: Bool {
        CommandRouting.shouldRun(in: viewModel.associatedWindow, keyWindow: NSApp.keyWindow)
    }

    /// The one and only place a menu command turns into an action. Kept out of
    /// `configuredLayout` so its modifier chain stays type-checkable.
    private var menuRoutedLayout: some View {
        browserLayout
            .onReceive(NotificationCenter.default.publisher(for: .browserCommand)) { notification in
                guard isKeyBrowserWindow,
                      let command = BrowserCommand(notification: notification) else { return }
                perform(command)
            }
    }

    /// Runs a menu command against THIS window. Page-scoped commands act on the
    /// focused split pane's tab, matching what clicking that pane's own nav-bar
    /// control does.
    private func perform(_ command: BrowserCommand) {
        let focusedTab = viewModel.tabManager.focusedTab

        // Cmd+1…Cmd+9.
        if let index = command.tabIndex {
            viewModel.selectTab(at: index)
            return
        }

        switch command {
        // Tabs
        case .newTab: viewModel.newTab()
        case .closeTab: viewModel.closeCurrentTab()
        case .reopenClosedTab: viewModel.reopenClosedTab()
        case .selectNextTab: viewModel.selectNextTab()
        case .selectPreviousTab: viewModel.selectPreviousTab()
        case .searchTabs: viewModel.toggleTabSearch()

        // Navigation
        case .goBack: if let focusedTab { viewModel.goBack(for: focusedTab) }
        case .goForward: if let focusedTab { viewModel.goForward(for: focusedTab) }
        case .reloadPage: if let focusedTab { viewModel.reload(for: focusedTab) }
        case .stopLoading: if let focusedTab { viewModel.stopLoading(for: focusedTab) }

        // Zoom
        case .zoomIn: viewModel.zoomIn(for: focusedTab)
        case .zoomOut: viewModel.zoomOut(for: focusedTab)
        case .actualSize: viewModel.resetZoom(for: focusedTab)

        // Layout
        case .toggleBookmarkBar: viewModel.toggleBookmarkBar()
        case .toggleVerticalTabs: viewModel.toggleVerticalTabs()
        case .toggleSplitView: viewModel.toggleSplitView()
        case .focusAddressBar: viewModel.focusAddressBar()

        // Internal pages
        case .showHistory: viewModel.openInternalPage(.history)
        case .showBookmarks: viewModel.openInternalPage(.bookmarks)
        case .showDownloads: viewModel.openInternalPage(.downloads)
        case .showSettingsPage: viewModel.openInternalPage(.settings)
        case .addBookmark: viewModel.showAddBookmark = true

        // Find & palette
        case .findInPage: viewModel.toggleFindInPage()
        case .showCommandPalette: viewModel.toggleCommandPalette()

        // Tools
        case .printPage: viewModel.printCurrentPage()
        case .toggleReaderMode: viewModel.toggleReaderMode()
        case .captureScreenshot: viewModel.captureScreenshot()
        case .toggleFocusMode: viewModel.toggleFocusMode()
        case .askThisPage: viewModel.toggleAskThisPage()
        case .autoFillPassword: viewModel.autoFillCurrentPage()

        // Develop
        case .showWebInspector: viewModel.toggleDevTools()
        case .showConsole: viewModel.showDevToolsPanel = true
        case .viewSource: viewModel.fetchAndShowViewSource()

        // Handled above.
        case .selectTab1, .selectTab2, .selectTab3, .selectTab4, .selectTab5,
             .selectTab6, .selectTab7, .selectTab8, .selectTab9:
            break
        }
    }

    @ViewBuilder
    private var browserLayout: some View {
        // The GeometryReader publishes the window content's global frame as
        // the virtual canvas Firefox theme header images anchor to, so the
        // tab strip, nav bars (incl. split panes), and vertical sidebar all
        // render slices of ONE continuous window-wide backdrop.
        GeometryReader { geometry in
            browserChrome
                .environment(\.chromeCanvasFrame, geometry.frame(in: .global))
        }
    }

    @ViewBuilder
    private var browserChrome: some View {
        HStack(spacing: 0) {
            if viewModel.useVerticalTabs && !viewModel.isVideoFullscreen {
                // The sidebar sizes itself (single source of truth for the
                // collapsed/expanded width lives in VerticalTabBarView).
                VerticalTabBarView(
                    tabManager: viewModel.tabManager,
                    isCollapsed: $viewModel.verticalTabBarCollapsed,
                    isPrivateMode: viewModel.isPrivateMode,
                    onNewTab: { viewModel.newTab() },
                    onDetachTab: { tab in viewModel.detachTab(tab) },
                    onReceiveTab: { tabID in
                        _ = BrowserViewModel.transferTab(tabID: tabID, to: viewModel)
                    },
                    onSplitOnEdge: { tab, edge in viewModel.splitWith(tab: tab, edge: edge) }
                )
                // Above the content column so the collapsed bar's transient
                // hover-expansion flies OVER the page instead of reflowing it.
                .zIndex(1)
            }

            VStack(spacing: 0) {
                if !viewModel.useVerticalTabs && !viewModel.isVideoFullscreen {
                    TabBarView(
                        tabManager: viewModel.tabManager,
                        isFullScreen: viewModel.isFullScreen,
                        isPrivateMode: viewModel.isPrivateMode,
                        onNewTab: { viewModel.newTab() },
                        onDetachTab: { tab in viewModel.detachTab(tab) },
                        onReceiveTab: { tabID in
                            _ = BrowserViewModel.transferTab(tabID: tabID, to: viewModel)
                        },
                        onSplitOnEdge: { tab, edge in viewModel.splitWith(tab: tab, edge: edge) }
                    )
                    // Above the page, for the same reason the navigation bar
                    // below already is (`.zIndex(200)`): a tab's WKWebView is an
                    // AppKit view hosted inside this SwiftUI stack, and AppKit
                    // composites a hosted view above SwiftUI siblings that have
                    // no z-order of their own. In a window nothing notices,
                    // because the host sits exactly in its slot. Entering
                    // fullscreen resizes it to the whole window before SwiftUI
                    // re-lays the stack, and from then on it covers the chrome.
                    //
                    // The strip was never missing: it was drawn, at the right
                    // size, in the right place, underneath the page. Measured in
                    // fullscreen it reported 1920x38 at the top of the window
                    // while showing nothing at all.
                    .zIndex(ChromeLayer.tabStrip)
                    // Chrome-on-chrome separator: the tab strip and the toolbar
                    // below it are two slices of ONE themed backdrop, so under a
                    // theme this hairline paints a grey line straight across the
                    // header art. The theme supplies its own separation — the
                    // stock look keeps the separator, themed chrome doesn't get
                    // one overdrawn on it. Private windows are never themed
                    // (every themed branch gates on !isPrivateMode), so theirs
                    // stays even while a theme is loaded.
                    if viewModel.isPrivateMode || !FirefoxThemeManager.shared.hasHeaderBackdrop {
                        Rectangle()
                            .fill(Color.primary.opacity(0.08))
                            .frame(height: 0.5)
                    }
                }

                // "Something outside Cherry is clicking in this window right
                // now", and the one click that stops it.
                //
                // Window level, above the panes, and OUTSIDE the
                // `!isVideoFullscreen` guards the rest of the chrome sits behind.
                // A grant survives tab switching, so a bar that only existed
                // while the acted-on tab was displayed left an agent working in
                // one tab with no sign anywhere while the user read another —
                // and no way to end it without guessing which tab to switch to.
                WebActionSessionBar(viewModel: viewModel)

                if viewModel.tabManager.isSplitActive,
                   let primaryTab = viewModel.tabManager.selectedTab,
                   let secondaryTab = viewModel.tabManager.secondarySelectedTab,
                   primaryTab.id != secondaryTab.id {
                    HSplitView {
                        paneContentView(
                            tab: primaryTab,
                            isFocused: !viewModel.tabManager.focusedPaneIsSecondary,
                            isSplitPane: true,
                            // Weak: this closure becomes CherryWebView.onFocused,
                            // retained by the webview — a strong viewModel capture
                            // would leak the window graph (webView → closure →
                            // viewModel → tab → webView).
                            onFocusPane: { [weak viewModel] in viewModel?.tabManager.focusedPaneIsSecondary = false }
                        )
                        .onDrop(of: [.cherryBrowserTab], isTargeted: nil) { providers in
                            viewModel.handleContentAreaDrop()
                        }
                        .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)

                        paneContentView(
                            tab: secondaryTab,
                            isFocused: viewModel.tabManager.focusedPaneIsSecondary,
                            isSplitPane: true,
                            // Weak: same webview-retained closure as the primary pane.
                            onFocusPane: { [weak viewModel] in viewModel?.tabManager.focusedPaneIsSecondary = true }
                        )
                        .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else if let currentTab = viewModel.currentTab {
                    GeometryReader { geometry in
                        paneContentView(
                            tab: currentTab,
                            isFocused: true,
                            isSplitPane: false,
                            onFocusPane: nil
                        )
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .onDrop(
                            of: [.cherryBrowserTab],
                            delegate: ContentAreaDropDelegate(
                                contentWidth: geometry.size.width,
                                hoverEdge: $dragHoverEdge,
                                onDrop: { edge in viewModel.handleContentAreaDrop(edge: edge) }
                            )
                        )
                        .overlay(alignment: .leading) {
                            edgeDropIndicator(isActive: dragHoverEdge == .leading)
                        }
                        .overlay(alignment: .trailing) {
                            edgeDropIndicator(isActive: dragHoverEdge == .trailing)
                        }
                    }
                } else {
                    emptyState
                }

                // Rendered ONCE here, below the split (not per-pane inside
                // BrowserContentView), so split view never shows two stacked
                // dev tools panels. Scoped to the focused pane's tab.
                devToolsPanelOverlay
            }
            .frame(maxWidth: .infinity)

            if viewModel.isSidebarVisible && !viewModel.isVideoFullscreen {
                Divider()
                sidebarView
            }
        }
    }

    /// Builds a `BrowserContentView` whose action closures target `tab`
    /// specifically, so each split-view pane operates on its own tab rather
    /// than whichever tab `viewModel.currentTab` currently resolves to.
    ///
    /// Every closure calls `onFocusPane?()` first so clicking ANY nav-bar
    /// control (not just the background tap) focuses this pane — required
    /// because the page-scoped VM actions below (bookmark, adblock, autofill,
    /// print, screenshot, QR, save PDF, private mode, reader mode, PiP) read
    /// `tabManager.focusedTab` internally, so focus must already point at
    /// this pane by the time they run.
    @ViewBuilder
    private func paneContentView(
        tab: Tab,
        isFocused: Bool,
        isSplitPane: Bool,
        onFocusPane: (() -> Void)?
    ) -> some View {
        BrowserContentView(
            viewModel: viewModel,
            tab: tab,
            isFocused: isFocused,
            isSplitPane: isSplitPane,
            onFocusPane: onFocusPane,
            onNavigate: { onFocusPane?(); viewModel.navigate(to: $0, in: tab) },
            onBack: { onFocusPane?(); viewModel.goBack(for: tab) },
            onForward: { onFocusPane?(); viewModel.goForward(for: tab) },
            onReload: { onFocusPane?(); viewModel.reload(for: tab) },
            onStop: { onFocusPane?(); viewModel.stopLoading(for: tab) },
            onHome: { onFocusPane?(); viewModel.goHome(for: tab) },
            onBookmark: { onFocusPane?(); viewModel.showAddBookmark = true },
            // These navigate THIS pane's tab to the matching cherry:// page,
            // so each split pane tracks its own internal page independently.
            onToggleHistory: { onFocusPane?(); viewModel.openInternalPage(.history, in: tab) },
            onToggleBookmarks: { onFocusPane?(); viewModel.openInternalPage(.bookmarks, in: tab) },
            onDownloads: { onFocusPane?(); viewModel.openInternalPage(.downloads, in: tab) },
            onSettings: { onFocusPane?(); viewModel.openInternalPage(.settings, in: tab) },
            onToggleAdBlock: { onFocusPane?(); viewModel.toggleAdBlockForCurrentSite() },
            onTogglePrivateMode: { onFocusPane?(); viewModel.requestTogglePrivateMode() },
            onAutoFill: { onFocusPane?(); viewModel.toggleAutoFillPopup() },
            onGeneratePassword: { onFocusPane?(); viewModel.generateAndFillPassword() },
            onPrint: { onFocusPane?(); viewModel.printCurrentPage() },
            onToggleReaderMode: { onFocusPane?(); viewModel.toggleReaderMode() },
            onPictureInPicture: { onFocusPane?(); viewModel.togglePictureInPicture() },
            onScreenshot: { onFocusPane?(); viewModel.captureScreenshot() },
            onQRCode: { onFocusPane?(); viewModel.showQRCode = true },
            onSavePDF: { onFocusPane?(); viewModel.savePDF() },
            onToggleFocusMode: { onFocusPane?(); viewModel.toggleFocusMode() },
            onAskThisPage: { onFocusPane?(); viewModel.toggleAskThisPage() }
        )
    }

    /// The single dev tools panel for the whole window. Rendered once below
    /// whichever content is showing (split or single pane), bound to the
    /// FOCUSED pane's tab, so opening dev tools in split view never renders
    /// a second copy under the other pane and never shows the wrong tab's data.
    @ViewBuilder
    private var devToolsPanelOverlay: some View {
        if viewModel.showDevToolsPanel && !viewModel.isVideoFullscreen,
           let focusedTabID = viewModel.tabManager.focusedTab?.id {
            // Unconditional on purpose: this sits at the BOTTOM of the window
            // between page content and the dev tools panel. No themed backdrop
            // reaches down here, so there is nothing to overdraw — themed or
            // not, the panel needs its top edge.
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
            DevToolsPanelView(
                focusedTabID: focusedTabID,
                onEvaluateJS: { js, cb in viewModel.evaluateJSForDevTools(js, completion: cb) },
                onHighlightElement: { sel in viewModel.highlightElementInDevTools(selector: sel) },
                onApplyHTML: { sel, b64, cb in viewModel.applyHTMLInDevTools(selector: sel, base64HTML: b64, completion: cb) },
                onDismiss: { viewModel.showDevToolsPanel = false }
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var sidebarView: some View {
        switch viewModel.sidebarContent {
        case .history:
            HistoryView(
                repository: viewModel.historyRepository,
                onItemClick: { viewModel.openHistoryItem($0) },
                onOpenInNewTab: { viewModel.openHistoryItemInNewTab($0) },
                presentation: .sidebar,
                onClose: { viewModel.closeSidebar() }
            )
            .frame(minWidth: 300, maxWidth: 300)
        case .bookmarks:
            BookmarksSidebarView(
                repository: viewModel.bookmarkRepository,
                onBookmarkClick: { viewModel.openBookmark($0) },
                onOpenInNewTab: { viewModel.openBookmarkInNewTab($0) },
                presentation: .sidebar,
                onClose: { viewModel.closeSidebar() },
                isPrivateMode: viewModel.isPrivateMode
            )
            .frame(minWidth: 300, maxWidth: 300)
        case .downloads:
            DownloadsSidebarView(
                repository: viewModel.downloadRepository,
                downloadManager: viewModel.downloadManager,
                presentation: .sidebar,
                onClose: { viewModel.closeSidebar() },
                isPrivateMode: viewModel.isPrivateMode
            )
            .frame(minWidth: 300, maxWidth: 300)
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private var tabSearchOverlay: some View {
        if viewModel.showTabSearch {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture {
                    viewModel.showTabSearch = false
                }

            VStack {
                TabSearchView(
                    tabManager: viewModel.tabManager,
                    isPresented: $viewModel.showTabSearch
                )
                .padding(.top, 60)

                Spacer()
            }
        }
    }

    @ViewBuilder
    private var downloadToastOverlay: some View {
        if viewModel.showDownloadToast, let downloadID = viewModel.toastDownloadID {
            DownloadToastView(
                downloadManager: viewModel.downloadManager,
                downloadRepository: viewModel.downloadRepository,
                downloadID: downloadID,
                isCompleted: viewModel.toastIsCompleted,
                onShowAll: { viewModel.showDownloadsFromToast() },
                onDismiss: { viewModel.dismissDownloadToast() }
            )
            .transition(.move(edge: .trailing).combined(with: .opacity))
            .padding(.top, 50)
            .zIndex(999)
        }
    }

    @ViewBuilder
    private var savePasswordOverlay: some View {
        if viewModel.passwordManager.showSavePrompt {
            SavePasswordBanner(
                domain: viewModel.passwordManager.pendingSaveDomain,
                username: viewModel.passwordManager.pendingSaveUsername ?? "",
                onSave: { viewModel.passwordManager.savePromptAccepted() },
                onDismiss: { viewModel.passwordManager.savePromptDismissed() }
            )
            .transition(.move(edge: .top).combined(with: .opacity))
            .padding(.top, viewModel.showBookmarkBar ? 88 : 52)
            .zIndex(998)
        }
    }

    @ViewBuilder
    private var findInPageOverlay: some View {
        if viewModel.showFindInPage {
            FindInPageBar(
                query: $viewModel.findQuery,
                currentMatch: viewModel.findCurrentMatch,
                totalMatches: viewModel.findTotalMatches,
                onNext: { viewModel.findNext() },
                onPrevious: { viewModel.findPrevious() },
                onDismiss: {
                    viewModel.showFindInPage = false
                    viewModel.dismissFind()
                }
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .zIndex(997)
        }
    }

    @ViewBuilder
    private var readerModeOverlay: some View {
        if viewModel.showReaderMode, let content = viewModel.readerContent {
            ReaderModeView(
                content: content,
                onDismiss: { viewModel.toggleReaderMode() },
                // A link followed from the reader leaves reader mode and opens
                // as a normal tab, where the omnibox, history and per-site
                // rules all apply. The reader's own web view never navigates.
                onOpenLink: { url in
                    viewModel.toggleReaderMode()
                    viewModel.newTab(url: url)
                }
            )
            .transition(.opacity)
            .zIndex(996)
        }
    }

    @ViewBuilder
    private var qrCodeOverlay: some View {
        if viewModel.showQRCode, let tab = viewModel.tabManager.focusedTab, let url = tab.url {
            QRCodePopup(
                url: url,
                pageTitle: tab.title,
                onDismiss: { viewModel.showQRCode = false }
            )
            .transition(.opacity)
            .zIndex(1000)
        }
    }

    @ViewBuilder
    private var commandPaletteOverlay: some View {
        if viewModel.showCommandPalette {
            CommandPaletteView(viewModel: viewModel)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                .zIndex(1001)
        }
    }

    @ViewBuilder
    private var viewSourceOverlay: some View {
        if viewModel.showViewSource {
            ViewSourcePanel(
                html: viewModel.viewSourceHTML,
                pageTitle: viewModel.currentTab?.title ?? "Page Source",
                onDismiss: { viewModel.showViewSource = false }
            )
            .transition(.move(edge: .trailing).combined(with: .opacity))
            .zIndex(995)
        }
    }

    @ViewBuilder
    private var askThisPageOverlay: some View {
        if viewModel.showAskThisPage {
            AskThisPagePanel(
                pageTitle: viewModel.askThisPageTitle,
                pageText: viewModel.askThisPageText,
                tabManager: viewModel.tabManager,
                seedDraft: viewModel.askThisPageSeed,
                onDismiss: { viewModel.showAskThisPage = false }
            )
            .transition(.move(edge: .trailing).combined(with: .opacity))
            .zIndex(994)
        }
    }

    @ViewBuilder
    private var focusBlockOverlay: some View {
        if viewModel.showFocusBlock {
            FocusBlockView(
                blockedHost: viewModel.focusBlockedHost,
                onOverride: {
                    FocusModeManager.shared.overrideDomain(viewModel.focusBlockedHost)
                    viewModel.showFocusBlock = false
                    if let url = viewModel.focusBlockedURL {
                        viewModel.navigate(to: url.absoluteString)
                    }
                },
                onDisableFocus: {
                    FocusModeManager.shared.stopFocusMode()
                    viewModel.showFocusBlock = false
                    if let url = viewModel.focusBlockedURL {
                        viewModel.navigate(to: url.absoluteString)
                    }
                },
                onDismiss: {
                    viewModel.showFocusBlock = false
                }
            )
            .transition(.opacity)
            .zIndex(1003)
        }
    }

    @ViewBuilder
    private var screenshotToastOverlay: some View {
        if viewModel.showScreenshotToast {
            HStack(spacing: 8) {
                Image(systemName: viewModel.screenshotToastIcon)
                    .foregroundStyle(viewModel.screenshotToastIconColor)
                Text(viewModel.screenshotToastMessage)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            )
            .padding(.bottom, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .zIndex(997)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "globe")
                .font(.system(size: 64))
                .foregroundStyle(.tertiary)

            Text("No tab selected")
                .font(.title2)
                .foregroundStyle(.secondary)

            Button("New Tab") {
                viewModel.newTab()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Translucent accent-colored bar shown down an edge while a dragged tab
    /// hovers that edge's drop zone, previewing the split that's about to open.
    @ViewBuilder
    private func edgeDropIndicator(isActive: Bool) -> some View {
        if isActive {
            SettingsManager.shared.accentColor
                .opacity(0.35)
                .frame(width: 6)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }

    /// The one shortcut that is deliberately NOT a menu command: Escape is a
    /// dismissal gesture, not an action, so it has no menu representation in
    /// any browser and nothing to be ambiguous with. Everything else lives in
    /// the menu bar (see `BrowserCommand`); this is the whole remainder of what
    /// used to be a ~30-button invisible shortcut layer.
    @ViewBuilder
    private var escapeShortcut: some View {
        Button("") {
            if viewModel.showCommandPalette {
                viewModel.showCommandPalette = false
            } else if viewModel.showViewSource {
                viewModel.showViewSource = false
            } else if viewModel.showAskThisPage {
                viewModel.showAskThisPage = false
            } else if viewModel.showDevToolsPanel {
                viewModel.showDevToolsPanel = false
            } else if viewModel.showFindInPage {
                viewModel.showFindInPage = false
                viewModel.dismissFind()
            }
        }
        .keyboardShortcut(.escape, modifiers: [])
        // Hidden from assistive tech on purpose: it's a key handler, not a
        // control, and each panel Escape closes has its own visible close
        // button that VoiceOver can reach.
        .accessibilityHidden(true)
        .frame(width: 0, height: 0)
        .opacity(0)
    }
}

// Separate view to properly observe tab changes with @Bindable
struct BrowserContentView: View {
    @Bindable var viewModel: BrowserViewModel
    @Bindable var tab: Tab
    /// Whether this pane is the one keyboard shortcuts / toolbar clicks act on.
    /// Always `true` outside split view.
    var isFocused: Bool = true
    /// Whether this instance is rendered inside the split-view `HSplitView`.
    /// Gates the focus border/dim decoration so the single-pane path is
    /// visually unchanged when split is off.
    var isSplitPane: Bool = false
    /// Called when the user clicks this pane's chrome (nav bar) to focus it.
    /// `nil` outside split view, where there's nothing to switch focus to.
    var onFocusPane: (() -> Void)? = nil
    let onNavigate: (String) -> Void
    let onBack: () -> Void
    let onForward: () -> Void
    let onReload: () -> Void
    let onStop: () -> Void
    let onHome: () -> Void
    let onBookmark: () -> Void
    let onToggleHistory: () -> Void
    let onToggleBookmarks: () -> Void
    let onDownloads: () -> Void
    let onSettings: () -> Void
    let onToggleAdBlock: () -> Void
    var onTogglePrivateMode: (() -> Void)? = nil
    var onAutoFill: (() -> Void)? = nil
    var onGeneratePassword: (() -> Void)? = nil
    var onPrint: (() -> Void)? = nil
    var onToggleReaderMode: (() -> Void)? = nil
    var onPictureInPicture: (() -> Void)? = nil
    var onScreenshot: (() -> Void)? = nil
    var onQRCode: (() -> Void)? = nil
    var onSavePDF: (() -> Void)? = nil
    var onToggleFocusMode: (() -> Void)? = nil
    var onAskThisPage: (() -> Void)? = nil

    // Track URL changes to force WebViewWrapper updates
    @State private var urlVersion: Int = 0

    /// Bumped when the window-wide "Focus Address Bar" (⌘L) command fires AND
    /// this pane is the focused one, so only one omnibox takes focus in split
    /// view. Forwarding the view model's counter directly would also fire on
    /// the *unfocused* pane whenever split focus changed.
    @State private var omniboxFocusTrigger: Int = 0

    /// Computed from THIS pane's tab, not `viewModel.currentTab` — so the
    /// bookmark star reflects the right tab even for the unfocused split pane.
    private var isBookmarked: Bool {
        guard let url = tab.url else { return false }
        return viewModel.bookmarkRepository.isBookmarked(url: url)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !viewModel.isVideoFullscreen {
                NavigationBarView(
                    tab: tab,
                    isBookmarked: isBookmarked,
                    onNavigate: onNavigate,
                    onBack: onBack,
                    onForward: onForward,
                    onReload: onReload,
                    onStop: onStop,
                    onHome: onHome,
                    onBookmark: onBookmark,
                    onToggleHistory: onToggleHistory,
                    onToggleBookmarks: onToggleBookmarks,
                    onDownloads: onDownloads,
                    onSettings: onSettings,
                    onToggleAdBlock: onToggleAdBlock,
                    onAutoFill: onAutoFill,
                    loginFormDetected: viewModel.passwordManager.loginFormDetected,
                    isPrivateMode: viewModel.isPrivateMode,
                    onTogglePrivateMode: onTogglePrivateMode,
                    showWindowDragArea: viewModel.useVerticalTabs && !viewModel.isFullScreen,
                    onPrint: onPrint,
                    onToggleReaderMode: onToggleReaderMode,
                    showReaderMode: viewModel.showReaderMode,
                    onAskThisPage: onAskThisPage,
                    onPictureInPicture: onPictureInPicture,
                    onScreenshot: onScreenshot,
                    onQRCode: onQRCode,
                    isViewingPDF: viewModel.isViewingPDF,
                    onSavePDF: onSavePDF,
                    onToggleFocusMode: onToggleFocusMode,
                    showExtensionButtons: isFocused,
                    isVerticalTabBarCollapsed: viewModel.verticalTabBarCollapsed,
                    focusAddressBarTrigger: omniboxFocusTrigger
                )
                .overlay(alignment: .topTrailing) {
                    if viewModel.showAutoFillPopup {
                        PasswordAutoFillPopup(
                            credentials: viewModel.passwordManager.matchingCredentials,
                            onSelect: { credential in
                                viewModel.fillCredential(credential)
                            },
                            onGenerate: {
                                onGeneratePassword?()
                            },
                            onDismiss: {
                                viewModel.showAutoFillPopup = false
                            }
                        )
                        .padding(.trailing, 80)
                        .offset(y: 36)
                        .zIndex(100)
                    }
                }
                .overlay(alignment: .top) {
                    if isSplitPane && isFocused {
                        Rectangle()
                            .fill(SettingsManager.shared.accentColor)
                            .frame(height: 2)
                    }
                }
                .opacity(isSplitPane && !isFocused ? 0.6 : 1.0)
                .simultaneousGesture(
                    TapGesture().onEnded { onFocusPane?() }
                )
                .zIndex(ChromeLayer.navigationBar)
            }

            // Bookmark bar. Same z-order as the strip and the navigation bar,
            // and for the same reason — it went with the strip in fullscreen.
            if viewModel.showBookmarkBar && !viewModel.isVideoFullscreen {
                BookmarkBarView(
                    repository: viewModel.bookmarkRepository,
                    onBookmarkClick: { viewModel.openBookmark($0) },
                    onOpenInNewTab: { viewModel.openBookmarkInNewTab($0) },
                    isPrivateMode: viewModel.isPrivateMode
                )
                .zIndex(ChromeLayer.bookmarkBar)
            }

            // Loading progress bar. Suppressed while an internal cherry://
            // page is shown — the still-live covered site's load progress
            // must not animate over cherry://settings.
            if tab.isLoading && tab.internalPage == nil && !tab.showHomePage && !viewModel.isVideoFullscreen {
                ProgressBarView(progress: tab.loadingProgress)
            } else if !viewModel.isVideoFullscreen {
                // Unconditional on purpose: this is the chrome↔page boundary,
                // the last row below the nav/bookmark bars, standing in for the
                // progress bar. Chrome needs separating from page content
                // whatever the chrome looks like — Firefox keeps its toolbox
                // bottom border under a theme for the same reason.
                //
                // Not free, though: under a TILING theme (`repeat`/`repeat-y`)
                // the header art does reach the bottom of the bookmark bar, and
                // this row is then a gap in it rather than a border at its edge.
                // That is a known, accepted cost of keeping the boundary, not a
                // case that doesn't arise.
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 0.5)
            }

            // Content - show internal cherry:// page, settings, homepage, or web view.
            // While an internal page is active the WKWebView is not rendered,
            // but the Tab keeps it alive (same as showSettingsPage always did)
            // so Back re-adopts it with history/scroll/form state intact.
            if let page = tab.internalPage {
                CherryPageView(page: page, viewModel: viewModel, tab: tab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tab.showSettingsPage {
                SettingsPageView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tab.showHomePage {
                HomePageView(
                    repository: viewModel.shortcutRepository,
                    isPrivateMode: viewModel.isPrivateMode,
                    onShortcutClick: { url in
                        onNavigate(url.absoluteString)
                    },
                    onSearch: { query in
                        onNavigate(query)
                    },
                    onAskAI: { query in
                        // Focus follows the ask only when the ask took: a
                        // press that did nothing must not steal pane focus
                        // either.
                        let taken = viewModel.askCherryAI(seed: query)
                        if taken { onFocusPane?() }
                        return taken
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Web content - use urlVersion to force updates when URL changes
                WebViewWrapper(
                    tab: tab,
                    urlVersion: urlVersion,
                    onNewTab: { url in
                        viewModel.newTab(url: url)
                    },
                    // Weak: the wrapper's coordinator stores this closure, and
                    // the webview's userContentController retains the
                    // coordinator — a strong viewModel capture here would
                    // rebuild the window-wide retain cycle Coordinator's weak
                    // references exist to break.
                    onNewTabWithWebView: { [weak viewModel] webView, url in
                        viewModel?.newTabWithWebView(webView, url: url)
                    },
                    viewModel: viewModel,
                    onFocused: onFocusPane
                )
                    .id(tab.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Drawn OVER the web view rather than instead of it. The
                    // web view keeps its back/forward list, the tab keeps the
                    // address that failed, and neither the failed page nor the
                    // one still loaded underneath can reach any of this.
                    .overlay { failureOverlay }
                    // Pearl, if she has been switched on. She is over the WEB
                    // VIEW specifically — not over the homepage, not over a
                    // `cherry://` page, not over the reader — because she
                    // stands on the pages you browse, and Cherry's own
                    // surfaces are Cherry talking. She is also below the
                    // failure surface in the modifier order above, so an
                    // offline page is never a cat standing on an apology.
                    //
                    // Everything about whether she is here at all is in
                    // `PearlPetPresence`; nothing about it is in this file.
                    .overlay { pearlPetOverlay }
            }
        }
        // Video fullscreen hides the whole navigation bar, and with it the MCP
        // connection indicator — so an external client could read the user's
        // tabs and history while they watched a video with no way to be told.
        // A security indicator that a display mode can switch off is not an
        // indicator, so it is re-hosted here for exactly that mode. It still
        // draws nothing unless a client is actually connected.
        .overlay(alignment: .topTrailing) {
            if viewModel.isVideoFullscreen {
                MCPConnectionIndicator { onSettings() }
                    .padding(12)
            }
        }
        .onChange(of: tab.url) { _, _ in
            urlVersion += 1
        }
        .onChange(of: viewModel.focusAddressBarTrigger) { _, _ in
            guard isFocused else { return }
            omniboxFocusTrigger += 1
        }
    }

    /// Pearl, standing on this pane's page — or nothing at all, which is what
    /// she is by default.
    ///
    /// The two conditions that are THIS view's to know are passed in: whether
    /// this pane is the focused one (only one Pearl per window, in the pane
    /// you are working in), and whether a bottom-anchored surface is up. The
    /// find bar and the status toast are drawn at the bottom of the window,
    /// exactly where she stands, and they are the ones the user asked for —
    /// so she is the one that leaves.
    @ViewBuilder
    private var pearlPetOverlay: some View {
        PearlPetOverlay(
            host: viewModel,
            showsWebContent: tab.internalPage == nil
                && !tab.showSettingsPage
                && !tab.showHomePage
                && !tab.isShowingFailure
                && !viewModel.showReaderMode,
            isFocusedPane: isFocused,
            isPrivate: viewModel.isPrivateMode,
            bottomSurfaceVisible: viewModel.showFindInPage
                || viewModel.showScreenshotToast
                || viewModel.isVideoFullscreen
        )
    }

    /// The certificate interstitial, or the error surface, or nothing.
    ///
    /// The certificate warning wins when both are set, which can happen for one
    /// frame: refusing the connection makes WebKit report a TLS failure, and
    /// "this certificate expired on 12 April 2015" is strictly more useful than
    /// "the secure connection failed".
    @ViewBuilder
    private var failureOverlay: some View {
        if let warning = tab.certificateWarning {
            CertificateWarningView(
                warning: warning,
                canGoBack: tab.canGoBack,
                onLeave: { viewModel.leaveCertificateWarning(for: tab) },
                onProceed: { viewModel.proceedPastCertificateWarning(for: tab) }
            )
        } else if let failure = tab.loadFailure {
            NavigationFailureView(
                failure: failure,
                isRetrying: tab.isRetryingFailedLoad,
                canGoBack: tab.canGoBack,
                onRetry: { viewModel.retryFailedLoad(for: tab) },
                onBack: { viewModel.goBack(for: tab) }
            )
        }
    }
}

// MARK: - Content Area Drop Delegate

/// Location-aware drop target for a dragged tab dropped on the single-pane
/// content area. Drops within the left/right ~30% edge zones open split view
/// (see `BrowserViewModel.handleContentAreaDrop(edge:)` for the pane
/// arrangement); everything else — including drops with no location info —
/// keeps the pre-existing "detach to new window" behavior via `edge: nil`.
private struct ContentAreaDropDelegate: DropDelegate {
    let contentWidth: CGFloat
    /// Fraction of the content width, from each side, that counts as an edge zone.
    let edgeZoneFraction: CGFloat = 0.3
    @Binding var hoverEdge: Edge?
    let onDrop: (Edge?) -> Bool

    func dropEntered(info: DropInfo) {
        hoverEdge = edge(for: info.location)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        hoverEdge = edge(for: info.location)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        hoverEdge = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let edge = edge(for: info.location)
        hoverEdge = nil
        return onDrop(edge)
    }

    private func edge(for location: CGPoint) -> Edge? {
        guard contentWidth > 0 else { return nil }
        let fraction = location.x / contentWidth
        if fraction <= edgeZoneFraction { return .leading }
        if fraction >= 1 - edgeZoneFraction { return .trailing }
        return nil
    }
}

// MARK: - Window Registrar

/// Captures the hosting NSWindow and registers it on the BrowserViewModel so
/// cross-window tab transfer can find the right destination window.
private struct WindowRegistrar: NSViewRepresentable {
    let viewModel: BrowserViewModel

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            viewModel.associatedWindow = view.window
            viewModel.tabManager.hostWindow = view.window
            ExtensionManager.shared.windowOpened(viewModel)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if viewModel.associatedWindow == nil {
                viewModel.associatedWindow = nsView.window
            }
            if viewModel.tabManager.hostWindow == nil {
                viewModel.tabManager.hostWindow = nsView.window
            }
            ExtensionManager.shared.windowOpened(viewModel)
        }
    }
}

// MARK: - Progress Bar

struct ProgressBarView: View {
    let progress: Double

    var body: some View {
        Rectangle()
            .fill(SettingsManager.shared.accentColor)
            .frame(height: 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .scaleEffect(x: progress, y: 1, anchor: .leading)
            .animation(.linear(duration: 0.15), value: progress)
    }
}

#Preview {
    BrowserView()
}
