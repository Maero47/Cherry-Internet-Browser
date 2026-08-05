//
//  SystemAccentSurfacesTests.swift
//  Internet BrowserTests
//
//  The accent caption in Settings tells the user which surfaces follow the
//  accent and which cannot. Menus have moved from the second group to the
//  first — Cherry draws its own now — and that move is exactly the kind of
//  thing a reworded sentence can silently undo. Both halves get a checklist and
//  both checklists get a test.
//

import XCTest
@testable import Cherry

final class SystemAccentSurfacesTests: XCTestCase {

    func testCaptionNamesEverySurveyedSurface() {
        for surface in SystemAccentSurfaces.surveyed {
            XCTAssertNotNil(
                SystemAccentSurfaces.caption.range(of: surface, options: .caseInsensitive),
                "The accent caption no longer names \"\(surface)\". Every surface that "
                    + "ignores the accent has to be named or the user cannot tell which "
                    + "ones are supposed to follow it."
            )
        }
    }

    /// The reported defect was red menus. A caption that stops saying menus now
    /// follow leaves the user who remembers them red with no way to know.
    func testCaptionSaysCherryDrawnSurfacesFollow() {
        for surface in SystemAccentSurfaces.cherryDrawn {
            XCTAssertNotNil(
                SystemAccentSurfaces.caption.range(of: surface, options: .caseInsensitive),
                "The accent caption no longer mentions \"\(surface)\", which does follow "
                    + "the accent. The surfaces that changed are the ones worth naming."
            )
        }
        XCTAssertNotNil(SystemAccentSurfaces.caption.range(of: "follow the accent you pick here"))
    }

    /// Guards the lists themselves, not just the sentence. `menus` sitting in
    /// `surveyed` again would mean someone had reverted the conversion — or,
    /// worse, described it as reverted while it still worked.
    func testMenusAreNoLongerSurveyedAsSystemDrawn() {
        XCTAssertFalse(
            SystemAccentSurfaces.surveyed.contains("menus"),
            "Cherry draws its own menus (CherryMenuController), so they follow the "
                + "tint and do not belong on the list of surfaces that ignore it."
        )
        XCTAssertTrue(SystemAccentSurfaces.cherryDrawn.contains("menus"))
    }

    /// The caption is useless without the one lever the user actually has.
    func testCaptionPointsAtTheSystemAccentSetting() {
        XCTAssertTrue(SystemAccentSurfaces.caption.contains("System Settings"))
    }

    /// The default configuration is the confusing one, so it has to be spelled
    /// out rather than left as the unstated case.
    func testCaptionNamesTheMulticolourFallback() {
        XCTAssertTrue(SystemAccentSurfaces.caption.contains("Multicolour"))
    }

    /// The old caption needed a "the menu bar stays macOS blue" exception,
    /// because the app's red `AccentColor` asset made everything else red while
    /// the out-of-process menu bar stayed blue. With the asset gone, every
    /// system-drawn surface follows the one system accent and the exception
    /// would now be false.
    func testCaptionNoLongerClaimsCherryRedOrAMenuBarException() {
        XCTAssertFalse(SystemAccentSurfaces.caption.contains("Cherry red"))
        XCTAssertFalse(SystemAccentSurfaces.caption.contains("menu bar"))
    }

    /// One paragraph, because it sits under a swatch row in a settings pane.
    func testCaptionIsASingleParagraph() {
        XCTAssertFalse(SystemAccentSurfaces.caption.contains("\n"))
    }
}
