//
//  WebActionPopupPolicy.swift
//  Cherry Browser
//
//  Which popups a page may still open while an agent is clicking in it.
//
//  ## The finding this exists for
//
//  `evaluateJavaScript` carries a LIVE user gesture. Measured:
//
//  ```
//  === USER ACTIVATION ===
//    top-of-evaluateJavaScript          isActive=true  hasBeenActive=true
//    inside-synthetic-click-handler     isActive=true  hasBeenActive=true
//  -- popup with javaScriptCanOpenWindowsAutomatically = false, via evaluateJavaScript:
//     createWebViewWith: ["https://example.com/eval-popup type=-1"]
//  ```
//
//  Every good outcome and every bad one follows from that single fact. Good:
//  there is no gesture-gating problem to solve — synthesised clicks work, form
//  submits work. Bad: **nothing is gated, and every gate has to be Cherry's own.**
//
//  The plan assumed Cherry's existing popup handling already covered this,
//  because `createWebViewWith` checks `navigationType` before adopting a popup.
//  Reading the code, it does not: that check only runs when the popup blocker is
//  ON, and even then it only refuses a `.other` popup whose URL *looks like an
//  ad*. So a `window.open` reached from an agent click opened a real window.
//  This is the missing half.
//
//  ## Why the rule is this narrow
//
//  `.linkActivated` and the two form-submission types are what a real
//  `<a target="_blank">` and a real form produce, and an agent clicking one of
//  those is doing exactly what it was permitted to do — refusing them would
//  break ordinary clicking to close a hole that is not there. `.other` is what a
//  scripted `window.open` produces, and under a session that is a window nobody
//  asked for.
//
//  `nonisolated` and pure so the predicate is a unit test rather than a
//  screenshot.
//

import WebKit

nonisolated enum WebActionPopupPolicy {

    /// Whether a new window may be adopted while a live action session covers
    /// the opener's tab.
    ///
    /// Applies ONLY under a session. With no session this is not consulted at
    /// all and Cherry's ordinary popup handling is unchanged.
    static func allowsPopup(navigationType: WKNavigationType) -> Bool {
        switch navigationType {
        case .linkActivated, .formSubmitted, .formResubmitted:
            true
        default:
            // `.other` (which is what a scripted `window.open` arrives as),
            // `.reload`, `.backForward`. None of them is a control the agent
            // pressed, so none of them is covered by what the user allowed.
            false
        }
    }
}
