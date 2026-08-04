//
//  WebActionSessionBar.swift
//  Cherry Browser
//
//  "Something is clicking in this window right now", and the one click that
//  stops it.
//
//  ## Why it is per WINDOW and not per displayed pane
//
//  It used to be per pane, which meant it only existed while the tab being acted
//  on was the tab on screen. A grant survives tab switching — that is the whole
//  point of a time-boxed session — so an agent could click and type in tab A for
//  up to thirty minutes while the user worked in tab B, with no sign anywhere
//  and no way to end it without first guessing which tab to switch to. The file
//  argued at length that this indicator must not be hideable while shipping one
//  that was invisible, which is worse.
//
//  So: one row per live session in this window, always drawn, naming its tab.
//  The row for the tab you are looking at says "this tab"; the others name
//  theirs, so ending the right one needs no guessing and no tab switch.
//
//  ## Why it is not hideable, and not in the toolbar catalogue
//
//  Same argument as `MCPConnectionIndicator`, with more force: that one says a
//  program is READING the browser, this one says a program is CHANGING a page.
//  An indicator the user can switch off would let someone believe they were
//  being told while they were not. Not a `ToolbarButtonID`, not reorderable, not
//  hideable, and drawn in video fullscreen too — which hides the whole
//  navigation bar — for exactly the reason `BrowserView`'s overlay comment gives.
//
//  ## The countdown is cosmetic and nothing depends on it
//
//  The timer below drives the digits and nothing else. Expiry is decided by
//  `WebActionSession.isLive(at:)` at the instant an action runs, so a bar that
//  stopped ticking — a window that never redraws, a suspended app — cannot leave
//  an expired grant usable. That is the whole reason expiry is checked at the
//  point of use rather than fired from a timer.
//
//  ## Motion budget
//
//  It appears, the digits change once a second, and it disappears. It does not
//  pulse, breathe or animate on a loop. A security indicator that is always
//  moving becomes wallpaper within a day.
//

import SwiftUI

struct WebActionSessionBar: View {

    /// The window this bar belongs to. Every live session granted in it is drawn,
    /// whether or not its tab is the one on screen.
    let windowID: UUID

    /// The window's tabs, so a row can name the tab it is about and say whether
    /// it is the one being looked at.
    let tabManager: TabManager

    @State private var store = WebActionSessionStore.shared
    @State private var now = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var sessions: [WebActionSession] {
        store.liveSessions.filter { $0.windowID == windowID }
    }

    var body: some View {
        Group {
            if !sessions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(sessions) { session in
                        row(for: session)
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: sessions.count)
        // A second, not 100ms: the digits only ever change once a second, and a
        // faster tick is main-actor work bought for nothing.
        .task(id: sessions.isEmpty) {
            guard !sessions.isEmpty else { return }
            while !Task.isCancelled {
                now = Date()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// How the row names the tab it is about.
    ///
    /// "this tab" only when that tab is actually on screen — in split view both
    /// panes count. Otherwise the tab's own title, so the user can tell which of
    /// their tabs is being driven without switching to find out.
    private func where_(_ session: WebActionSession) -> String {
        let displayed = [tabManager.selectedTabID, tabManager.secondarySelectedTabID]
        if displayed.contains(session.tabID) { return "this tab" }
        guard let tab = tabManager.tabs.first(where: { $0.id == session.tabID }) else {
            return "another tab"
        }
        return "“\(WebActionText.singleLine(tab.displayTitle, limit: 40))”"
    }

    private func row(for session: WebActionSession) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.tap.fill")
                .font(.system(size: 11, weight: .semibold))
                .accessibilityHidden(true)

            Text("\(session.requester.displayName) is clicking and typing in \(where_(session))")
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)

            // The purpose it was granted for, so the user can see at a glance
            // whether what is happening is what they agreed to. This is the same
            // string every audit entry is recorded against.
            Text("· \(session.purpose)")
                .font(.system(size: 11))
                .opacity(0.85)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            Text(Self.countdown(session.secondsRemaining(at: now)))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .opacity(0.9)
                .accessibilityLabel("\(session.secondsRemaining(at: now)) seconds left")

            Button("End") {
                store.revoke(sessionID: session.id)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.white.opacity(0.22))
            )
            .help("End this session now. Nothing further will be clicked or typed.")
            .accessibilityHint("Ends the session immediately")
        }
        .foregroundStyle(MCPStatusPalette.readableForeground(on: SettingsManager.shared.accentColor))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SettingsManager.shared.accentColor)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(session.requester.displayName) is clicking and typing in \(where_(session)): "
                + session.purpose
        )
    }

    /// `m:ss`, floored. Never negative — an expired session has already stopped
    /// being drawn, and a bar reading "-0:03" would be the UI disagreeing with
    /// the enforcement.
    nonisolated static func countdown(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        return String(format: "%d:%02d left", clamped / 60, clamped % 60)
    }
}
