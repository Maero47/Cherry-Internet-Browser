//
//  NavigationFailureView.swift
//  Cherry Browser
//
//  The screen a page that did not load leaves behind.
//
//  ## What it is not
//
//  It is not web content and it is not a `cherry://` page. It is drawn by
//  Cherry, in Cherry's chrome, over the tab's own web view, which stays exactly
//  where it was: the address in the toolbar is still the one the user asked
//  for, Back still walks the web view's real history, and the page underneath
//  is never given a chance to style, script, or trigger any of this.
//
//  ## Motion
//
//  There is none, and that is the design. An error appears when somebody is
//  already frustrated; a screen that slides, fades or bounces in has added a
//  wait to a moment that was already a wait. The single moving part in the
//  whole surface is the spinner that appears after Retry is pressed, and
//  `accessibilityReduceMotion` replaces even that with the word.
//
//  The one exception is chosen, not shown: the offline family — and only it,
//  see `NavigationFailure.offersPearlRunner` — puts Pearl's runner in the top
//  slot, in place of the symbol. It is as still as the rest of the screen;
//  nothing moves unless the user starts the game.
//
//  ## Why the game is above the copy and the copy still reads first
//
//  The runner does not sit between the reader and anything. It takes the one
//  slot on this screen that never held a word — the symbol's — and at rest it
//  is the same wordless mark at the same height, so the title, the
//  explanation, the address and Retry are at the exact distance from the top
//  they are on every other failure family. Nothing was pushed down and
//  nothing was demoted: the first *text* is still the 22pt title, and the
//  runner's own caption is 11pt in the body tone beside the mark.
//

import SwiftUI

struct NavigationFailureView: View {

    let failure: NavigationFailure
    let isRetrying: Bool
    let canGoBack: Bool
    let onRetry: () -> Void
    let onBack: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        FailureColumn {
            if failure.offersPearlRunner {
                // The wait screen's game, where Chrome puts the dino: above
                // the failure text, in the slot the symbol holds elsewhere.
                // At rest it is a still mark of the symbol's height, so no
                // word below it moved; it starts nothing on its own.
                PearlRunnerSection(offersRunner: failure.offersPearlRunner)
            } else {
                Image(systemName: failure.symbolName)
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(FailurePalette.body)
                    .accessibilityHidden(true)
            }

            Text(verbatim: failure.title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.primary)
                .fixedSize(horizontal: false, vertical: true)

            Text(verbatim: failure.explanation)
                .font(.system(size: 14))
                .foregroundStyle(FailurePalette.body)
                .fixedSize(horizontal: false, vertical: true)

            if let address = failure.url?.absoluteString {
                FailureAddress(text: address)
            }

            if let nextStep = failure.nextStep {
                Text(verbatim: nextStep)
                    .font(.system(size: 13))
                    .foregroundStyle(FailurePalette.body)
                    .fixedSize(horizontal: false, vertical: true)
            }

            actions

            if let diagnostic = failure.diagnosticLine {
                // Only the unrecognised family gets here. The domain and code
                // are what makes a failure Cherry has no words for still
                // reportable, instead of a dead end.
                Text(verbatim: diagnostic)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(FailurePalette.body)
                    .textSelection(.enabled)
                    .padding(.top, 2)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(failure.title)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            if isRetrying {
                // The moment after Retry: the surface does not vanish to a
                // blank page and reappear if the retry also fails. It stays,
                // says what it is doing, and is replaced only when the retry
                // has content to show.
                HStack(spacing: 7) {
                    if !reduceMotion {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Retrying")
                        .font(.system(size: 13))
                        .foregroundStyle(FailurePalette.body)
                }
                .accessibilityLabel("Retrying \(failure.url?.absoluteString ?? "the address")")
            } else {
                Button("Retry", action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }

            if canGoBack {
                Button("Back", action: onBack)
                    .buttonStyle(.bordered)
                    .disabled(isRetrying)
            }
        }
        .padding(.top, 4)
    }
}
