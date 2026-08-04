//
//  WebActionSessionBar.swift
//  Cherry Browser
//
//  "Something is clicking in this tab right now", and the one click that stops
//  it.
//
//  ## Why it is not hideable, and not in the toolbar catalogue
//
//  Same argument as `MCPConnectionIndicator`, with more force: that one says a
//  program is READING the browser, this one says a program is CHANGING a page.
//  An indicator the user can switch off would let someone believe they were
//  being told while they were not. So it is not a `ToolbarButtonID`, it is not
//  reorderable, it is not hideable, and it is re-hosted in video fullscreen —
//  which hides the whole navigation bar — for exactly the reason the comment at
//  `BrowserView`'s overlay gives.
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

    /// The tab this bar sits above. A grant is for one tab, so the bar is drawn
    /// per tab and never window-wide: in split view the pane being acted on is
    /// the pane that shows it.
    let tabID: UUID

    @State private var store = WebActionSessionStore.shared
    @State private var now = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var session: WebActionSession? {
        store.liveSessions.first { $0.tabID == tabID }
    }

    var body: some View {
        Group {
            if let session {
                bar(for: session)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: session?.id)
        // A second, not 100ms: the digits only ever change once a second, and a
        // faster tick is main-actor work bought for nothing.
        .task(id: session?.id) {
            guard session != nil else { return }
            while !Task.isCancelled {
                now = Date()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func bar(for session: WebActionSession) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.tap.fill")
                .font(.system(size: 11, weight: .semibold))
                .accessibilityHidden(true)

            Text("\(session.requester.displayName) is clicking and typing in this tab")
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
        .accessibilityLabel("\(session.requester.displayName) is clicking and typing in this tab: \(session.purpose)")
    }

    /// `m:ss`, floored. Never negative — an expired session has already stopped
    /// being drawn, and a bar reading "-0:03" would be the UI disagreeing with
    /// the enforcement.
    nonisolated static func countdown(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        return String(format: "%d:%02d left", clamped / 60, clamped % 60)
    }
}
