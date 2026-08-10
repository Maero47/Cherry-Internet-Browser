//
//  AppearanceApplicationTests.swift
//  Internet BrowserTests
//
//  Cherry used to have two appearances at once: `.preferredColorScheme` styled
//  the SwiftUI content in the user's choice while `NSApp.effectiveAppearance` —
//  and everything AppKit hangs off it, the contrast guard's `resolve` included —
//  kept following macOS. The guard then measured glyphs and plates in one
//  appearance while the content drew them in the other, and with the system
//  dark and Cherry light it solved for exactly the wrong polarity.
//
//  The fix gives the application ONE appearance: `CherryAppearance.apply` pins
//  `NSApp.appearance` to the chosen mode (or hands it back to macOS for
//  System), every window inherits it, and the guard's read becomes correct by
//  construction. These pin all of that.
//

import AppKit
import SwiftUI
import XCTest
@testable import Cherry

@MainActor
final class AppearanceApplicationTests: XCTestCase {

    private var savedAppAppearance: NSAppearance?
    /// What macOS itself says while nothing overrides it — read with the
    /// override lifted, so the tests never assume which appearance the
    /// machine is set to.
    private var systemAppearanceName: NSAppearance.Name = .aqua

    override func setUp() {
        super.setUp()
        savedAppAppearance = NSApp.appearance
        NSApp.appearance = nil
        systemAppearanceName = NSApp.effectiveAppearance
            .bestMatch(from: [.aqua, .darkAqua]) ?? .aqua
    }

    override func tearDown() {
        NSApp.appearance = savedAppAppearance
        super.tearDown()
    }

    // MARK: - The three modes

    func testLightPinsTheApplicationToAqua() {
        CherryAppearance.apply(.light)
        XCTAssertEqual(NSApp.appearance?.bestMatch(from: [.aqua, .darkAqua]), .aqua)
        XCTAssertEqual(NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .aqua)
    }

    func testDarkPinsTheApplicationToDarkAqua() {
        CherryAppearance.apply(.dark)
        XCTAssertEqual(NSApp.appearance?.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
        XCTAssertEqual(NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
    }

    /// System is expressed as NO override at all — that, and nothing else, is
    /// what lets a change in System Settings reach the running app: with
    /// `NSApp.appearance` nil, AppKit re-derives `effectiveAppearance` from
    /// macOS's own value whenever it changes, exactly as it does for any
    /// un-overridden app. A stored copy of "what the system said at apply time"
    /// would freeze it instead.
    func testSystemHandsTheDecisionBackToMacOS() {
        CherryAppearance.apply(.dark)
        CherryAppearance.apply(.system)
        XCTAssertNil(NSApp.appearance)
        XCTAssertEqual(
            NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]),
            systemAppearanceName,
            "with the override lifted the app must show whatever macOS is set to"
        )
    }

    // MARK: - Windows follow

    /// No Cherry window sets an appearance of its own, so every one of them —
    /// browser windows, the menu panels, sheets, whatever comes later —
    /// inherits the application's. One assignment therefore covers windows
    /// that already exist AND windows not yet born, which is what "existing
    /// windows must follow when the setting changes" means mechanically.
    func testAWindowWithNoAppearanceOfItsOwnFollowsTheSettingLive() {
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 100, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        // `close()` on a titled window releases it by default, which is a
        // crash when Swift still holds the reference.
        window.isReleasedWhenClosed = false
        defer { window.close() }
        XCTAssertNil(window.appearance, "the premise: Cherry windows carry no own appearance")

        // On screen (far offscreen, so nothing flashes) and given a runloop
        // turn: AppKit distributes an application appearance change to its
        // windows during the update cycle, not inside the setter — the same
        // cycle every window gets in the running app.
        window.orderFront(nil)
        CherryAppearance.apply(.light)
        assertWindowSettles(window, on: .aqua)

        CherryAppearance.apply(.dark)
        assertWindowSettles(window, on: .darkAqua)
    }

    // MARK: - The defect itself

    /// The actual bug, pinned without pixels: the appearance the contrast guard
    /// resolves colours in must be the SAME one the content is drawn in. The
    /// content draws in `resolvedColorScheme`; the guard reads
    /// `NSApp.effectiveAppearance`. Whatever this machine's system appearance
    /// is, one of the two modes below disagrees with it — so before the fix,
    /// one of these two passes always failed.
    func testTheGuardMeasuresInTheAppearanceTheContentIsDrawnIn() {
        for mode in [AppearanceMode.light, .dark] {
            CherryAppearance.apply(mode)

            let contentScheme: ColorScheme = mode == .dark ? .dark : .light
            let guardScheme: ColorScheme = NSApp.effectiveAppearance
                .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
            XCTAssertEqual(
                guardScheme, contentScheme,
                "the guard would measure in \(guardScheme) what the content draws in \(contentScheme)"
            )

            // And through the guard's own entry point: a dynamic colour now
            // resolves to the chosen appearance's value, not the system's.
            // The label colour is near-black in Aqua and near-white in Dark
            // Aqua, so its resolved luminance says which appearance answered.
            let label = ThemeContrast.resolve(Color(nsColor: .labelColor))
            let luminance = ThemeContrast.relativeLuminance(label.rgb)
            if mode == .dark {
                XCTAssertGreaterThan(luminance, 0.5, "dark mode must resolve a light label")
            } else {
                XCTAssertLessThan(luminance, 0.5, "light mode must resolve a dark label")
            }
        }
    }

    // MARK: - The setting reaches AppKit

    /// Changing the setting is enough — no window has to be reopened. The
    /// didSet is the one live path; launch goes through `SettingsManager`'s
    /// init the same way `applyCookiePolicy` and `applyAppIcon` do.
    func testChangingTheSettingAppliesTheAppearance() {
        let settings = SettingsManager.shared
        let savedMode = settings.appearanceMode
        defer { settings.appearanceMode = savedMode }

        settings.appearanceMode = .light
        XCTAssertEqual(NSApp.appearance?.bestMatch(from: [.aqua, .darkAqua]), .aqua)

        settings.appearanceMode = .dark
        XCTAssertEqual(NSApp.appearance?.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)

        settings.appearanceMode = .system
        XCTAssertNil(NSApp.appearance)
    }

    // MARK: - Predictability of the chrome

    /// The owner's complaint in one sentence: the same control in the same
    /// appearance with the same theme must come out the same colour every
    /// time. The glyph tone is a function of the theme and the appearance
    /// alone (`toolbarGlyph` takes nothing else), and the plate's COLOUR is
    /// chosen from the glyph alone — the artwork under a control may still
    /// set the plate's opacity, never its polarity. Measured here across
    /// backdrops that differ wildly.
    func testThePlateColourDependsOnTheGlyphAloneAcrossBackdrops() {
        let glyph = ThemeContrast.resolve(ThemeContrast.barGlyphOnDark)
        let backdrops: [[ThemeContrast.RGB]] = [
            Array(repeating: ThemeContrast.RGB(red: 0.95, green: 0.95, blue: 0.9), count: 64),
            Array(repeating: ThemeContrast.RGB(red: 0.9, green: 0.5, blue: 0.1), count: 64),
            (0..<64).map { ThemeContrast.RGB(red: Double($0) / 64, green: 0.5, blue: 0.8) },
        ]
        var colours: Set<Bool> = []
        for pixels in backdrops {
            let sample = ThemeBackdropSample(pixels: pixels, columns: 16, rows: 4, pointWidth: 96)
            guard let plan = ThemeContrast.plate(
                foreground: glyph, sample: sample,
                floor: ThemeContrast.iconFloor, windowPoints: 28
            ) else { continue }
            colours.insert(plan.isDark)
            XCTAssertEqual(plan.isDark, ThemeContrast.scrimIsDark(for: glyph))
        }
        XCTAssertEqual(colours, [true], "a light glyph must always get the dark plate, whatever is behind it")
    }

    /// Waits for AppKit to distribute the application's appearance to `window`,
    /// rather than assuming one runloop turn is enough.
    ///
    /// It is not: the distribution happens during the update cycle, and with a
    /// fixed 0.1s wait this assertion failed while the app itself was already
    /// correct — `NSApp.appearance` had taken the new value and the window had
    /// simply not been told yet. A fixed longer wait would only move the
    /// threshold; polling to a deadline passes as soon as the state is right
    /// and cannot go flaky on a loaded machine.
    private func assertWindowSettles(
        _ window: NSWindow, on expected: NSAppearance.Name,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let deadline = Date(timeIntervalSinceNow: 5)
        while Date() < deadline {
            if window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected { return }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        XCTFail(
            "window never settled on \(expected.rawValue) — "
                + "app.appearance=\(String(describing: NSApp.appearance?.name)) "
                + "app.effective=\(NSApp.effectiveAppearance.name) "
                + "window.appearance=\(String(describing: window.appearance?.name))",
            file: file, line: line
        )
    }

}
