//
//  FailureContrastTests.swift
//  Internet BrowserTests
//
//  Nothing on a failure screen is decoration. The user is there because
//  something broke, and every word is either the diagnosis, the consequence, or
//  the next step. So all of it clears 4.5:1 against the surface it is actually
//  drawn on, in both appearances, and the measurement is re-run against the
//  shipped colours rather than trusted from a comment.
//

import AppKit
import SwiftUI
import XCTest
@testable import Cherry

final class FailureContrastTests: XCTestCase {

    private let floor = 4.5

    private let appearances: [(String, NSAppearance.Name)] = [
        ("light", .aqua),
        ("dark", .darkAqua),
    ]

    /// `FailurePalette.surface`, which is `LibraryPalette.listSurface`:
    /// #FFFFFF in Aqua, #1E1E1E in Dark Aqua.
    private var surface: NSColor { .controlBackgroundColor }

    // MARK: - What ships

    func testEveryToneOnAFailureScreenClearsTheFloorInBothAppearances() {
        for (label, name) in appearances {
            guard let appearance = NSAppearance(named: name) else {
                XCTFail("no \(label) appearance")
                continue
            }
            appearance.performAsCurrentDrawingAppearance {
                let tones: [(String, NSColor)] = [
                    ("headline (.primary)", .labelColor),
                    ("body", NSColor(FailurePalette.body)),
                    ("caution", NSColor(FailurePalette.caution)),
                ]
                for (role, colour) in tones {
                    let ratio = LibraryPalette.contrastRatio(colour, on: surface)
                    XCTAssertGreaterThanOrEqual(
                        ratio, floor,
                        "\(role) measures \(ratio):1 on the failure surface in \(label) mode"
                    )
                }
            }
        }
    }

    /// The failing address sits in a tinted inset box, not straight on the
    /// surface, so the tone that carries it is measured against the box.
    func testTheAddressClearsTheFloorOnTheInsetItIsDrawnIn() {
        let insets: [(String, NSAppearance.Name, NSColor)] = [
            ("light", .aqua, NSColor.black.withAlphaComponent(0.05)),
            ("dark", .darkAqua, NSColor.white.withAlphaComponent(0.05)),
        ]
        for (label, name, overlay) in insets {
            guard let appearance = NSAppearance(named: name) else {
                XCTFail("no \(label) appearance")
                continue
            }
            appearance.performAsCurrentDrawingAppearance {
                let inset = LibraryPalette.composite(overlay, over: surface)
                let ratio = LibraryPalette.contrastRatio(NSColor(FailurePalette.body), on: inset)
                XCTAssertGreaterThanOrEqual(
                    ratio, floor,
                    "the failing address measures \(ratio):1 on its inset in \(label) mode"
                )
            }
        }
    }

    /// The numbers this feature's header comments quote, so a colour cannot
    /// drift away from the prose that justifies it.
    func testTheQuotedCautionMeasurementsAreTheRealOnes() {
        let expected: [(NSAppearance.Name, Double)] = [(.aqua, 7.02), (.darkAqua, 8.24)]
        for (name, value) in expected {
            guard let appearance = NSAppearance(named: name) else { continue }
            appearance.performAsCurrentDrawingAppearance {
                XCTAssertEqual(
                    LibraryPalette.contrastRatio(NSColor(FailurePalette.caution), on: surface),
                    value, accuracy: 0.05
                )
            }
        }
    }

    // MARK: - Why the warning tone is not a system colour

    /// This project already found `systemRed` at 3.57:1 in light mode. It is
    /// re-measured here because the certificate interstitial is the one screen
    /// where an unreadable warning is a security failure, not a style one.
    func testSystemRedWouldFailTheFloorOnThisSurfaceInLightMode() {
        guard let appearance = NSAppearance(named: .aqua) else {
            return XCTFail("no light appearance")
        }
        appearance.performAsCurrentDrawingAppearance {
            let ratio = LibraryPalette.contrastRatio(.systemRed, on: surface)
            XCTAssertLessThan(ratio, floor, "systemRed now measures \(ratio):1; revisit the tone")
        }
    }

    func testSystemOrangeWouldFailEvenMoreBadly() {
        guard let appearance = NSAppearance(named: .aqua) else {
            return XCTFail("no light appearance")
        }
        appearance.performAsCurrentDrawingAppearance {
            XCTAssertLessThan(LibraryPalette.contrastRatio(.systemOrange, on: surface), 3.0)
        }
    }

    // MARK: - One system, not two

    /// The failure screens borrow the library screens' surface and body tone
    /// rather than inventing their own. If these ever diverge, this feature has
    /// grown a parallel palette and should be looked at.
    func testTheFailureScreensReuseTheLibrarySurfaceAndBodyTone() {
        XCTAssertEqual(NSColor(FailurePalette.surface), NSColor(LibraryPalette.listSurface))
        XCTAssertEqual(NSColor(FailurePalette.body), NSColor(LibraryPalette.supporting))
    }
}
