//
//  HomepageAskAITests.swift
//  Internet BrowserTests
//
//  The homepage's way into the AI, and the bug underneath it: asking with no
//  web view to read used to do NOTHING — the toolbar button, the ⋯ entry,
//  ⌘⇧K and the command palette all hit the same `guard let webView … else
//  { return }`. Covered here: that opening now happens (with the empty
//  snapshot the panel reads as general chat), that the homepage's control
//  never closes a panel it was asked to open, and the rule that decides
//  whether what the user typed reaches the panel's composer.
//

import XCTest
@testable import Cherry

// MARK: - Opening where there is no page to read

@MainActor
final class AskCherryAIOpeningTests: XCTestCase {

    /// A fresh view model's default tab IS the home page: no url, no web view.
    private func homePageViewModel() -> BrowserViewModel {
        let viewModel = BrowserViewModel()
        let tab = viewModel.tabManager.focusedTab
        XCTAssertNotNil(tab, "a default view model should have a tab")
        XCTAssertTrue(tab?.showHomePage == true, "the default tab should be showing the home page")
        XCTAssertNil(tab?.webView, "the home page has no web view — the whole point of these tests")
        return viewModel
    }

    /// The regression: this used to return early and leave the user with a
    /// button, a menu item and a shortcut that all did nothing.
    func testAskingWithNoWebViewOpensThePanel() {
        let viewModel = homePageViewModel()

        viewModel.toggleAskThisPage()

        XCTAssertTrue(viewModel.showAskThisPage)
    }

    /// An EMPTY snapshot, not a fallback title: an empty `pageText` is exactly
    /// what `AskThisPagePanel.isGeneralChat` reads as "nothing to ground on",
    /// and an empty title keeps the header off a page that isn't there.
    func testAskingWithNoWebViewOpensOnAnEmptySnapshot() {
        let viewModel = homePageViewModel()
        viewModel.askThisPageTitle = "left over from a previous page"
        viewModel.askThisPageText = "left over body text"

        viewModel.toggleAskThisPage()

        XCTAssertEqual(viewModel.askThisPageTitle, "")
        XCTAssertEqual(viewModel.askThisPageText, "")
    }

    /// The toggle is still a toggle — the new branch is on the OPEN path only.
    func testAskingAgainClosesThePanel() {
        let viewModel = homePageViewModel()

        viewModel.toggleAskThisPage()
        viewModel.toggleAskThisPage()

        XCTAssertFalse(viewModel.showAskThisPage)
    }

    // MARK: The homepage control

    func testTheHomepageControlOpensThePanelCarryingWhatWasTyped() {
        let viewModel = homePageViewModel()

        viewModel.askCherryAI(seed: "how do jet engines work")

        XCTAssertTrue(viewModel.showAskThisPage)
        XCTAssertEqual(viewModel.askThisPageSeed, "how do jet engines work")
    }

    func testTheHomepageControlWithAnEmptyFieldOpensGeneralChat() {
        let viewModel = homePageViewModel()

        viewModel.askCherryAI(seed: "")

        XCTAssertTrue(viewModel.showAskThisPage)
        XCTAssertEqual(viewModel.askThisPageSeed, "")
        XCTAssertEqual(viewModel.askThisPageText, "")
    }

    /// "Take this to the AI" must never be the thing that closes the AI — and
    /// with the panel already up, its live conversation and composer are left
    /// exactly as they are.
    func testTheHomepageControlNeverClosesAnOpenPanel() {
        let viewModel = homePageViewModel()

        viewModel.askCherryAI(seed: "first question")
        viewModel.askCherryAI(seed: "second question")

        XCTAssertTrue(viewModel.showAskThisPage)
        XCTAssertEqual(viewModel.askThisPageSeed, "first question")
    }

    /// A seed belongs to the one opening it was typed for: without this, a
    /// homepage question would reappear in the composer the next time the
    /// panel was opened from a page.
    func testClosingThePanelDropsTheSeed() {
        let viewModel = homePageViewModel()
        viewModel.askCherryAI(seed: "why is the sky blue")

        viewModel.showAskThisPage = false

        XCTAssertEqual(viewModel.askThisPageSeed, "")

        viewModel.toggleAskThisPage()

        XCTAssertTrue(viewModel.showAskThisPage)
        XCTAssertEqual(viewModel.askThisPageSeed, "", "a later opening must start with an empty composer")
    }
}

// MARK: - Seeding the composer

/// `AskPanelDraftSeed.resolve` is the half of the panel's `onAppear` seeding
/// that can be tested: what the composer should hold, given what was handed
/// over and what is already in it.
final class AskPanelDraftSeedTests: XCTestCase {

    func testASeedFillsAnEmptyComposer() {
        XCTAssertEqual(AskPanelDraftSeed.resolve(seed: "explain hashing", draft: ""), "explain hashing")
    }

    func testTheSeedIsTrimmed() {
        XCTAssertEqual(AskPanelDraftSeed.resolve(seed: "  explain hashing\n", draft: ""), "explain hashing")
    }

    /// Every entry point other than the homepage's control seeds "" — the
    /// panel must open with an untouched composer.
    func testAnEmptySeedLeavesTheComposerAlone() {
        XCTAssertNil(AskPanelDraftSeed.resolve(seed: "", draft: ""))
    }

    func testAWhitespaceOnlySeedLeavesTheComposerAlone() {
        XCTAssertNil(AskPanelDraftSeed.resolve(seed: "   \n ", draft: ""))
    }

    /// The clobber guard: whatever the user has typed in the panel outranks
    /// anything a caller wants to seed.
    func testATypedComposerIsNeverOverwritten() {
        XCTAssertNil(AskPanelDraftSeed.resolve(seed: "explain hashing", draft: "what I am actually typing"))
    }

    /// Applied once: the first call fills the composer, and re-offering the
    /// same seed after the user has typed cannot take that typing away. (The
    /// panel also latches `hasSeededDraft`, so the second call never happens —
    /// this pins the rule underneath it as well.)
    func testReofferingASeedCannotUndoLaterTyping() {
        let first = AskPanelDraftSeed.resolve(seed: "explain hashing", draft: "")
        XCTAssertEqual(first, "explain hashing")

        // The user rewrites the composer, then something re-offers the seed.
        let afterTyping = AskPanelDraftSeed.resolve(seed: "explain hashing", draft: "explain hashing for a 5 year old")

        XCTAssertNil(afterTyping)
    }
}
