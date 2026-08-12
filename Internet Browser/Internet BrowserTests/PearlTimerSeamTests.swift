//
//  PearlTimerSeamTests.swift
//  Internet BrowserTests
//
//  Two features that animate, and the promise that only one of them ever is.
//
//  Pearl now moves in two places: the runner on the offline page and the pet
//  on the page you are browsing. Both drive themselves with
//  `PearlFrameTimerDriver` — deliberately the same class, so there is one
//  lifecycle to trust — and both branches proved their own driver dies with
//  their own surface. `PearlRunnerLifecycleTests` does it for the game,
//  `PearlPetLifecycleTests` for the cat.
//
//  Neither could ask the question this file asks, because neither had the
//  other: **switching both features on must not mean two timers running while
//  the user is looking at one thing.** Two 60Hz-and-10Hz timers ticking
//  behind a page nobody is on is not a test failure anywhere — it is a warm
//  laptop.
//
//  The answer turns out not to be arbitration between the two features, which
//  would be a third thing to keep right. It is that their surfaces are
//  mutually exclusive by construction: the runner exists only on the failure
//  surface, and the failure surface is one of the things that tells Pearl
//  there is no web content to stand on. So the tests below check exactly that
//  — first at the pane, which is where the exclusion is wired, and then at the
//  drivers, which is where it is paid.
//

import AppKit
import SwiftUI
import XCTest
@testable import Cherry

private func collectValues<T>(_ type: T.Type, in value: Any, depth: Int = 0) -> [T] {
    if let hit = value as? T { return [hit] }
    guard depth < 60 else { return [] }
    return Mirror(reflecting: value).children.flatMap {
        collectValues(type, in: $0.value, depth: depth + 1)
    }
}

@MainActor
final class PearlTimerSeamTests: XCTestCase {

    // MARK: - The pane keeps them apart

    private func pane(_ viewModel: BrowserViewModel, _ tab: Cherry.Tab) -> BrowserContentView {
        BrowserContentView(
            viewModel: viewModel, tab: tab, isFocused: true,
            onNavigate: { _ in }, onBack: {}, onForward: {}, onReload: {},
            onStop: {}, onHome: {}, onBookmark: {},
            onToggleHistory: {}, onToggleBookmarks: {}, onDownloads: {},
            onSettings: {}, onToggleAdBlock: {}
        )
    }

    private func browsingTab() throws -> (BrowserViewModel, Cherry.Tab) {
        let viewModel = BrowserViewModel()
        let tab = try XCTUnwrap(viewModel.tabManager.selectedTab)
        tab.showHomePage = false
        tab.url = URL(string: "https://example.com")
        return (viewModel, tab)
    }

    private func offlineFailure() -> NavigationFailure {
        NavigationFailure(
            family: .offline,
            url: URL(string: "https://example.invalid/"),
            systemDescription: "system sentence",
            domain: NSURLErrorDomain,
            code: NSURLErrorNotConnectedToInternet
        )
    }

    /// The connection drops, the runner's surface goes up, and the same pane
    /// stops telling Pearl there is a page to stand on. She is not hidden —
    /// `PearlPetPresence` refuses her, the overlay builds no view, and there
    /// is no second driver to run.
    ///
    /// Dies on: `!tab.isShowingFailure` being dropped from the pane's
    /// `showsWebContent`. Every pet test and every runner test stays green
    /// through that edit; this is the one that does not.
    func testTheOfflineSurfaceTakesTheWebContentAwayFromPearl() throws {
        let (viewModel, tab) = try browsingTab()

        let before = try XCTUnwrap(
            collectValues(PearlPetOverlay.self, in: pane(viewModel, tab).body).first,
            "precondition: a browsing pane has a Pearl overlay"
        )
        XCTAssertTrue(before.showsWebContent, "precondition: a live page is web content")

        tab.loadFailure = offlineFailure()
        XCTAssertTrue(tab.isShowingFailure, "precondition: the failure surface is up")

        let during = try XCTUnwrap(collectValues(PearlPetOverlay.self, in: pane(viewModel, tab).body).first)
        XCTAssertFalse(
            during.showsWebContent,
            "the pane still calls the offline surface a page for Pearl to stand on"
        )
        XCTAssertFalse(
            PearlPetPresence.shouldShow(
                enabled: true,
                isPrivate: during.isPrivate,
                isFocusedPane: during.isFocusedPane,
                showsWebContent: during.showsWebContent,
                bottomSurfaceVisible: during.bottomSurfaceVisible,
                contentSize: CGSize(width: 1200, height: 800)
            ),
            "she would have been built over the game"
        )
    }

    /// And she comes back when the page does — the exclusion is not a one-way
    /// door that quietly retires the pet after the first failed load.
    func testSheComesBackWhenThePageDoes() throws {
        let (viewModel, tab) = try browsingTab()
        tab.loadFailure = offlineFailure()
        tab.loadFailure = nil

        let overlay = try XCTUnwrap(collectValues(PearlPetOverlay.self, in: pane(viewModel, tab).body).first)
        XCTAssertTrue(overlay.showsWebContent, "the page came back and Pearl did not")
    }

    /// The certificate interstitial is the other thing `isShowingFailure`
    /// covers, and it has no game on it at all — so this is not the runner
    /// pushing her off, it is Cherry's own chrome doing it.
    func testCherrysOwnInterstitialTakesHerAwayToo() throws {
        let (viewModel, tab) = try browsingTab()
        tab.certificateWarning = CertificateWarning(
            host: "example.invalid",
            port: 443,
            url: URL(string: "https://example.invalid/")!,
            problem: .selfSigned,
            certificateCommonName: nil,
            isPrivate: false
        )
        XCTAssertTrue(tab.isShowingFailure)

        let overlay = try XCTUnwrap(collectValues(PearlPetOverlay.self, in: pane(viewModel, tab).body).first)
        XCTAssertFalse(overlay.showsWebContent, "she is standing on a security warning")
    }

    // MARK: - Two features on, one timer

    /// A window with both features switched on, walked through the moment the
    /// page fails: the pet's tick stops on the way out, the runner's has not
    /// started, and the count of running drivers is never two.
    ///
    /// Dies on: the pet's `viewDidMoveToWindow` no longer stopping her driver;
    /// the runner's controller starting a driver before the player asks for a
    /// run.
    func testAcrossTheHandoverAtMostOneDriverIsEverRunning() {
        let petDriver = SilentDriver()
        let pet = PearlPetView(driver: petDriver)
        pet.frame = CGRect(x: 0, y: 0, width: 56, height: 86)
        let runnerDriver = SilentDriver()
        // Its own defaults: this test is about timers, and it has no business
        // writing a high score onto the machine it runs on.
        let suite = "PearlTimerSeamTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let runner = PearlRunnerController(
            seed: 1,
            driver: runnerDriver,
            clock: { 0 },
            store: PearlHighScoreStore(defaults: defaults)
        )

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled], backing: .buffered, defer: true
        )

        func running() -> Int {
            [petDriver.isRunning, runnerDriver.isRunning].filter { $0 }.count
        }

        // Browsing: the cat ticks, the game does not exist yet.
        window.contentView?.addSubview(pet)
        XCTAssertTrue(petDriver.isRunning, "precondition: she ticks on a live page")
        XCTAssertFalse(runnerDriver.isRunning, "the game ticks before anybody asked for it")
        XCTAssertEqual(running(), 1)

        // The load fails. SwiftUI takes the overlay out of the tree; the
        // offline surface appears and offers the game.
        pet.removeFromSuperview()
        XCTAssertEqual(running(), 0, "nothing is on screen to animate and something is animating")

        // The player presses space.
        runner.begin()
        XCTAssertTrue(runnerDriver.isRunning, "precondition: the game runs when asked")
        XCTAssertEqual(running(), 1, "the cat is ticking behind the game")

        // The retry succeeds: the surface goes away, the page comes back.
        runner.shutDown()
        window.contentView?.addSubview(pet)
        XCTAssertEqual(running(), 1, "the game's timer survived the page coming back")
        XCTAssertFalse(runnerDriver.isRunning)
        XCTAssertTrue(petDriver.isRunning)
    }

    /// With the pet switched off, the only thing that can tick is the game —
    /// "off means off" stated as a fact about timers rather than about pixels.
    func testWithThePetOffOnlyTheGameCanEverTick() {
        XCTAssertFalse(
            PearlPetPresence.shouldShow(
                enabled: false, isPrivate: false, isFocusedPane: true,
                showsWebContent: true, bottomSurfaceVisible: false,
                contentSize: CGSize(width: 1200, height: 800)
            ),
            "the switch is off and she is still allowed on the page"
        )

        // And the view that would carry the tick is never built, so there is
        // nothing to stop: a Pearl who has not been put in a window has never
        // started a driver.
        let driver = SilentDriver()
        let pet = PearlPetView(driver: driver)
        pet.frame = CGRect(x: 0, y: 0, width: 56, height: 86)
        XCTAssertEqual(driver.starts, 0)
        XCTAssertFalse(driver.isRunning)
    }

    /// Both drivers are the same class, and it is the one whose lifecycle has
    /// been made trustworthy. A second frame driver appearing beside it is how
    /// one of these two features quietly stops being covered by the other's
    /// lifecycle tests.
    ///
    /// Dies on: a feature growing its own `Timer` for animation instead of
    /// taking `PearlFrameTimerDriver`.
    func testBothFeaturesDriveThemselvesWithTheOneDriver() throws {
        let timers = try AppSourceTree.swiftFiles()
            .filter { $0.path.hasPrefix("Features/Pearl") }
            .flatMap { file in
                file.contents.components(separatedBy: .newlines)
                    .filter { $0.contains("Timer(") || $0.contains("Timer.scheduledTimer") }
                    .map { (file.path, $0.trimmingCharacters(in: .whitespaces)) }
            }

        XCTAssertEqual(
            timers.count, 1,
            "Pearl's features build \(timers.count) timers: "
            + timers.map { "\($0.0): \($0.1)" }.joined(separator: " | ")
        )
        XCTAssertEqual(timers.first?.0, "Features/PearlRunner/Models/PearlRunnerController.swift")
    }

    /// The pet's driver runs at the pet's rate and the runner's at the game's.
    /// Sharing the class must not have quietly given a sitting cat sixty ticks
    /// a second.
    func testTheSharedDriverIsStillGivenTwoDifferentRates() {
        XCTAssertGreaterThan(
            PearlPetMood.tickInterval, PearlWorld.frameDuration,
            "the pet is ticking at the game's frame rate"
        )
    }
}
