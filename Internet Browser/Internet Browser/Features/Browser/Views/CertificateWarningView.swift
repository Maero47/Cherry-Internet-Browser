//
//  CertificateWarningView.swift
//  Cherry Browser
//
//  The certificate interstitial. The one screen in a browser where the copy is
//  the security feature.
//
//  ## The rules this screen is built to, and where each one lives
//
//  | Rule | How it is kept |
//  | --- | --- |
//  | blocking, not dismissible into the page | it is drawn over the whole content area with no close control, and the connection was already refused before it appeared |
//  | proceeding is possible | `Continue to <host>` exists and works |
//  | proceeding is deliberate | it is behind a disclosure the user must open, and it is the last control on the screen |
//  | proceeding is never pre-selected | `Leave this site` is `.defaultAction`; the proceed button carries no keyboard shortcut and is never focused |
//  | proceeding is never visually dominant | `Leave this site` is the only prominent button; proceed is a plain 12pt control in the body tone |
//  | the exception is scoped | the scope sentence is printed next to the button, and `CertificateExceptionStore` is what makes it true |
//  | a page cannot style or trigger it | it is SwiftUI over the web view, and every server-supplied string on it goes through `Text(verbatim:)` |
//
//  The host and the certificate's own name are the only untrusted text here,
//  and both are drawn verbatim in a monospaced box rather than interpolated
//  into a sentence Cherry renders as markdown.
//

import SwiftUI

struct CertificateWarningView: View {

    let warning: CertificateWarning
    let canGoBack: Bool
    let onLeave: () -> Void
    let onProceed: () -> Void

    /// Proceeding starts closed on every appearance. A screen that remembered
    /// it was open would be one keystroke from the outcome it exists to slow
    /// down.
    @State private var showingProceed = false

    var body: some View {
        FailureColumn {
            eyebrow

            Text(verbatim: warning.headline)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.primary)
                .fixedSize(horizontal: false, vertical: true)

            FailureAddress(text: warning.url.absoluteString)

            Text(verbatim: warning.detail)
                .font(.system(size: 14))
                .foregroundStyle(Color.primary)
                .fixedSize(horizontal: false, vertical: true)

            Text(verbatim: warning.risk)
                .font(.system(size: 13))
                .foregroundStyle(FailurePalette.body)
                .fixedSize(horizontal: false, vertical: true)

            Button("Leave this site", action: onLeave)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 4)
                .accessibilityHint(canGoBack
                    ? "Returns to the previous page"
                    : "Returns to the new tab page")

            Divider()
                .padding(.top, 8)

            proceed
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Security warning: \(warning.headline)")
    }

    private var eyebrow: some View {
        HStack(spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .accessibilityHidden(true)
            Text("Not secure")
                .font(.system(size: 12, weight: .semibold))
                .textCase(.uppercase)
                .kerning(0.8)
        }
        .foregroundStyle(FailurePalette.caution)
    }

    @ViewBuilder
    private var proceed: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                showingProceed.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: showingProceed ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text(showingProceed ? "Hide advanced" : "Advanced")
                        .font(.system(size: 12))
                }
                .foregroundStyle(FailurePalette.body)
                // A 12pt label is a small target, and the gap between the
                // chevron and the word is not part of it unless the shape says
                // so. Stated rather than left to the glyph outlines.
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showingProceed {
                Text(verbatim: warning.proceedScope)
                    .font(.system(size: 12))
                    .foregroundStyle(FailurePalette.body)
                    .fixedSize(horizontal: false, vertical: true)

                // Plain, small, in the body tone, and last. Deliberately NOT
                // `.borderedProminent`, NOT `.defaultAction`, and with no
                // keyboard shortcut of any kind: Return on this screen leaves
                // the site.
                Button {
                    onProceed()
                } label: {
                    Text("Continue to \(warning.host) anyway")
                        .font(.system(size: 12))
                        .foregroundStyle(FailurePalette.body)
                        .underline()
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(warning.proceedScope)
            }
        }
    }
}
