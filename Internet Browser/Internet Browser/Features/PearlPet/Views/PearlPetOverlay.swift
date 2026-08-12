//
//  PearlPetOverlay.swift
//  Cherry Browser
//
//  The seam between the page and the cat standing on it.
//
//  This is deliberately thin. It answers three questions and nothing else:
//  whether she is here at all (`PearlPetPresence`), where on the floor she
//  stands (`PearlPetPlacement`), and what she is allowed to reach into
//  (`PearlPetHost`). Everything she DOES is in `PearlPetView`; everything she
//  IS is in the models beside it.
//
//  ## Why an overlay on the web view and not a layer on the window
//
//  She has to be clipped to the page. A pet hosted on the window would need to
//  be told about split panes, the sidebar, the bookmark bar appearing, video
//  fullscreen and every future piece of chrome, and would be wrong for one
//  frame each time. As an overlay she inherits the pane's geometry by
//  construction: when the pane resizes she moves, and when the pane stops
//  existing so does she.
//
//  ## Nothing here is a surface
//
//  There is no `Color.clear`, no `background`, no `contentShape` anywhere in
//  this file, and that is load-bearing rather than tidy: any of them would put
//  a transparent wall over the page and every click on the site would land on
//  it. The only hit-testable thing in this subtree is Pearl's own `NSView`,
//  which answers per pixel (`PearlPetView.hitTest`). The `GeometryReader` is a
//  measuring device and contributes no hit area of its own.
//
//  ## Why `.position` rather than an alignment
//
//  Her hosting view is only as big as she is plus her hearts' headroom,
//  because a full-page view would be asked to hit-test every click on the
//  page. Placing a small view at an exact point is what `.position` is for.
//

import SwiftUI

struct PearlPetOverlay: View {

    /// The browser behind the page she is standing on.
    let host: any PearlPetHost
    /// Whether this pane's page is one she is allowed to stand on.
    let showsWebContent: Bool
    /// In split view, only the focused pane has her.
    let isFocusedPane: Bool
    let isPrivate: Bool
    /// The find bar and the status toast stand exactly where she does.
    let bottomSurfaceVisible: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var settings: SettingsManager { .shared }
    private let home = PearlPetHome()
    @State private var position = PearlPetHome().position

    /// Her standing box. The sleeping box is shorter and narrower, so a host
    /// view sized for the standing one always has room for both.
    private var spriteSize: CGSize {
        CGSize(
            width: PearlSpriteContract.petStanding.width,
            height: PearlSpriteContract.petStanding.height
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            if PearlPetPresence.shouldShow(
                enabled: settings.showPearlPet,
                isPrivate: isPrivate,
                isFocusedPane: isFocusedPane,
                showsWebContent: showsWebContent,
                bottomSurfaceVisible: bottomSurfaceVisible,
                contentSize: size
            ) {
                let frame = PearlPetPlacement.hostFrame(
                    in: size,
                    spriteSize: spriteSize,
                    position: position
                )
                PearlPetRepresentable(
                    host: host,
                    contentSize: size,
                    position: position,
                    reduceMotion: reduceMotion,
                    onMove: { moved in
                        position = moved
                        home.position = moved
                    },
                    onPutAway: { settings.showPearlPet = false }
                )
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
            }
        }
    }
}

/// `PearlPetView`, as SwiftUI sees it. It carries nothing of its own — every
/// property is pushed straight onto the `NSView`.
private struct PearlPetRepresentable: NSViewRepresentable {

    let host: any PearlPetHost
    let contentSize: CGSize
    let position: CGFloat
    let reduceMotion: Bool
    let onMove: (CGFloat) -> Void
    let onPutAway: () -> Void

    func makeNSView(context: Context) -> PearlPetView {
        let view = PearlPetView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: PearlPetView, context: Context) {
        apply(to: view)
    }

    /// SwiftUI takes the view out of its window when it leaves the tree, and
    /// `PearlPetView.viewDidMoveToWindow` stops the tick there. This says so
    /// out loud rather than leaving it to be assumed.
    static func dismantleNSView(_ view: PearlPetView, coordinator: ()) {
        view.removeFromSuperview()
    }

    private func apply(to view: PearlPetView) {
        view.host = host
        view.contentSize = contentSize
        view.position = position
        view.reduceMotion = reduceMotion
        view.onMove = onMove
        view.onPutAway = onPutAway
    }
}
