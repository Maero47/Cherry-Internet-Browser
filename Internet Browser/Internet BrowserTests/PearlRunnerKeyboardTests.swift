//
//  PearlRunnerKeyboardTests.swift
//  Internet BrowserTests
//
//  The half of the space bar the model tests could not see.
//
//  `PearlSpaceToStartTests` drives `spacePressed(offersRunner:
//  runnerHasKeyboardFocus:)` directly and passes `true` for the focus, so it
//  passed for two rounds while the feature did not work: on the real screen
//  nothing ever made that `true`. The press ran off the end of the responder
//  chain and macOS beeped.
//
//  So these tests do not hand the answer in. They put the real section in a
//  real `NSWindow`, click nothing, and send a real `NSEvent` space bar at the
//  window — the window's own first responder decides whether it arrives. That
//  is the level the defect lived at, and the first test here fails on the code
//  as it shipped.
//
//  What this still cannot do is activate the app (the test host has no
//  activation, so no trusted key can be posted and no pointer moved). It does
//  not need to: `NSWindow.sendEvent` walks the same responder chain a real
//  key walks, and the thing under test is who is standing on it.
//

import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Cherry

// MARK: - Harness

@MainActor
private final class KeyboardSpyDriver: PearlFrameDriving {
    private(set) var isRunning = false
    private(set) var tick: (() -> Void)?

    func start(_ tick: @escaping () -> Void) {
        self.tick = tick
        isRunning = true
    }

    func stop() {
        isRunning = false
    }
}

private final class KeyboardTestClock {
    var now: TimeInterval = 0
    func advanceOneFrame() { now += PearlWorld.frameDuration }
}

/// A stand-in for the tab's web view: a plain AppKit view that will hold the
/// keyboard, so a test can prove the runner took it and gave it back.
private final class KeyboardStandIn: NSView {
    override var acceptsFirstResponder: Bool { true }
}

private struct KeyboardStandInHost: NSViewRepresentable {
    let made: (KeyboardStandIn) -> Void
    func makeNSView(context: Context) -> KeyboardStandIn {
        let view = KeyboardStandIn()
        made(view)
        return view
    }
    func updateNSView(_ nsView: KeyboardStandIn, context: Context) {}
}

/// Whether the failure screen is up, so a test can put it up and take it away
/// again. Starts down: the page holds the keyboard first, the way it does when
/// the user has clicked into it and only then navigated somewhere offline.
private final class ScreenPresence: ObservableObject {
    @Published var isUp = false
}

@MainActor
class PearlRunnerKeyboardTestCase: XCTestCase {

    /// Windows are kept alive for the length of the test: a window that is
    /// released mid-run takes its responders with it and every assertion after
    /// that is about nothing.
    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows = []
        super.tearDown()
    }

    /// A real window, showing `view`, laid out. Not key and not active — the
    /// test host cannot activate the app — which is exactly the state the
    /// diagnosis was made in.
    func show(_ view: some View, size: CGSize = CGSize(width: 900, height: 600)) -> NSWindow {
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        settle()
        return window
    }

    func keep(_ window: NSWindow) {
        windows.append(window)
    }

    /// Let SwiftUI realize the tree and run its appearance handlers. `onAppear`
    /// is not synchronous with `layoutSubtreeIfNeeded`, so a test that asks
    /// immediately asks too early.
    func settle(_ seconds: TimeInterval = 0.6) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    /// One space bar, down and up, delivered to the window the way AppKit
    /// delivers one: to whoever the window says holds the keyboard.
    func pressSpace(at window: NSWindow) {
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: " ", charactersIgnoringModifiers: " ",
                isARepeat: false, keyCode: 49
            )
        }
        guard let down = event(.keyDown), let up = event(.keyUp) else {
            return XCTFail("could not build a space bar NSEvent")
        }
        window.sendEvent(down)
        settle(0.3)
        window.sendEvent(up)
        settle(0.3)
    }

    /// Every view in the tree that will accept the keyboard. On the failure
    /// screen there is exactly one — the runner's slot; the Retry button's
    /// proxy does not accept it.
    func focusableViews(in view: NSView) -> [NSView] {
        var found: [NSView] = []
        if view.acceptsFirstResponder { found.append(view) }
        for sub in view.subviews { found += focusableViews(in: sub) }
        return found
    }

    func runnerSlot(in window: NSWindow, file: StaticString = #filePath, line: UInt = #line) -> NSView? {
        let slots = focusableViews(in: window.contentView!)
        XCTAssertEqual(
            slots.count, 1,
            "the failure screen should offer exactly one keyboard slot — the runner's",
            file: file, line: line
        )
        return slots.first
    }
}

// MARK: - The press that never arrived

@MainActor
final class PearlRunnerSpaceReachesTheRunnerTests: PearlRunnerKeyboardTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "PearlRunnerKeyboardTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeController(_ driver: PearlFrameDriving, _ clock: KeyboardTestClock) -> PearlRunnerController {
        PearlRunnerController(
            seed: 42,
            driver: driver,
            clock: { clock.now },
            store: PearlHighScoreStore(defaults: defaults)
        )
    }

    /// Landing on the offline screen and pressing space starts the run. No
    /// click first.
    ///
    /// This is the test the previous two rounds did not have. It dies on:
    /// deleting the idle mark's `onAppear` claim (which is what `defaultFocus`
    /// amounted to — the screen came up with the window itself as first
    /// responder); on `PearlKeyboardClaim.mayClaim` returning false; on the
    /// key handler returning `.ignored` for `.start`; and on `PearlSpaceKey`
    /// answering `.notOurs` for a focused offline screen.
    func testSpaceStartsTheRunOnASurfaceNobodyClicked() {
        let driver = KeyboardSpyDriver()
        let controller = makeController(driver, KeyboardTestClock())
        let window = show(
            FailureColumn {
                PearlRunnerSection(offersRunner: true, controller: controller)
            }
        )

        // Nobody has clicked anything, and the runner already holds the
        // keyboard. Before the fix this was the window itself, which is why
        // the press had nowhere to go.
        let slot = runnerSlot(in: window)
        XCTAssertNotNil(slot)
        XCTAssertTrue(
            window.firstResponder === slot,
            "the offline screen must come up holding the keyboard, not handing it to the window "
                + "(first responder was \(String(describing: window.firstResponder)))"
        )

        XCTAssertFalse(controller.hasStarted)
        pressSpace(at: window)

        XCTAssertTrue(controller.hasStarted, "one space bar, no click, and Pearl is running")
        XCTAssertTrue(driver.isRunning, "and the run is actually ticking")
        XCTAssertFalse(controller.input.jump, "the starting press is not a held jump")
    }

    /// The keyboard stays with the game once the field replaces the mark, so
    /// the next space is the jump rather than a second start. Dies on:
    /// deleting `PearlRunnerSurface`'s `onAppear` focus, and on the surface's
    /// space handler being wired to anything but `spacePressed`.
    func testTheSecondSpaceJumpsTheRunTheFirstOneStarted() {
        let driver = KeyboardSpyDriver()
        let clock = KeyboardTestClock()
        let controller = makeController(driver, clock)
        let window = show(
            FailureColumn {
                PearlRunnerSection(offersRunner: true, controller: controller)
            }
        )

        pressSpace(at: window)
        XCTAssertTrue(controller.hasStarted)

        for _ in 0..<60 {
            clock.advanceOneFrame()
            driver.tick?()
        }
        let frameBefore = controller.game.frame
        let scoreBefore = controller.game.score
        XCTAssertEqual(controller.game.phase, .running)
        XCTAssertFalse(controller.game.isAirborne)

        // The mark is gone and the field is in its place; the keyboard has to
        // have come with it.
        XCTAssertTrue(
            window.firstResponder === runnerSlot(in: window),
            "the field must hold the keyboard the mark held, or the jump is a beep"
        )

        window.sendEvent(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: " ", charactersIgnoringModifiers: " ",
            isARepeat: false, keyCode: 49
        )!)
        settle(0.3)

        XCTAssertTrue(controller.input.jump, "the second space must reach the simulation as a jump")
        XCTAssertEqual(controller.game.frame, frameBefore, "and must not restart the run")
        XCTAssertEqual(controller.game.score, scoreBefore, "or drop the score it had")

        for _ in 0..<10 {
            clock.advanceOneFrame()
            driver.tick?()
        }
        XCTAssertTrue(controller.game.isAirborne, "space on a running game jumps")
    }

    /// An instruction screen has no game to start, so it must never ask for
    /// the keyboard — space there still belongs to the scroll view. Dies on:
    /// `mayClaim` dropping its `offersRunner` guard.
    func testAnInstructionScreenNeverAsksForTheKeyboard() {
        let driver = KeyboardSpyDriver()
        let controller = makeController(driver, KeyboardTestClock())
        let window = show(
            FailureColumn {
                PearlRunnerSection(offersRunner: false, controller: controller)
            }
        )

        let slot = runnerSlot(in: window)
        XCTAssertNotNil(slot)
        XCTAssertFalse(
            window.firstResponder === slot,
            "a screen that offers no runner must not be holding the keyboard"
        )

        pressSpace(at: window)
        XCTAssertFalse(controller.hasStarted, "an instruction screen started a game")
        XCTAssertFalse(driver.isRunning)
    }

    /// A failure that arrives mid-word does not swallow the rest of the word.
    /// Dies on: `mayClaim` dropping its `textIsBeingEdited` guard, and on the
    /// handover reading the wrong window (the app's key window is nil here, so
    /// a claim that consults `NSApp` instead of its own window claims anyway).
    func testTheRunnerNeverTakesTheKeyboardOutOfSomethingBeingTyped() {
        let driver = KeyboardSpyDriver()
        let controller = makeController(driver, KeyboardTestClock())

        let container = NSView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        let field = NSTextField(frame: CGRect(x: 20, y: 560, width: 300, height: 24))
        field.isEditable = true
        field.stringValue = "exam"
        container.addSubview(field)

        let window = NSWindow(
            contentRect: container.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        keep(window)

        XCTAssertTrue(
            window.makeFirstResponder(field),
            "the test needs the address field to hold the keyboard before the failure arrives"
        )
        let typingResponder = window.firstResponder

        // Now the page fails, and the offline screen appears over it.
        let hosting = NSHostingView(
            rootView: AnyView(
                FailureColumn {
                    PearlRunnerSection(offersRunner: true, controller: controller)
                }
            )
        )
        hosting.frame = container.bounds
        container.addSubview(hosting)
        hosting.layoutSubtreeIfNeeded()
        settle()

        XCTAssertTrue(
            window.firstResponder === typingResponder,
            "the runner took the keyboard out of a field that was being typed in "
                + "(first responder is now \(String(describing: window.firstResponder)))"
        )

        pressSpace(at: window)
        XCTAssertFalse(controller.hasStarted, "the runner started on somebody else's key")
    }

    /// What the runner borrowed it gives back: the page that comes back after
    /// Retry can be scrolled without being clicked first. Dies on: deleting
    /// `handover.take()`, deleting the section's `onDisappear` give-back, or
    /// `giveBack()` handing the keyboard to the wrong responder.
    func testTheKeyboardGoesBackToWhoeverHadItWhenTheScreenLeaves() {
        let driver = KeyboardSpyDriver()
        let controller = makeController(driver, KeyboardTestClock())
        let presence = ScreenPresence()
        var page: KeyboardStandIn?

        let window = show(
            PageWithFailure(
                presence: presence,
                controller: controller,
                made: { page = $0 }
            )
        )

        XCTAssertNotNil(page)
        XCTAssertTrue(
            window.makeFirstResponder(page),
            "the test needs the page to hold the keyboard before the runner asks for it"
        )

        // Now the page goes offline and the failure screen appears over it.
        presence.isUp = true
        settle()

        XCTAssertFalse(
            window.firstResponder === page,
            "the runner must take the keyboard off the page it is drawn over"
        )

        // Retry succeeded: the failure screen goes away.
        presence.isUp = false
        settle()

        XCTAssertTrue(
            window.firstResponder === page,
            "the keyboard must go back to the page, not be left with nobody "
                + "(first responder is \(String(describing: window.firstResponder)))"
        )
    }

    /// The section drawn over a page, which can be taken away again.
    private struct PageWithFailure: View {
        @ObservedObject var presence: ScreenPresence
        let controller: PearlRunnerController
        let made: (KeyboardStandIn) -> Void

        var body: some View {
            KeyboardStandInHost(made: made)
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
}

// MARK: - The rule, read straight

final class PearlKeyboardClaimTests: XCTestCase {

    /// Every combination, so no guard can be dropped without something going
    /// red. Dies on: either `guard` in `mayClaim` being removed or inverted.
    func testOnlyAnOfflineScreenWithNobodyTypingMayClaimTheKeyboard() {
        XCTAssertTrue(
            PearlKeyboardClaim.mayClaim(offersRunner: true, textIsBeingEdited: false),
            "the offline screen with an idle keyboard is the one case that may ask"
        )
        XCTAssertFalse(
            PearlKeyboardClaim.mayClaim(offersRunner: false, textIsBeingEdited: false),
            "an instruction screen has no game to start and no business holding the keyboard"
        )
        XCTAssertFalse(
            PearlKeyboardClaim.mayClaim(offersRunner: true, textIsBeingEdited: true),
            "a word being typed outranks the offer of a game"
        )
        XCTAssertFalse(
            PearlKeyboardClaim.mayClaim(offersRunner: false, textIsBeingEdited: true),
            "neither reason alone is enough to claim"
        )
    }
}
