//
//  LibraryContrastTests.swift
//  Internet BrowserTests
//
//  Every field on a library row is information: the domain a page is on, the
//  time you were there, how big a file is, where it went. None of it is
//  decoration, so all of it has to clear 4.5:1 against the surface it is
//  actually drawn on, in both appearances.
//
//  The old screens drew domains in `.secondary` and timestamps in `.tertiary`.
//  This measures what those actually were, and what replaced them.
//

import AppKit
import SwiftUI
import XCTest
@testable import Cherry

final class LibraryContrastTests: XCTestCase {

    /// WCAG AA for body-size text.
    private let floor = 4.5

    private let appearances: [(String, NSAppearance.Name)] = [
        ("light", .aqua),
        ("dark", .darkAqua),
    ]

    /// The surface library rows are drawn on: `LibraryPalette.listSurface`.
    private var listSurface: NSColor { .controlBackgroundColor }

    // MARK: - What the screens ship

    func testEveryLibraryTextToneClearsTheFloorOnTheRealSurface() {
        for (label, name) in appearances {
            guard let appearance = NSAppearance(named: name) else {
                XCTFail("no \(label) appearance")
                continue
            }
            appearance.performAsCurrentDrawingAppearance {
                let tones: [(String, NSColor)] = [
                    ("title (.primary)", .labelColor),
                    ("supporting", NSColor(LibraryPalette.supporting)),
                    ("failure", NSColor(LibraryPalette.failure)),
                ]
                for (role, colour) in tones {
                    let ratio = LibraryPalette.contrastRatio(colour, on: listSurface)
                    XCTAssertGreaterThanOrEqual(
                        ratio, floor,
                        "\(role) is \(ratio):1 on the list surface in \(label) mode"
                    )
                }
            }
        }
    }

    /// The rail is the one other surface these screens draw text on, and it is
    /// a translucent overlay rather than a flat colour, so it needs measuring
    /// separately rather than assuming the list's numbers carry over.
    func testSupportingTextClearsTheFloorOnTheScopeRail() {
        let railOverlays: [(String, NSAppearance.Name, NSColor)] = [
            ("light", .aqua, NSColor.systemGray.withAlphaComponent(0.05)),
            ("dark", .darkAqua, NSColor.black.withAlphaComponent(0.2)),
        ]

        for (label, name, overlay) in railOverlays {
            guard let appearance = NSAppearance(named: name) else {
                XCTFail("no \(label) appearance")
                continue
            }
            appearance.performAsCurrentDrawingAppearance {
                let rail = LibraryPalette.composite(overlay, over: .windowBackgroundColor)
                for (role, colour) in [
                    ("title (.primary)", NSColor.labelColor),
                    ("supporting", NSColor(LibraryPalette.supporting)),
                ] {
                    let ratio = LibraryPalette.contrastRatio(colour, on: rail)
                    XCTAssertGreaterThanOrEqual(
                        ratio, floor,
                        "\(role) is \(ratio):1 on the scope rail in \(label) mode"
                    )
                }
            }
        }
    }

    // MARK: - Why the palette exists

    /// The tones the old screens used. If a future macOS lifts them over the
    /// floor, this palette has stopped earning its keep and should be revisited
    /// rather than kept out of habit.
    func testTheSystemTonesTheOldScreensUsedFailInLightMode() {
        guard let appearance = NSAppearance(named: .aqua) else {
            return XCTFail("no light appearance")
        }
        appearance.performAsCurrentDrawingAppearance {
            XCTAssertLessThan(
                LibraryPalette.contrastRatio(.secondaryLabelColor, on: listSurface), floor,
                "secondaryLabelColor now clears the floor in light mode"
            )
            XCTAssertLessThan(
                LibraryPalette.contrastRatio(.tertiaryLabelColor, on: listSurface), floor,
                "tertiaryLabelColor now clears the floor in light mode"
            )
        }
    }

    /// `.tertiary` was the timestamp colour, and it was not close. Pinned so
    /// nobody reintroduces it thinking it was a near miss.
    func testTheOldTimestampToneWasFarBelowTheFloor() {
        guard let appearance = NSAppearance(named: .aqua) else {
            return XCTFail("no light appearance")
        }
        appearance.performAsCurrentDrawingAppearance {
            let ratio = LibraryPalette.contrastRatio(.tertiaryLabelColor, on: listSurface)
            XCTAssertLessThan(ratio, 3.0, "tertiaryLabelColor measured \(ratio):1")
        }
    }

    // MARK: - The arithmetic itself

    func testContrastRatioCompositesTranslucentForegroundsFirst() {
        // secondaryLabelColor is black at fractional alpha. Read raw it looks
        // like 21:1; composited it is the ~4:1 it actually renders as.
        let halfBlack = NSColor.black.withAlphaComponent(0.5)
        XCTAssertEqual(
            LibraryPalette.contrastRatio(halfBlack, on: .white), 3.95, accuracy: 0.05,
            "a half-alpha black on white must measure as the grey it renders as"
        )
    }

    func testRelativeLuminanceMatchesTheWCAGAnchors() {
        XCTAssertEqual(LibraryPalette.relativeLuminance(.white), 1.0, accuracy: 0.001)
        XCTAssertEqual(LibraryPalette.relativeLuminance(.black), 0.0, accuracy: 0.001)
        XCTAssertEqual(
            LibraryPalette.contrastRatio(.white, on: .black), 21.0, accuracy: 0.01
        )
    }

    /// The numbers the palette's header comment quotes, so the comment cannot
    /// drift away from the colours it describes.
    func testTheQuotedMeasurementsAreTheRealOnes() {
        let expected: [(NSAppearance.Name, Double, Double)] = [
            (.aqua, 5.74, 6.54),
            (.darkAqua, 5.93, 7.34),
        ]
        for (name, supporting, failure) in expected {
            guard let appearance = NSAppearance(named: name) else { continue }
            appearance.performAsCurrentDrawingAppearance {
                XCTAssertEqual(
                    LibraryPalette.contrastRatio(NSColor(LibraryPalette.supporting), on: listSurface),
                    supporting, accuracy: 0.05
                )
                XCTAssertEqual(
                    LibraryPalette.contrastRatio(NSColor(LibraryPalette.failure), on: listSurface),
                    failure, accuracy: 0.05
                )
            }
        }
    }
}
