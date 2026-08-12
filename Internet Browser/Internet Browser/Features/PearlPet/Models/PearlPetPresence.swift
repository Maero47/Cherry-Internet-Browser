//
//  PearlPetPresence.swift
//  Cherry Browser
//
//  The one place that decides whether Pearl is on this page at all.
//
//  It is a pure function rather than a chain of `if`s in a view body because
//  every clause in it is a promise made to the user, and a promise that lives
//  in a view body is a promise nothing can check. `PearlPetPresenceTests`
//  walks every combination of these inputs; the view calls this and nothing
//  else.
//
//  A `false` here is not "hidden". The view is never built, so there is no
//  layer, no tick, no timer and nothing to leak — which is what makes the
//  Settings switch a real off switch rather than a visibility toggle.
//

import CoreGraphics

enum PearlPetPresence {

    /// Whether a pet belongs over this pane's page right now.
    ///
    /// - Parameters:
    ///   - enabled: the Settings switch. Off by default; off means she was
    ///     never built.
    ///   - isPrivate: a private window. Every themed and decorative surface in
    ///     Cherry refuses those, and a pet that watched you browse in
    ///     incognito would be the loudest possible exception.
    ///   - isFocusedPane: in split view only ONE Pearl exists, in the pane you
    ///     are working in. Two cats in one window is a bug that looks like a
    ///     feature.
    ///   - showsWebContent: she stands on the pages you browse, not on
    ///     Cherry's own surfaces — the homepage (a picture the user chose),
    ///     `cherry://` pages, Settings, the reader. Those are Cherry talking,
    ///     and she is not part of what it is saying.
    ///   - bottomSurfaceVisible: the find bar and the status toast live
    ///     exactly where she stands. When one is up she leaves; she is the
    ///     thing that yields, because the other two were asked for.
    ///   - contentSize: too small a page has no room for a cat.
    ///   - size: how big a cat the user asked for. It belongs in this decision
    ///     because "too small a page" is not one number: a 3x Pearl on a page
    ///     that a 1x Pearl sits on comfortably is not a companion, she is the
    ///     furniture. `PearlPetPlacement.minimumContentSize(for:)` is where
    ///     that scale lives.
    static func shouldShow(
        enabled: Bool,
        isPrivate: Bool,
        isFocusedPane: Bool,
        showsWebContent: Bool,
        bottomSurfaceVisible: Bool,
        contentSize: CGSize,
        size: PearlPetSize
    ) -> Bool {
        guard enabled, !isPrivate, isFocusedPane, showsWebContent, !bottomSurfaceVisible else {
            return false
        }
        return PearlPetPlacement.fits(contentSize, size: size)
    }
}
