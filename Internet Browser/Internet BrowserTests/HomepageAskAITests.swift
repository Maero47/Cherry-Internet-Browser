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
import WebKit
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

    /// The question the user typed is the thing that must not be destroyed.
    /// The homepage clears its field only when the ask reports that it took
    /// the question somewhere; with the panel already open nothing happens to
    /// it, so the field has to keep it.
    func testAnAskThatDoesNothingSaysSoSoTheFieldCanKeepTheQuestion() {
        let viewModel = homePageViewModel()

        XCTAssertTrue(viewModel.askCherryAI(seed: "first question"))
        XCTAssertFalse(
            viewModel.askCherryAI(seed: "second question"),
            "the panel was already open, so nothing happened to the second question"
        )
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

// MARK: - What the panel grounds on

/// The two halves of "is there something ON SCREEN to ground on", exercised
/// against a real, loaded `WKWebView` because that is where the distinction
/// lives. `Tab.openInternalPage` deliberately KEEPS the web view — a
/// `cherry://` page covers a live site whose back/forward list and scroll
/// position have to survive — so "is there a web view" answers yes on
/// cherry://history and grounds the chat on a page the user is not looking at.
@MainActor
final class AskCherryAIGroundingTests: XCTestCase {

    private static let article = """
    <html><head><title>The covered article</title></head>
    <body><article><p>Sodium metal reacts vigorously with water, producing hydrogen
    gas and sodium hydroxide, and the reaction is exothermic enough to ignite the
    hydrogen it releases.</p></article></body></html>
    """

    /// Polls the main actor until `condition` holds, so an async extraction
    /// is given every chance to land before the assertions run — including in
    /// the test where that extraction is the path that must NOT be taken.
    private func wait(
        upTo timeout: TimeInterval = 15,
        for condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// A tab showing a real, loaded, extractable page. Asserts the page really
    /// is readable, so a later "the panel opened empty" means the guard
    /// declined it rather than the fixture being unreadable.
    private func tabOnALoadedArticle(
        in viewModel: BrowserViewModel
    ) async throws -> Tab {
        let tab = try XCTUnwrap(viewModel.tabManager.focusedTab)
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        tab.webView = webView
        tab.url = URL(string: "https://example.com/sodium")
        tab.showHomePage = false
        webView.loadHTMLString(Self.article, baseURL: URL(string: "https://example.com/sodium"))

        var extracted: ExtractedPageContent?
        await wait { !webView.isLoading }
        await wait {
            let done = extracted != nil
            if !done { Task { extracted = await PageAIService.extractPageText(from: webView) } }
            return done
        }
        let content = try XCTUnwrap(extracted, "the fixture page should be readable, or these tests prove nothing")
        XCTAssertEqual(content.title, "The covered article")
        return tab
    }

    func testAskingOnAnInternalPageDoesNotGroundOnTheCoveredSite() async throws {
        let viewModel = BrowserViewModel()
        let tab = try await tabOnALoadedArticle(in: viewModel)

        // cherry://history now covers it. The web view stays alive by design.
        tab.openInternalPage(.history)
        XCTAssertNotNil(tab.webView, "openInternalPage keeps the web view — that is the trap")

        viewModel.toggleAskThisPage()
        await wait { viewModel.showAskThisPage }

        XCTAssertTrue(viewModel.showAskThisPage, "the panel must still open on an internal page")
        XCTAssertEqual(
            viewModel.askThisPageText, "",
            "the chat must not be grounded on a page the user is not looking at"
        )
        XCTAssertEqual(
            viewModel.askThisPageTitle, "",
            "the tab chip must not be labelled with the covered site"
        )
    }

    /// The other direction, and the reason the guard is three conditions
    /// rather than "never ground on anything": a page that IS on screen must
    /// still be read exactly as it always was.
    func testAskingOnAPageThatIsOnScreenStillGroundsOnIt() async throws {
        let viewModel = BrowserViewModel()
        _ = try await tabOnALoadedArticle(in: viewModel)

        viewModel.toggleAskThisPage()
        await wait { viewModel.showAskThisPage }

        XCTAssertTrue(viewModel.showAskThisPage)
        XCTAssertEqual(viewModel.askThisPageTitle, "The covered article")
        XCTAssertTrue(
            viewModel.askThisPageText.contains("Sodium metal reacts vigorously"),
            "the page on screen must still ground the chat: \(viewModel.askThisPageText)"
        )
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
