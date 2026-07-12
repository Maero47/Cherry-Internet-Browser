//
//  ExtensionToolbarButton.swift
//  Internet Browser
//

import SwiftUI
import WebKit

/// A zero-size AppKit view whose only purpose is providing a stable `NSView`
/// identity to anchor `NSPopover.show(relativeTo:of:preferredEdge:)` to —
/// SwiftUI's `Button` has no `NSView` of its own to hand the popover.
private struct PopoverAnchorView: NSViewRepresentable {
    @Binding var anchor: NSView?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { anchor = view }
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

    @State private var anchorView: NSView?

    private var action: WKWebExtension.Action? {
        // Reading `actionUpdateTick` (unused otherwise) makes this computed
        // property — and therefore the button's icon/badge — re-evaluate
        // whenever `didUpdateAction` fires for any extension.
        _ = ExtensionManager.shared.actionUpdateTick
        return ExtensionManager.shared.action(for: loaded, tab: tab)
    }

    var body: some View {
        Button {
            ExtensionManager.shared.performAction(for: loaded, tab: tab, anchorView: anchorView)
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
        .background(PopoverAnchorView(anchor: $anchorView))
        .help(action?.label ?? loaded.displayName)
    }
}
