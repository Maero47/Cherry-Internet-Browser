//
//  PearlPetPresenceTests.swift
//  Internet BrowserTests
//
//  Whether there is a cat on this page at all.
//
//  Every clause of `PearlPetPresence.shouldShow` is a promise — off by
//  default, never in incognito, never two of her, never on Cherry's own
//  surfaces, never over the find bar — and each one is tested here by moving
//  exactly that input and nothing else. The last group walks the real pane's
//  view tree, because a policy nothing consults is not a policy.
//

import AppKit
import SwiftUI
import XCTest
@testable import Cherry

/// Every value of type `T` inside a SwiftUI view value, however deep — the
/// codebase's established way of asking what a view is made of.
private func collectValues<T>(_ type: T.Type, in value: Any, depth: Int = 0) -> [T] {
    if let hit = value as? T { return [hit] }
    guard depth < 60 else { return [] }
    return Mirror(reflecting: value).children.flatMap {
        collectValues(type, in: $0.value, depth: depth + 1)
    }
}

@MainActor
final class PearlPetPresenceTests: XCTestCase {

    private let page = CGSize(width: 1200, height: 800)

    /// Every input at the value that says "yes", so each test below can move
    /// one of them and see the answer change.
    private func showing(
        enabled: Bool = true,
        isPrivate: Bool = false,
        isFocusedPane: Bool = true,
        showsWebContent: Bool = true,
        bottomSurfaceVisible: Bool = false,
        contentSize: CGSize? = nil
    ) -> Bool {
        PearlPetPresence.shouldShow(
            enabled: enabled,
            isPrivate: isPrivate,
            isFocusedPane: isFocusedPane,
            showsWebContent: showsWebContent,
            bottomSurfaceVisible: bottomSurfaceVisible,
            contentSize: contentSize ?? page
        )
    }

    // MARK: - The switch

    /// The default, pinned where it is decided.
    ///
    /// `SettingsManager` has a private `init`, so there is no way to build one
    /// against a fresh `UserDefaults` and read the fallback out of it — and
    /// asserting on `.shared` proves only what this machine's preferences
    /// happen to say. So this reads the line itself, through `AppSourceTree`
    /// (which skips rather than hanging if the checkout is in a folder macOS
    /// gates). Dies on somebody changing the fallback to `true`, which is the
    /// entire risk this test exists for.
    func testSheIsOffOnAFreshInstall() throws {
        let source = try AppSourceTree.read("Features/Settings/ViewModels/SettingsManager.swift")
        let line = try XCTUnwrap(
            source.components(separatedBy: .newlines)
                .first { $0.contains("Keys.showPearlPet") && $0.contains("as? Bool") },
            "SettingsManager no longer loads showPearlPet with a default"
        )
        XCTAssertTrue(
            line.contains("?? false"),
            "Pearl's default must be off; found: \(line.trimmingCharacters(in: .whitespaces))"
        )
    }

    /// And the switch persists what it is given, so "off" survives a relaunch.
    func testTheSwitchPersists() {
        let settings = SettingsManager.shared
        let original = settings.showPearlPet
        defer { settings.showPearlPet = original }

        settings.showPearlPet = true
        XCTAssertEqual(UserDefaults.standard.object(forKey: "showPearlPet") as? Bool, true)
        settings.showPearlPet = false
        XCTAssertEqual(UserDefaults.standard.object(forKey: "showPearlPet") as? Bool, false)
    }

    func testTheSwitchIsTheWholeAnswer() {
        XCTAssertTrue(showing(enabled: true))
        XCTAssertFalse(showing(enabled: false))
    }

    /// The switch turns her off with every other condition still saying yes —
    /// i.e. nothing else can keep her alive.
    func testNothingOutranksTheSwitch() {
        for isFocused in [true, false] {
            for showsWeb in [true, false] {
                XCTAssertFalse(
                    showing(enabled: false, isFocusedPane: isFocused, showsWebContent: showsWeb),
                    "she survived the switch being off"
                )
            }
        }
    }

    // MARK: - The absences

    /// Every themed and decorative surface in Cherry refuses private windows;
    /// a pet that watched you browse in incognito would be the loudest
    /// possible exception to that.
    func testNeverInAPrivateWindow() {
        XCTAssertFalse(showing(isPrivate: true))
    }

    /// One Pearl per window. In split view she is in the pane you are working
    /// in, and the other pane has none.
    func testOnlyTheFocusedPaneHasHer() {
        XCTAssertTrue(showing(isFocusedPane: true))
        XCTAssertFalse(showing(isFocusedPane: false))
    }

    /// She stands on the pages you browse, not on Cherry's own surfaces.
    func testNotOnCherrysOwnSurfaces() {
        XCTAssertFalse(showing(showsWebContent: false))
    }

    /// The find bar and the status toast are drawn exactly where she stands,
    /// and they were asked for. She is the one that leaves.
    func testSheYieldsToABottomAnchoredSurface() {
        XCTAssertFalse(showing(bottomSurfaceVisible: true))
    }

    /// In a window too small for her she is not a companion, she is the page.
    func testNotInAWindowTooSmallForHer() {
        XCTAssertFalse(showing(contentSize: CGSize(width: 300, height: 800)))
        XCTAssertFalse(showing(contentSize: CGSize(width: 1200, height: 200)))
        XCTAssertFalse(showing(contentSize: .zero))
        XCTAssertTrue(showing(contentSize: PearlPetPlacement.minimumContentSize))
    }

    // MARK: - The pane actually asks

    /// The overlay is in the pane's view tree, and it is handed THIS pane's
    /// answers. Dies on the pane being wired to a constant, or to the wrong
    /// pane's focus.
    func testThePaneHandsHerItsOwnConditions() throws {
        let viewModel = BrowserViewModel()
        let tab = try XCTUnwrap(viewModel.tabManager.selectedTab)
        tab.showHomePage = false
        tab.url = URL(string: "https://example.com")

        let pane = BrowserContentView(
            viewModel: viewModel,
            tab: tab,
            isFocused: true,
            onNavigate: { _ in }, onBack: {}, onForward: {}, onReload: {},
            onStop: {}, onHome: {}, onBookmark: {},
            onToggleHistory: {}, onToggleBookmarks: {}, onDownloads: {},
            onSettings: {}, onToggleAdBlock: {}
        )

        let overlays = collectValues(PearlPetOverlay.self, in: pane.body)
        let overlay = try XCTUnwrap(overlays.first, "the pane has no Pearl overlay at all")
        XCTAssertEqual(overlays.count, 1, "one pane, one Pearl")
        XCTAssertTrue(overlay.showsWebContent, "a tab on a website is web content")
        XCTAssertTrue(overlay.isFocusedPane)
        XCTAssertFalse(overlay.isPrivate)
        XCTAssertFalse(overlay.bottomSurfaceVisible)
    }

    /// A private window's pane says so, so the policy can refuse her.
    func testAPrivatePaneSaysItIsPrivate() throws {
        let viewModel = BrowserViewModel()
        viewModel.isPrivateMode = true
        let tab = try XCTUnwrap(viewModel.tabManager.selectedTab)
        tab.showHomePage = false

        let pane = BrowserContentView(
            viewModel: viewModel, tab: tab, isFocused: true,
            onNavigate: { _ in }, onBack: {}, onForward: {}, onReload: {},
            onStop: {}, onHome: {}, onBookmark: {},
            onToggleHistory: {}, onToggleBookmarks: {}, onDownloads: {},
            onSettings: {}, onToggleAdBlock: {}
        )
        let overlay = try XCTUnwrap(collectValues(PearlPetOverlay.self, in: pane.body).first)
        XCTAssertTrue(overlay.isPrivate)
    }

    /// On Cherry's own surfaces she is not merely refused, she is not even
    /// built: the overlay hangs off the WEB VIEW, so a pane showing the
    /// homepage has no Pearl anywhere in it. Belt (this) and braces
    /// (`showsWebContent`, which covers the reader and the failure surface,
    /// both of which ARE drawn over a live web view).
    func testThePaneShowingTheHomepageHasNoPearlAtAll() throws {
        let viewModel = BrowserViewModel()
        let tab = try XCTUnwrap(viewModel.tabManager.selectedTab)
        tab.showHomePage = true

        let pane = BrowserContentView(
            viewModel: viewModel, tab: tab, isFocused: true,
            onNavigate: { _ in }, onBack: {}, onForward: {}, onReload: {},
            onStop: {}, onHome: {}, onBookmark: {},
            onToggleHistory: {}, onToggleBookmarks: {}, onDownloads: {},
            onSettings: {}, onToggleAdBlock: {}
        )
        XCTAssertTrue(
            collectValues(PearlPetOverlay.self, in: pane.body).isEmpty,
            "the homepage pane built a Pearl overlay"
        )
    }

    /// The unfocused pane says so, the reader is not a page she stands on, and
    /// the find bar is reported.
    func testThePaneReportsFocusTheReaderAndTheFindBar() throws {
        let viewModel = BrowserViewModel()
        let tab = try XCTUnwrap(viewModel.tabManager.selectedTab)
        tab.showHomePage = false
        tab.url = URL(string: "https://example.com")

        func overlay(isFocused: Bool = false) throws -> PearlPetOverlay {
            let pane = BrowserContentView(
                viewModel: viewModel, tab: tab, isFocused: isFocused,
                onNavigate: { _ in }, onBack: {}, onForward: {}, onReload: {},
                onStop: {}, onHome: {}, onBookmark: {},
                onToggleHistory: {}, onToggleBookmarks: {}, onDownloads: {},
                onSettings: {}, onToggleAdBlock: {}
            )
            return try XCTUnwrap(collectValues(PearlPetOverlay.self, in: pane.body).first)
        }

        XCTAssertFalse(try overlay().isFocusedPane, "the unfocused pane said it was focused")

        viewModel.showReaderMode = true
        XCTAssertFalse(try overlay().showsWebContent, "the reader is Cherry's own surface")
        viewModel.showReaderMode = false

        viewModel.showFindInPage = true
        XCTAssertTrue(try overlay().bottomSurfaceVisible, "the find bar was not reported")
    }
}
