//
//  PearlFocusSeamTests.swift
//  Internet BrowserTests
//
//  Two features that both want an input device, and the promise that they want
//  different ones.
//
//  `runner-space-focus` gave the offline screen the keyboard. It is a real
//  take: the section asks for first responder the moment it appears, on a
//  screen nobody has clicked, out of whatever held it — normally the web view
//  the failure surface is drawn over. `pearl-pet-plus` put Pearl on every page
//  the user browses, where she answers mouse events per pixel.
//
//  Each branch proved its own half. Neither could ask the question here:
//  **with both on, does either take something the other needed?**
//
//  ## The answer, and why it is not arbitration
//
//  Nothing arbitrates, because the two devices never cross:
//
//  * **The cat never asks for the keyboard.** `PearlPetView` does not override
//    `acceptsFirstResponder`, so AppKit refuses to make her first responder at
//    all — a click on her does not move focus, and she cannot appear in a
//    window's responder chain. That is not a detail: `PearlKeyboardHandover`
//    remembers whoever held the keyboard when the runner took it and gives it
//    back on the way out, and a cat that could hold it could be handed it back
//    — leaving the page that just returned from Retry deaf, with the keyboard
//    parked on a sprite.
//  * **The runner never asks for the mouse anywhere the cat is.** Its slot
//    exists only inside the failure surface, and that surface is the very
//    thing that takes the web content away from Pearl (`PearlTimerSeamTests`).
//
//  ## And the timer the focus change could have started
//
//  There is one new way to start a clock in the combined tree, and it is worth
//  naming. Focus now arrives on the offline screen without a click, and the
//  section's `onChange(of: isFocused)` calls `controller.resume()` when it
//  does. `resume()` guards on `hasStarted`, so an offer nobody accepted still
//  drives nothing — but before this branch nothing was focused without a click
//  and no test had a reason to check. The last test here is that check.
//

import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Cherry

// MARK: - Harness

/// The tab's web view, in miniature: it takes the keyboard when it is given
/// it, which is what makes "the runner took it from here and put it back"
/// observable.
private final class FocusPageStandIn: NSView {
    override var acceptsFirstResponder: Bool { true }
}

private struct FocusPageHost: NSViewRepresentable {
    let made: (FocusPageStandIn) -> Void
    func makeNSView(context: Context) -> FocusPageStandIn {
        let view = FocusPageStandIn()
        made(view)
        return view
    }
    func updateNSView(_ nsView: FocusPageStandIn, context: Context) {}
}

private final class FailureScreenPresence: ObservableObject {
    @Published var isUp = false
}

/// A page that can go offline and come back, with the failure surface drawn
/// over it exactly as `BrowserContentView` draws it.
private struct PageThatCanFail: View {
    @ObservedObject var presence: FailureScreenPresence
    let controller: PearlRunnerController
    let made: (FocusPageStandIn) -> Void

    var body: some View {
        FocusPageHost(made: made)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if presence.isUp {
                    FailureColumn {
                        PearlRunnerSection(offersRunner: true, controller: controller)
                    }
                }
            }
    }
}

@MainActor
final class PearlFocusSeamTests: PearlRunnerKeyboardTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "PearlFocusSeamTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func controller(_ driver: PearlFrameDriving) -> PearlRunnerController {
        PearlRunnerController(
            seed: 7, driver: driver, clock: { 0 },
            store: PearlHighScoreStore(defaults: defaults)
        )
    }

    /// Pearl, sized and placed the way the overlay places her, in a container
    /// this big.
    private func pearl(in size: CGSize, driver: SilentDriver) -> PearlPetView {
        let view = PearlPetView(driver: driver)
        view.size = .default
        view.contentSize = size
        view.spot = PearlPetSpot(x: 0.5, y: 1)
        let host = PearlPetPlacement.hostFrame(in: size, size: .default, spot: view.spot)
        view.frame = CGRect(
            x: host.minX, y: size.height - host.maxY,
            width: host.width, height: host.height
        )
        return view
    }

    // MARK: - The cat is not a keyboard slot

    /// Nothing in a window ever offers her as a place the keyboard can go: on
    /// a page with Pearl standing on it, the page is the only keyboard slot
    /// there is.
    ///
    /// Stated as "she is not a slot" rather than "AppKit will refuse her",
    /// because AppKit will not refuse her. `NSWindow.makeFirstResponder(_:)`
    /// does not consult `acceptsFirstResponder` at all — that property is what
    /// the KEY LOOP consults, so it governs clicks, Tab, and
    /// `selectNextKeyView`, which is every route focus actually travels. An
    /// explicit `makeFirstResponder(cat)` would succeed, so the guarantee has
    /// to be that nobody makes that call; `testNothingInTheCatEverAsksForTheKeyboard`
    /// is that half.
    ///
    /// Dies on: `override var acceptsFirstResponder: Bool { true }` on
    /// `PearlPetView` — a one-line change somebody would make to give her a
    /// keyboard shortcut, and which puts her in the chain the runner borrows
    /// the keyboard from and hands it back to.
    func testTheCatIsNotAKeyboardSlot() {
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        let page = FocusPageStandIn(frame: container.bounds)
        container.addSubview(page)
        let cat = pearl(in: container.bounds.size, driver: SilentDriver())
        container.addSubview(cat)

        let window = NSWindow(
            contentRect: container.frame, styleMask: [.titled],
            backing: .buffered, defer: false
        )
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        keep(window)

        XCTAssertFalse(cat.acceptsFirstResponder, "Pearl offers herself as a keyboard slot")
        XCTAssertEqual(
            focusableViews(in: container).count, 1,
            "the page and the cat are both keyboard slots; only the page should be"
        )
        XCTAssertTrue(window.makeFirstResponder(page), "precondition: the page can hold the keyboard")

        // The key loop, which is the route a Tab press takes: it walks past
        // her rather than through her.
        window.selectNextKeyView(nil)
        XCTAssertFalse(window.firstResponder === cat, "Tab landed the keyboard on Pearl")
    }

    /// And she never asks for it herself. The rule above is about who AppKit
    /// offers the keyboard to; this is about the one thing that could bypass
    /// that — a view calling `makeFirstResponder` on itself, which is exactly
    /// what a text field does in its own `mouseDown`.
    ///
    /// Dies on: `window?.makeFirstResponder(self)` appearing anywhere in the
    /// pet, which would take the keyboard out of the omnibox on a click meant
    /// only to pet her.
    func testNothingInTheCatEverAsksForTheKeyboard() throws {
        for file in try AppSourceTree.swiftFiles() where file.path.hasPrefix("Features/PearlPet") {
            let code = file.contents
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0).components(separatedBy: "//").first ?? "" }
                .joined(separator: "\n")
            XCTAssertFalse(
                code.contains("makeFirstResponder"),
                "\(file.path) asks for the keyboard; the pet has no business holding it"
            )
            XCTAssertFalse(
                code.contains("acceptsFirstResponder"),
                "\(file.path) answers the key loop's question; the default answer is the right one"
            )
        }
    }

    /// Clicking her pets her and changes nothing about who is typing. This is
    /// the mouse half of the same promise: the gesture that makes her react is
    /// not a gesture that reaches the keyboard.
    ///
    /// Dies on: `mouseDown` calling `window?.makeFirstResponder(self)`, which
    /// is the other one-line way she ends up in the chain — and which would
    /// swallow the rest of a word being typed in the omnibox.
    func testClickingHerLeavesTheKeyboardWhereItWas() throws {
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        let page = FocusPageStandIn(frame: container.bounds)
        container.addSubview(page)
        let cat = pearl(in: container.bounds.size, driver: SilentDriver())
        container.addSubview(cat)

        let window = NSWindow(
            contentRect: container.frame, styleMask: [.titled],
            backing: .buffered, defer: false
        )
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        keep(window)
        XCTAssertTrue(window.makeFirstResponder(page))

        // The middle of her body — a pixel she really drew, so the click is
        // hers rather than the page's.
        let sprite = cat.spriteRect
        let onHer = CGPoint(x: sprite.midX, y: sprite.minY + sprite.height * 0.3)
        XCTAssertTrue(cat.isOnPearl(onHer), "precondition: this point is Pearl")

        func mouse(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: container.convert(onHer, from: cat),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )!
        }
        cat.mouseDown(with: mouse(.leftMouseDown))
        cat.mouseUp(with: mouse(.leftMouseUp))

        XCTAssertEqual(
            cat.currentAppearance?.pose, .delighted,
            "precondition: the click really reached her"
        )
        XCTAssertTrue(
            window.firstResponder === page,
            "petting her moved the keyboard (it is now \(String(describing: window.firstResponder)))"
        )
    }

    // MARK: - The handover, with the cat in the window

    /// The whole round trip with both features on: the page holds the
    /// keyboard, Pearl is standing on it, the load fails, the runner takes the
    /// keyboard, Retry succeeds, and the keyboard goes back to the PAGE.
    ///
    /// `PearlRunnerKeyboardTests` walks this without a cat in the window. The
    /// thing only this tree can ask is whether her being there changes the
    /// answer — she is a sibling view in the same pane, and `giveBack()` hands
    /// the keyboard to a remembered responder.
    ///
    /// The window has a second keyboard slot standing in for Cherry's chrome,
    /// and that is load-bearing rather than scenery. With ONE slot in the
    /// window, AppKit's own key-view recalculation lands the keyboard back on
    /// it when the runner's slot is torn down — so the assertion below passes
    /// whether or not `giveBack()` exists, which is what a first draft of this
    /// test did. With two, the fallback is ambiguous and only the handover
    /// knows which of them was actually typing, which is also the shape of a
    /// real browser window.
    ///
    /// Dies on: `PearlPetView` accepting first responder (she then becomes a
    /// candidate the borrow can land on), deleting the section's `onDisappear`
    /// give-back, and on `giveBack()` losing its "still in this window" check.
    func testTheRunnerBorrowsFromThePageAndGivesItBackToThePage() {
        let driver = KeyboardSeamDriver()
        let presence = FailureScreenPresence()
        var page: FocusPageStandIn?

        // Built by hand rather than through `show`, so the cat is a sibling of
        // the hosted tree the way she is a sibling of the web view in a real
        // pane — rather than a foreign subview inside SwiftUI's own hosting
        // view, which SwiftUI is entitled to rearrange.
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        let chrome = FocusPageStandIn(frame: CGRect(x: 0, y: 560, width: 900, height: 40))
        container.addSubview(chrome)
        let hosting = NSHostingView(
            rootView: AnyView(
                PageThatCanFail(presence: presence, controller: controller(driver), made: { page = $0 })
            )
        )
        hosting.frame = CGRect(x: 0, y: 0, width: 900, height: 560)
        container.addSubview(hosting)
        let cat = pearl(in: container.bounds.size, driver: SilentDriver())
        container.addSubview(cat)

        let window = NSWindow(
            contentRect: container.frame, styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        keep(window)
        hosting.layoutSubtreeIfNeeded()
        settle()

        let thePage = page
        XCTAssertNotNil(thePage)
        XCTAssertTrue(window.makeFirstResponder(thePage), "precondition: the page holds the keyboard")

        // Offline. SwiftUI puts the failure surface up; the pane takes Pearl
        // out of the tree at the same moment, which is what this stands in for.
        presence.isUp = true
        settle()
        cat.removeFromSuperview()

        XCTAssertFalse(window.firstResponder === thePage, "the runner never took the keyboard")
        XCTAssertFalse(window.firstResponder === cat, "the keyboard went to the cat")

        // Retry succeeded.
        presence.isUp = false
        settle()
        container.addSubview(cat)

        XCTAssertTrue(
            window.firstResponder === thePage,
            "the page came back deaf — the keyboard is with "
                + "\(String(describing: window.firstResponder))"
        )
        XCTAssertFalse(cat.acceptsFirstResponder)
    }

    // MARK: - Focus is not a start button

    /// The offline screen takes the keyboard by itself now. Taking it must not
    /// also start the game: the offer is an offer, and a run nobody asked for
    /// is a 60 Hz timer on a screen the user is reading an error on.
    ///
    /// Dies on: `PearlRunnerController.resume()` losing its `guard hasStarted`
    /// — with which the section's own `onChange(of: isFocused)` starts the
    /// driver the instant the claim lands. Every other runner test survives
    /// that edit, because they all click or press space first.
    func testTakingTheKeyboardDoesNotStartTheGame() {
        let driver = KeyboardSeamDriver()
        let runner = controller(driver)
        let window = show(
            FailureColumn { PearlRunnerSection(offersRunner: true, controller: runner) }
        )

        let slot = runnerSlot(in: window)
        XCTAssertTrue(
            window.firstResponder === slot,
            "precondition: the offline screen holds the keyboard without a click"
        )
        XCTAssertFalse(runner.hasStarted, "focus started a run nobody asked for")
        XCTAssertEqual(driver.starts, 0, "focus started the game's timer")
        XCTAssertFalse(driver.isRunning)
    }

    /// The same instant from the cat's side: while the offline screen sits
    /// there holding the keyboard, nothing at all is ticking. The runner has
    /// not been asked to run and Pearl is not in a window to run in.
    ///
    /// Dies on: the same `resume()` edit as above, and on `PearlPetView`
    /// keeping its driver after leaving its window.
    func testNothingTicksWhileTheOfflineScreenJustSitsThere() {
        let runnerDriver = KeyboardSeamDriver()
        let petDriver = SilentDriver()

        let container = NSView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        let hosting = NSHostingView(
            rootView: AnyView(
                FailureColumn {
                    PearlRunnerSection(offersRunner: true, controller: controller(runnerDriver))
                }
            )
        )
        hosting.frame = container.bounds
        container.addSubview(hosting)

        let window = NSWindow(
            contentRect: container.frame, styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        keep(window)
        hosting.layoutSubtreeIfNeeded()
        settle()

        // She was in a window a moment ago, on the page that has just failed.
        let cat = pearl(in: container.bounds.size, driver: petDriver)
        container.addSubview(cat)
        XCTAssertTrue(petDriver.isRunning, "precondition: she ticks while she is on a page")
        cat.removeFromSuperview()

        XCTAssertNotNil(runnerSlot(in: window))
        XCTAssertFalse(petDriver.isRunning, "the cat is ticking with no window to tick in")
        XCTAssertFalse(runnerDriver.isRunning, "the game is ticking with nobody playing")
        XCTAssertEqual(runnerDriver.starts, 0)
    }

    /// And the offer still works: one space bar, no click, starts the run —
    /// so the four tests above are not passing because focus quietly stopped
    /// arriving.
    func testTheSpaceBarStillStartsTheRun() {
        let driver = KeyboardSeamDriver()
        let runner = controller(driver)
        let window = show(
            FailureColumn { PearlRunnerSection(offersRunner: true, controller: runner) }
        )

        pressSpace(at: window)
        XCTAssertTrue(runner.hasStarted, "space no longer starts the run")
        XCTAssertTrue(driver.isRunning, "the run started without a timer")
    }
}

/// A frame driver that counts, for the runner's side of these tests.
@MainActor
private final class KeyboardSeamDriver: PearlFrameDriving {
    private(set) var isRunning = false
    private(set) var starts = 0
    private var tick: (() -> Void)?

    func start(_ tick: @escaping () -> Void) {
        self.tick = tick
        isRunning = true
        starts += 1
    }

    func stop() {
        tick = nil
        isRunning = false
    }
}
