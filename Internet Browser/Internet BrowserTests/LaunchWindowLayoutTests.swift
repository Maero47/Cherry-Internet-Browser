//
//  LaunchWindowLayoutTests.swift
//  Internet BrowserTests
//
//  The launch window must end in the same laid-out state as a ⌘N window.
//
//  It used to not: the scene-presented launch window was created, measured and
//  shown around a frame that was still being restored, and views realized
//  against that in-between geometry — focus proxies, platform view hosts, the
//  promoted layers that draw the homepage's glyphs — kept its coordinates
//  permanently, surviving later resizes. Side by side in one app instance, the
//  restored window drew the search field's magnifier on the wallpaper and the
//  Favorites "Add" pill without its plus while a ⌘N window drew both
//  correctly. Every browser window now takes the ⌘N bring-up (final frame
//  first, then configuration, then showing — `openBrowserWindow`), the launch
//  window included.
//
//  The test host IS the real app, launched through its real path, so the
//  window this compares is the real launch window. Geometry only; no pixels.
//
//  TWO launch windows are measured here, because there are two of them in the
//  real world:
//
//  1. `LaunchWindowLayoutTests` — the app's own launch window, as this test
//     host brought it up. That is a RETURNING user's launch: first run is over,
//     no wizard is offered, nothing is presented over the window.
//  2. `LaunchWindowFirstRunLayoutTests` — a FIRST RUN launch window, opened
//     through the same `openBrowserWindow` with the presenter's test-host
//     guard deliberately switched off, so the wizard sheet really is claimed,
//     really is deferred a runloop turn, and really does present. That is the
//     path `setup-wizard` added to the launch sequence, and until now the
//     guard meant these ordering tests never walked it. It is walked below.
//

import AppKit
import SwiftUI
import XCTest
@testable import Cherry

/// How far a view may sit from where the ⌘N window puts it. One source of
/// truth: `HomepageGeometry.readingOrder` groups frames into rows using `y`,
/// so the row rule and the assertion cannot drift apart.
private enum Tolerance {
    static let x: CGFloat = 2
    static let y: CGFloat = 4
    static let width: CGFloat = 2
}

/// Shared by both launch-window tests: reduce a window's homepage to frames,
/// and compare two of them. Extracted rather than duplicated so the first-run
/// window is judged by EXACTLY the comparison the returning-user window is —
/// a second, slightly-different copy of this is how one of the two quietly
/// stops guarding anything.
private enum HomepageGeometry {

    /// Frames of every view inside the homepage's scroll container, grouped by
    /// (container path, view class) and put in reading order, in container
    /// coordinates. `nil` when the window shows no homepage scroll.
    static func groups(in container: NSView) -> [String: [CGRect]]? {
        guard let clip = clipView(in: container) else { return nil }
        var groups: [String: [CGRect]] = [:]
        func walk(_ view: NSView, path: String) {
            for sub in view.subviews {
                let cls = String(describing: type(of: sub))
                let group = "\(path)/\(cls)"
                groups[group, default: []].append(sub.convert(sub.bounds, to: clip))
                walk(sub, path: group)
            }
        }
        walk(clip, path: "")
        for (key, frames) in groups {
            groups[key] = readingOrder(frames)
        }
        return groups
    }

    /// Every way `candidate`'s homepage differs from `golden`'s, empty when
    /// they agree.
    static func differences(candidate: [String: [CGRect]], golden: [String: [CGRect]]) -> [String] {
        var stale: [String] = []
        for (group, goldenFrames) in golden {
            // The shared field editor lives in whichever window is key at the
            // moment — keyboard furniture, not layout.
            if group.contains("_NSKeyboardFocusClipView") { continue }
            let candidateFrames = candidate[group] ?? []
            if candidateFrames.count != goldenFrames.count {
                stale.append("\(group): \(candidateFrames.count) views vs \(goldenFrames.count) in ⌘N")
                continue
            }
            for (l, g) in zip(candidateFrames, goldenFrames) {
                if abs(l.minX - g.minX) > Tolerance.x
                    || abs(l.minY - g.minY) > Tolerance.y
                    || abs(l.width - g.width) > Tolerance.width {
                    stale.append("\(group): candidate=\(l) ⌘N=\(g)")
                }
            }
        }
        return stale.sorted()
    }

    /// Sibling frames in reading order: rows top to bottom, and left to right
    /// inside a row.
    ///
    /// Rows, rather than a plain sort on `(minY, minX)` — that sort is what
    /// made this test intermittent. A Favorites tile the pointer is resting on
    /// carries hover's `scaleEffect(1.025)`, and the platform views inside it
    /// (the ⋯ button's anchor, its accessibility view) are then measured about
    /// 1.3pt higher and 0.7pt wider than their resting frames. Every one of
    /// those deltas is well inside what this test allows — but they are not
    /// inside an EXACT `!=` on `minY`, so the hovered tile sorted ahead of its
    /// own row, `zip` paired it against a different tile, and a window that was
    /// laid out perfectly reported 129pt differences. The pointer is not part
    /// of what this test guards, and neither is a comparison whose pairing
    /// turns over on a third of a point.
    ///
    /// So: frames closer together in `y` than the tolerance the assertion
    /// itself applies are not separable into different rows, and are ordered by
    /// `x` instead. The homepage's real rows are 117pt apart (7pt at the very
    /// closest, between a tile and its own ⋯), so the row a frame lands in
    /// never depends on jitter this small. Nothing here is a tolerance: two
    /// views still have to be within `Tolerance` of each other to pass.
    static func readingOrder(_ frames: [CGRect]) -> [CGRect] {
        var rows: [[CGRect]] = []
        for frame in frames.sorted(by: { $0.minY < $1.minY }) {
            if let previous = rows.last?.last, frame.minY - previous.minY < Tolerance.y {
                rows[rows.count - 1].append(frame)
            } else {
                rows.append([frame])
            }
        }
        return rows.flatMap { row in
            row.sorted { a, b in
                a.minX != b.minX ? a.minX < b.minX : a.width < b.width
            }
        }
    }

    /// The homepage's scroll clip view: the one whose content hosts the search
    /// field's platform text field.
    static func clipView(in container: NSView) -> NSView? {
        var found: NSView?
        func walk(_ view: NSView) {
            if found != nil { return }
            if String(describing: type(of: view)) == "NSClipView",
               containsTextField(view) {
                found = view
                return
            }
            for sub in view.subviews { walk(sub) }
        }
        func containsTextField(_ view: NSView) -> Bool {
            if view is NSTextField { return true }
            return view.subviews.contains { containsTextField($0) }
        }
        walk(container)
        return found
    }

    /// A window built by hand through the ⌘N ordering — frame final before it
    /// is ever shown — at `frame`. The golden the launch window is judged
    /// against; built in the test rather than by a helper in the app so the
    /// ordering under test is explicit here.
    @MainActor
    static func makeGoldenWindow(at frame: NSRect) -> DetachedWindow {
        let golden = DetachedWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        golden.isReleasedWhenClosed = false
        golden.contentView = cherryHostingView(BrowserView(isPrivate: false))
        configureBrowserWindow(golden)
        golden.makeKeyAndOrderFront(nil)
        return golden
    }
}

@MainActor
private func pump(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

// MARK: - The returning user's launch window

@MainActor
final class LaunchWindowLayoutTests: XCTestCase {

    func testLaunchWindowHomepageMatchesACommandNWindow() throws {
        pump(1.5)

        // The launch window: the earliest browser window the app brought up.
        let browserWindows = NSApp.windows.filter { window in
            window.contentView != nil && BrowserViewModel.windowViewModels.values
                .contains { $0.associatedWindow === window }
        }
        guard let launchWindow = browserWindows.first,
              let vm = BrowserViewModel.windowViewModels.values
                  .first(where: { $0.associatedWindow === launchWindow }) else {
            return XCTFail("no launch browser window found")
        }

        // A homepage must be showing. If a saved session was restored into
        // this window, open a fresh homepage tab the way ⌘T does. (The
        // historical stranding hit the homepage that lived through the
        // bring-up itself — kept when no session replaces it — so this test
        // is at its sharpest in a run with no saved session.)
        if vm.tabManager.selectedTab?.showHomePage != true {
            vm.newTab()
        }
        pump(1.5)

        let golden = HomepageGeometry.makeGoldenWindow(at: launchWindow.frame)
        defer {
            golden.close()
            pump(0.2)
        }
        pump(2.0)

        let launchHomepage = try XCTUnwrap(
            HomepageGeometry.groups(in: launchWindow.contentView!),
            "launch window shows no homepage to compare"
        )
        let goldenHomepage = try XCTUnwrap(
            HomepageGeometry.groups(in: golden.contentView!),
            "golden window shows no homepage to compare"
        )

        // Same class of views, same frames, ordered by position — sibling
        // enumeration order is not part of the contract, geometry is.
        let stale = HomepageGeometry.differences(candidate: launchHomepage, golden: goldenHomepage)
        XCTAssertTrue(
            stale.isEmpty,
            "launch window's homepage is not laid out like ⌘N's:\n" + stale.joined(separator: "\n")
        )
    }
}

// MARK: - The FIRST RUN launch window

/// The launch window as a brand-new user gets it: the setup wizard claims it,
/// and a sheet comes up over it.
///
/// This class exists because the ordering tests were, until it, blind to
/// exactly the path `setup-wizard` added. `SetupWizardPresenter` refuses to
/// claim inside a test host — it has to, or every geometry test in the suite
/// would be measuring a window with a sheet on it — and the consequence was
/// that the one launch sequence nobody had measured was the one a first-run
/// user actually gets. So the guard is not sidestepped here, it is switched
/// off ON PURPOSE, over a throwaway defaults suite, and the resulting window
/// is put through the SAME comparison `LaunchWindowLayoutTests` uses.
///
/// What is being guarded: the wizard must claim SYNCHRONOUSLY (bookkeeping,
/// during `BrowserView.init`, at the top of `openBrowserWindow`) but present
/// on the NEXT main-queue turn, so the real order stays frame → configure →
/// show → sheet. Presenting inside the bring-up callout is geometry activity
/// on a window that is coming up, which is precisely what stranded the
/// homepage's glyphs in the first place.
@MainActor
final class LaunchWindowFirstRunLayoutTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var savedPresenter: SetupWizardPresenter!

    override func setUp() {
        super.setUp()
        suiteName = "LaunchWindowFirstRun-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        savedPresenter = SetupWizardPresenter.shared
        // Guard off, throwaway store: a real first run, and the developer's
        // own first-run marker is never read or written.
        SetupWizardPresenter.shared = SetupWizardPresenter(defaults: defaults, respectsTestHost: false)
    }

    override func tearDown() {
        SetupWizardPresenter.shared = savedPresenter
        savedPresenter = nil
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    /// The ordering itself, measured on a real window from the real function.
    ///
    /// Dies on: `attachSetupWizardIfEligible` setting `showSetupWizard`
    /// directly instead of hopping to the next main-queue turn (the first
    /// assertion fires while the window is still inside its bring-up
    /// callout); and on the sheet never arriving at all.
    func testFirstRunSheetIsClaimedDuringBringUpAndPresentedAfterIt() throws {
        let frame = NSRect(x: 140, y: 120, width: 1120, height: 780)
        let (window, viewModel) = try openFirstRunWindow(at: frame)
        defer { dismissAndClose(window, viewModel) }

        // Everything below runs in the same callout `openBrowserWindow`
        // returned from: the window is up, and nothing has been presented
        // over it.
        XCTAssertTrue(SetupWizardPresenter.shared.hasClaimedThisSession,
                      "the launch window did not even ask for the wizard")
        XCTAssertTrue(window.isVisible, "frame → configure → show did not complete")
        XCTAssertFalse(viewModel.showSetupWizard,
                       "the sheet was requested during the window's bring-up callout")
        XCTAssertNil(window.attachedSheet,
                     "a sheet was attached before the window finished coming up")

        pump(2.0)

        XCTAssertTrue(viewModel.showSetupWizard, "the deferred first-run sheet never arrived")
        XCTAssertNotNil(window.attachedSheet,
                        "the wizard claimed the window but never presented a sheet over it")
        XCTAssertEqual(window.frame, frame,
                       "the wizard sheet moved or resized the window it presented over")
    }

    /// And the layout underneath it. A first-run launch window, with the
    /// wizard sheet actually up, must lay its homepage out exactly like a ⌘N
    /// window with no sheet at all — the sheet is a separate window AppKit
    /// owns, and it must not have touched the content beneath it.
    ///
    /// Dies on: the sheet being presented inside the bring-up (which strands
    /// the homepage's platform views at the in-between geometry — the
    /// original bug, reached through the wizard this time), or the wizard
    /// being given anything that resizes its host window.
    func testFirstRunWindowWithTheWizardUpIsLaidOutLikeACommandNWindow() throws {
        let frame = NSRect(x: 140, y: 120, width: 1120, height: 780)
        let (window, viewModel) = try openFirstRunWindow(at: frame)
        defer { dismissAndClose(window, viewModel) }

        pump(2.0)
        XCTAssertNotNil(window.attachedSheet, "precondition: the wizard sheet is up over this window")

        if viewModel.tabManager.selectedTab?.showHomePage != true {
            viewModel.newTab()
        }
        pump(1.5)

        let golden = HomepageGeometry.makeGoldenWindow(at: window.frame)
        defer {
            golden.close()
            pump(0.2)
        }
        pump(2.0)

        let firstRunHomepage = try XCTUnwrap(
            HomepageGeometry.groups(in: window.contentView!),
            "first-run window shows no homepage under the sheet"
        )
        let goldenHomepage = try XCTUnwrap(
            HomepageGeometry.groups(in: golden.contentView!),
            "golden window shows no homepage to compare"
        )

        let stale = HomepageGeometry.differences(candidate: firstRunHomepage, golden: goldenHomepage)
        XCTAssertTrue(
            stale.isEmpty,
            "a first-run launch window's homepage is not laid out like ⌘N's:\n" + stale.joined(separator: "\n")
        )
    }

    /// First run cannot resurrect, through this path either: the sheet the
    /// REAL launch window put up, dismissed by any means, ends first run — and
    /// the next launch's presenter refuses the claim.
    ///
    /// Dies on: `showSetupWizard`'s didSet losing its write, or the claim
    /// being made to a store the marker is not written to.
    func testDismissingTheLaunchWindowsWizardEndsFirstRunForGood() throws {
        let (window, viewModel) = try openFirstRunWindow(at: NSRect(x: 160, y: 140, width: 1050, height: 720))
        defer { dismissAndClose(window, viewModel) }
        pump(1.0)
        XCTAssertTrue(viewModel.showSetupWizard, "precondition: the sheet came up")

        viewModel.showSetupWizard = false
        pump(0.5)

        XCTAssertFalse(SetupWizardFirstRun.shouldShow(in: defaults))
        XCTAssertFalse(
            SetupWizardPresenter(defaults: defaults, respectsTestHost: false)
                .claimPresentation(isPrivate: false),
            "a relaunch after finishing offered the wizard again"
        )
    }

    // MARK: - Opening one

    /// Opens a browser window through the app's real `openBrowserWindow` — the
    /// same call `applicationDidFinishLaunching` makes — and returns it with
    /// its view model. Nothing here reaches around the function under test.
    ///
    /// The view model is identified by the registry key that appeared, not by
    /// `associatedWindow`: a view model registers itself in `BrowserView.init`
    /// (synchronously, inside `openBrowserWindow`) but only learns its window
    /// when the view appears, a runloop turn later. Waiting for
    /// `associatedWindow` would mean pumping first — and the whole point of
    /// the ordering assertions is to look BEFORE anything is pumped.
    private func openFirstRunWindow(at frame: NSRect) throws -> (NSWindow, BrowserViewModel) {
        let before = Set(BrowserViewModel.windowViewModels.keys)
        openBrowserWindow(isPrivate: false, frame: frame)
        let window = try XCTUnwrap(BrowserViewModel.detachedWindows.last,
                                   "openBrowserWindow produced no window")
        let newKey = try XCTUnwrap(
            Set(BrowserViewModel.windowViewModels.keys).subtracting(before).first,
            "openBrowserWindow registered no new view model"
        )
        let viewModel = try XCTUnwrap(BrowserViewModel.windowViewModels[newKey])
        return (window, viewModel)
    }

    /// Takes the sheet down BEFORE `tearDown` restores the real presenter, so
    /// the dismissal's `markSeen` lands in this test's throwaway suite and
    /// never on the developer's own first-run marker.
    private func dismissAndClose(_ window: NSWindow, _ viewModel: BrowserViewModel) {
        viewModel.showSetupWizard = false
        pump(0.3)
        window.close()
        pump(0.2)
    }
}
