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
//  ## Why it is a badge and not a tinted glyph
//
//  It draws over a toolbar that may be `.bar`, an imported theme's
//  `toolbarColor`, or a header backdrop **image** — and its `foregroundStyle`
//  overrides the bar's `themedToolbarText`, so it cannot inherit a tone that
//  was chosen against that backdrop either. A bare accent-tinted glyph is
//  therefore a signal with no contrast floor at all, and a pale accent on a
//  pale themed header is an indicator nobody can see. Everywhere else the
//  accent tints a glyph sitting beside high-contrast text; here it IS the whole
//  signal.
//
//  So the glyph sits on an opaque accent-filled badge and takes its tone from
//  `MCPStatusPalette.readableForeground(on:)`. The badge decouples the signal
//  from the backdrop: whatever is behind it, the glyph is only ever read
//  against the badge, at a measured ≥4.60:1 for every shipped accent.
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
                    badge
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

    private var badge: some View {
        let accent = SettingsManager.shared.accentColor
        return Image(systemName: "antenna.radiowaves.left.and.right")
            .font(.system(size: AppConstants.UI.toolbarIconSize - 2, weight: .semibold))
            .foregroundStyle(MCPStatusPalette.readableForeground(on: accent))
            .frame(width: 22, height: 18)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(accent)
            }
            .overlay {
                // A hairline in the glyph's own tone. It does nothing when the
                // badge already stands off the bar, and gives it an edge when
                // the accent happens to land near the backdrop's colour.
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        MCPStatusPalette.readableForeground(on: accent).opacity(0.35),
                        lineWidth: 0.5
                    )
            }
    }

    private func openConnectionsSettings() {
        SettingsNavigator.shared.request(.connections)
        onOpenSettings()
    }

    /// Keep the indicator up for whatever is left of the activity window, then
    /// take it down. Restarted by `.task(id:)` whenever another request lands,
    /// which is what makes a run of tool calls read as one connection rather
    /// than a stutter.
    ///
    /// The age check is the whole point, and its absence was a bug: `.task(id:)`
    /// also runs on every REMOUNT, so gating on `lastActivity != nil` and then
    /// sleeping the full window lit the indicator for ten seconds whenever the
    /// navigation bar was rebuilt — a second window, split view, leaving video
    /// fullscreen — over a timestamp that could be hours old. Sleeping only the
    /// REMAINING interval also means a remount mid-window does not restart the
    /// clock.
    private func holdVisible() async {
        guard let remaining = MCPServerPresentation.remainingActivityHold(
            since: manager.lastActivity,
            now: Date()
        ) else {
            withinActivityWindow = false
            return
        }
        withinActivityWindow = true
        try? await Task.sleep(for: .seconds(remaining))
        // On cancellation another request has already arrived and the next run
        // of this task owns the flag. Clearing it here would blink the glyph
        // off and straight back on.
        if !Task.isCancelled { withinActivityWindow = false }
    }
}
