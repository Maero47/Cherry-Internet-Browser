//
//  ExtensionToolbarButton.swift
//  Internet Browser
//

import SwiftUI
import WebKit

/// Plain reference-type holder for a button's anchor `NSView`. Set
/// synchronously by `PopoverAnchorView.makeNSView` — unlike `@State`, writing
/// to a class property doesn't need to route through a SwiftUI view update,
/// so the anchor is available immediately once AppKit creates the backing
/// view, with no risk of a click racing an async assignment and finding it
/// still nil.
private final class PopoverAnchorBox {
    var view: NSView?
}

/// A zero-size AppKit view whose only purpose is providing a stable `NSView`
/// identity to anchor `NSPopover.show(relativeTo:of:preferredEdge:)` to —
/// SwiftUI's `Button` has no `NSView` of its own to hand the popover.
private struct PopoverAnchorView: NSViewRepresentable {
    let box: PopoverAnchorBox

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// One toolbar button per loaded extension. Shows that extension's action
/// icon (falling back to a puzzle-piece glyph) plus its badge text for
/// `tab`, and presents the extension's popup on click.
struct ExtensionToolbarButton: View {
    let loaded: ExtensionManager.LoadedExtension
    let tab: Tab?

    @State private var anchorBox = PopoverAnchorBox()

    /// The action icon's dominant tone, or nil when the extension supplies no
    /// icon and the puzzle-piece glyph is drawn instead.
    private var iconTone: Color? {
        guard let icon = action?.icon(
            for: CGSize(width: AppConstants.UI.toolbarIconSize, height: AppConstants.UI.toolbarIconSize)
        ) else { return nil }
        return ThemeContrastGuard.shared.dominantTone(of: icon, id: loaded.id)
    }

    private var action: WKWebExtension.Action? {
        // Reading `actionUpdateTick` (unused otherwise) makes this computed
        // property — and therefore the button's icon/badge — re-evaluate
        // whenever `didUpdateAction` fires for any extension.
        _ = ExtensionManager.shared.actionUpdateTick
        return ExtensionManager.shared.action(for: loaded, tab: tab)
    }

    var body: some View {
        Button {
            ExtensionManager.shared.performAction(for: loaded, tab: tab, anchorView: anchorBox.view)
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let icon = action?.icon(for: CGSize(width: AppConstants.UI.toolbarIconSize, height: AppConstants.UI.toolbarIconSize)) {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: AppConstants.UI.toolbarIconSize, height: AppConstants.UI.toolbarIconSize)
                    } else {
                        Image(systemName: "puzzlepiece.extension")
                            .font(.system(size: AppConstants.UI.toolbarIconSize, weight: .medium))
                    }
                }
                .opacity(action?.isEnabled == false ? 0.4 : 1.0)

                if let badge = action?.badgeText, !badge.isEmpty {
                    Text(badge)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.red))
                        .offset(x: 6, y: 6)
                }
            }
        }
        .buttonStyle(ToolbarButtonStyle())
        // The one toolbar glyph Cherry does not choose the colour of. Told to
        // the contrast guard so the scrim behind it is solved for the icon's
        // own tone rather than for the bar's `toolbar_text`, which this button
        // never draws in. Nil (no action icon) leaves the inherited tone, which
        // is right: the puzzle-piece fallback IS drawn in `toolbar_text`.
        .themeLegibilityTint(iconTone)
        .background(PopoverAnchorView(box: anchorBox))
        .help(action?.label ?? loaded.displayName)
    }
}
