//
//  SystemAccentSurfacesTests.swift
//  Internet BrowserTests
//
//  The accent caption in Settings is not decoration — it is the whole of
//  Cherry's answer to "why is this menu red when my accent is blue?", because
//  no runtime API can retint the surfaces it names. That makes its coverage
//  behaviour, and behaviour gets a test: rewording the sentence must not be
//  able to quietly drop a surface, least of all `menus`, which is the one the
//  defect was reported against.
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

    /// Guards the list itself, not just the sentence: dropping `menus` from
    /// `surveyed` would make the caption test pass while the caption stopped
    /// mentioning the ⋯ menu and every context menu in the app.
    func testMenusAreSurveyed() {
        XCTAssertTrue(SystemAccentSurfaces.surveyed.contains("menus"))
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

    /// The menu bar is drawn outside Cherry's process and falls back to stock
    /// macOS blue, not to Cherry's red asset. Without this clause the sentence
    /// is simply wrong about one of the surfaces it covers.
    func testCaptionCallsOutTheMenuBarException() {
        XCTAssertTrue(SystemAccentSurfaces.caption.contains("menu bar"))
    }

    /// One line, because it sits under a swatch row in a settings pane.
    func testCaptionIsASingleParagraph() {
        XCTAssertFalse(SystemAccentSurfaces.caption.contains("\n"))
    }
}
