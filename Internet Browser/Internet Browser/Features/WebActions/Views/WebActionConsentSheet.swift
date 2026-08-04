//
//  WebActionConsentSheet.swift
//  Cherry Browser
//
//  The one moment the user is actually paying attention.
//
//  ## Why one prompt and not twenty
//
//  Per-action prompts are the anti-pattern this design exists to avoid. A person
//  asked twenty times stops reading by the fourth, and by the tenth they are
//  pressing Allow as a way of getting the dialog off the screen. So there is one
//  prompt per session, it names the tab and the site, it quotes the requester's
//  own words, and it says what the grant does NOT include — which is the part
//  people actually weigh.
//
//  ## Every claim below is checked against what the engine does
//
//  A security screen that misstates the risk is worse than none, so each line of
//  copy here has a counterpart in code, and the counterpart is what makes it
//  true:
//
//  | The sheet says | Enforced by |
//  | --- | --- |
//  | "in this tab" | `WebActionSessionStore.liveSession(forTab:requester:)` |
//  | "for N minutes" | `WebActionSession.isLive(at:)`, checked when an action runs |
//  | "ends if this tab goes to another site" | the origin pin in `WebActionBridge.perform` |
//  | "not your other tabs" | one grant, one `tabID`; there is no second lookup |
//  | "not your private windows" | `MCPBrowserBridge`'s two-level privacy gate |
//  | "will not type into password fields" | `elementRefusal`'s `passwordField` branch |
//  | "will not open a file chooser" | `elementRefusal`'s `filePicker` branch |
//  | "refuses buttons that look like they commit" | `WebActionHeuristics`, and it is called a GUESS here because that is what it is |
//
//  The one sentence with no counterpart in code is the last: the check is
//  English-only, blind to icon-only buttons, and deliberately silent about
//  "Continue" and "Next". Saying so on the sheet is the difference between a
//  security screen and a reassurance.
//

import SwiftUI

struct WebActionConsentSheet: View {

    let request: WebActionConsentRequest
    let onAllow: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            purpose
            permissions
            Divider()
            buttons
        }
        .padding(22)
        .frame(width: 460)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(request.requester.displayName) is asking to click and type in a tab")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "hand.tap")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(SettingsManager.shared.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(request.requester.displayName) wants to click and type in this tab")
                    .font(.system(size: 15, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(request.requester.identityDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var purpose: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The tab, named. A grant is for ONE tab and the user has to be able
            // to tell which.
            HStack(spacing: 6) {
                Text(request.tabTitle.isEmpty ? "Untitled tab" : request.tabTitle)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text("·")
                    .foregroundStyle(.secondary)
                Text(request.origin)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            // The requester's own words, quoted so it is visibly THEIR claim and
            // not Cherry's. Already one line and bounded — see
            // `WebActionText.sanitisePurpose` for the fake-UI attack that closes.
            Text("“\(request.purpose)”")
                .font(.system(size: 13))
                .italic()
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                .accessibilityLabel("Stated purpose: \(request.purpose)")
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 7) {
            row(
                "checkmark.circle",
                "It can click links and buttons and type into fields in this tab for "
                    + "\(request.minutes) \(request.minutes == 1 ? "minute" : "minutes")."
            )
            row(
                "xmark.circle",
                "It cannot see your other tabs, your private windows, or your saved passwords, and "
                    + "it cannot type into a password field or open a file chooser."
            )
            row(
                "arrow.uturn.backward.circle",
                "You can end it at any moment from the bar above the page. It also ends if this "
                    + "tab goes to another site, closes, or goes to sleep."
            )
            row(
                "exclamationmark.triangle",
                "Cherry refuses clicks on buttons whose names look like they commit something — "
                    + "paying, sending, deleting. That is a guess from English wording: it will "
                    + "miss an unlabelled icon, a page in another language, and anything called "
                    + "“Continue”."
            )
        }
    }

    private func row(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Spacer()
            // Escape declines. A prompt the user can only answer one way is not a
            // prompt, and the safe answer must be the reflexive one.
            Button("Not now", role: .cancel, action: onDecline)
                .keyboardShortcut(.cancelAction)
            // Deliberately NOT `.defaultAction`: Return must not grant a
            // permission to a program because the user happened to be typing.
            Button("Allow for \(request.minutes) \(request.minutes == 1 ? "minute" : "minutes")",
                   action: onAllow)
                .buttonStyle(.borderedProminent)
        }
    }
}
