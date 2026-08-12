//
//  PearlPetOverlay.swift
//  Cherry Browser
//
//  The seam between the page and the cat standing on it.
//
//  This is deliberately thin. It answers three questions and nothing else:
//  whether she is here at all (`PearlPetPresence`), where on the page she
//  stands and how big she is (`PearlPetPlacement`, `PearlPetSize`), and what
//  she is allowed to reach into (`PearlPetHost`). Everything she DOES is in
//  `PearlPetView`; everything she IS is in the models beside it.
//
//  ## Where her spot and her size are kept
//
//  In `PearlPetHome` — one place for the whole app, read when a pane brings
//  her on and written when the user moves or resizes her. That is the answer
//  to "per window, per tab, or per app": a cat who is in a different corner of
//  every tab is a cat you have to look for, and there is no window identity
//  that survives a relaunch to key her to. It has one visible consequence,
//  which is the intended one: a drag moves her in the window you are dragging
//  in, and every pane opened afterwards starts where you left her.
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
    /// How many downloads Cherry has finished this session. The pane hands it
    /// over; she reacts to the ones she has not seen yet. Passed as a plain
    /// count rather than observed here, so this file keeps having nothing in
    /// it that runs.
    let finishedDownloads: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var settings: SettingsManager { .shared }
    private let home = PearlPetHome()
    @State private var spot = PearlPetHome().spot
    @State private var petSize = PearlPetHome().size

    var body: some View {
        GeometryReader { geometry in
            let content = geometry.size
            if PearlPetPresence.shouldShow(
                enabled: settings.showPearlPet,
                isPrivate: isPrivate,
                isFocusedPane: isFocusedPane,
                showsWebContent: showsWebContent,
                bottomSurfaceVisible: bottomSurfaceVisible,
                contentSize: content,
                size: petSize
            ) {
                // Recomputed from THIS pane's size every time it changes, which
                // is what makes a spot saved in a big window land inside a
                // small one — there is no stored rectangle to be stale.
                let frame = PearlPetPlacement.hostFrame(
                    in: content,
                    size: petSize,
                    spot: spot
                )
                PearlPetRepresentable(
                    host: host,
                    contentSize: content,
                    spot: spot,
                    size: petSize,
                    finishedDownloads: finishedDownloads,
                    reduceMotion: reduceMotion,
                    onMove: { moved in
                        spot = moved
                        home.spot = moved
                    },
                    onResize: { chosen in
                        petSize = chosen
                        home.size = chosen
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
    let spot: PearlPetSpot
    let size: PearlPetSize
    let finishedDownloads: Int
    let reduceMotion: Bool
    let onMove: (PearlPetSpot) -> Void
    let onResize: (PearlPetSize) -> Void
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
        view.spot = spot
        view.size = size
        view.reduceMotion = reduceMotion
        view.onMove = onMove
        view.onResize = onResize
        view.onPutAway = onPutAway
        // Last, so that everything she might react with is already in place —
        // and after the size, so a reaction that arrives in the same update as
        // a resize is drawn at the size the user just picked.
        view.noticeDownloads(finishedDownloads)
    }
}
