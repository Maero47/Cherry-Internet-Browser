//
//  MCPConnectionIndicator.swift
//  Cherry Browser
//
//  The "something outside this browser is reading it" light.
//
//  ## Why this is NOT a `ToolbarButtonID`
//
//  The toolbar is user-customisable: every button in `ToolbarButtonID` can be
//  reordered and hidden from Settings ▸ General ▸ Toolbar. This is not one of
//  them, and the omission is deliberate, not an oversight to be tidied up.
//
//  This is a security indicator. It says that a program outside Cherry is
//  reading the user's tabs, page text, history or bookmarks right now. An
//  indicator the user can switch off is worse than no indicator at all: it
//  would let someone believe they were being told, while they were not, and it
//  would give anyone who could reach the settings a way to make the reading
//  invisible.
//
//  So: not in the catalogue, not reorderable, not hideable, and it does not
//  appear in the ⋯ overflow menu. **Do not "complete" the toolbar customisation
//  work by adding it.** If it ever needs to be optional, that is a product
//  decision about whether Cherry has a security indicator at all, not a
//  customisation gap.
//
//  ## Why it appears at all, given a stateless server
//
//  Each MCP request builds its own `MCP.Server`, answers, and is forgotten;
//  there is no held-open session to draw a lamp for. So "connected" means "used
//  within `MCPServerPresentation.activityWindow`" — see that constant for why.
//  Without the hold, a tool call lasting a few milliseconds would flash a glyph
//  no one could ever see, which is the same as not having one.
//
//  ## Motion budget
//
//  It appears and it disappears. It does not pulse, breathe, spin, or animate
//  on a loop, at any point, in any state. A security indicator that is always
//  moving becomes wallpaper within a day, and a moving thing in the toolbar is
//  a thing the eye cannot rest away from. The single cross-fade is skipped
//  entirely under `accessibilityReduceMotion`.
//

import SwiftUI

struct MCPConnectionIndicator: View {

    /// Opens Settings. The indicator's whole point is that the switch to stop
    /// this is one click away.
    let onOpenSettings: () -> Void

    @State private var manager = MCPServerManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// True from the moment a request lands until the activity window closes.
    /// Driven by `.task(id:)` rather than a repeating timer, so nothing ticks
    /// while no client is talking to Cherry.
    @State private var withinActivityWindow = false

    private var isConnected: Bool {
        manager.activeRequestCount > 0 || withinActivityWindow
    }

    var body: some View {
        Group {
            if isConnected {
                Button(action: openConnectionsSettings) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: AppConstants.UI.toolbarIconSize, weight: .medium))
                        .foregroundStyle(SettingsManager.shared.accentColor)
                }
                .buttonStyle(ToolbarButtonStyle())
                .help("An MCP client is reading Cherry right now. Click to open Connections settings.")
                .accessibilityLabel("MCP client connected")
                .accessibilityHint("Opens Connections settings, where you can switch the MCP server off")
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isConnected)
        .task(id: manager.lastActivity) { await holdVisible() }
    }

    private func openConnectionsSettings() {
        SettingsSection.pendingSelection = .connections
        onOpenSettings()
    }

    /// Keep the indicator up for the activity window after the last request,
    /// then take it down. Restarted by `.task(id:)` whenever another request
    /// lands, which is what makes a run of tool calls read as one connection
    /// rather than a stutter.
    private func holdVisible() async {
        guard manager.lastActivity != nil else {
            withinActivityWindow = false
            return
        }
        withinActivityWindow = true
        try? await Task.sleep(for: .seconds(MCPServerPresentation.activityWindow))
        // On cancellation another request has already arrived and the next run
        // of this task owns the flag. Clearing it here would blink the glyph
        // off and straight back on.
        if !Task.isCancelled { withinActivityWindow = false }
    }
}
