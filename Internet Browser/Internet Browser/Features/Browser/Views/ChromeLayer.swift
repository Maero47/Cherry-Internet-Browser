//
//  ChromeLayer.swift
//  Cherry Browser
//
//  The z-order of the browser chrome, in one place.
//
//  ## Why chrome needs a z-order at all
//
//  A tab's `WKWebView` is an AppKit view hosted inside a SwiftUI stack. AppKit
//  composites a hosted view ABOVE any SwiftUI sibling that has not been given a
//  z-order of its own — SwiftUI only promotes a view out of the shared drawing
//  pass once it has a reason to, and an explicit `zIndex` is that reason.
//
//  In a window this never shows, because the host sits exactly in the slot the
//  layout gave it and covers nothing else. Entering fullscreen resizes it to
//  the whole window before SwiftUI re-lays the stack around it, and from that
//  moment it is drawn over everything above it.
//
//  That is the whole of the "fullscreen loses the tab strip" defect. Nothing
//  was conditional on fullscreen and nothing collapsed: the strip was laid out
//  at 1920x38 at the top of the window, and painted underneath the page. The
//  navigation bar survived only because it already carried a `zIndex` — added
//  for an unrelated reason (its autofill popup and split-pane accent bar) — and
//  the bookmark bar, which carried none, disappeared alongside the strip.
//
//  So the values live here together rather than as three loose numbers: they
//  only mean anything relative to each other, and the bug was caused by one row
//  of the chrome having an opinion about z-order while its neighbours did not.
//
//  Ordering: the navigation bar is highest because its autofill popup overhangs
//  the rows below it.
//
enum ChromeLayer {
    /// The horizontal tab strip, above the tab bar's own separator hairline.
    static let tabStrip: Double = 100

    /// The bookmark bar, below the navigation bar it hangs from.
    static let bookmarkBar: Double = 150

    /// The navigation bar, and the autofill popup that overhangs from it.
    static let navigationBar: Double = 200
}
