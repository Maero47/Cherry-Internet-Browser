//
//  PearlRunnerKeyboard.swift
//  Cherry Browser
//
//  The AppKit half of the runner's keyboard: which window it is in, who had
//  the keyboard before it asked, and giving that back.
//
//  ## Why SwiftUI needed help here
//
//  `@FocusState` can say "focus me", and that is all this needs from it. What
//  it cannot say is who it is taking focus FROM, and on this screen that
//  matters twice:
//
//  * The refusal. A failure can arrive while the user is typing an address.
//    Whether that is happening is a fact about the window's first responder —
//    a field editor is an `NSText` — and SwiftUI does not publish it.
//  * The return. The failure surface is drawn OVER the tab's web view, which
//    is still there and, if the user had clicked into the page, still holds
//    the keyboard. Retry succeeds, the surface goes away, and something has to
//    put the keyboard back where it was or the page comes back deaf.
//
//  Both are one weak reference to a window and one to a responder, held for as
//  long as the offline screen is up.
//

import AppKit
import SwiftUI

/// The window the runner's section is in, and the responder it borrowed the
/// keyboard from. A reference type because two sides write to it: the AppKit
/// view below, when the section is installed in a window, and the section's
/// own lifecycle handlers, when it takes the keyboard and when it leaves.
///
/// Everything it holds is weak. A failure screen must not be the reason a
/// window or a web view outlives its tab.
@MainActor
final class PearlKeyboardHandover {

    /// The window the section is in, or `nil` before it has been installed in
    /// one. Callers fall back to the key window rather than assume.
    private(set) weak var window: NSWindow?

    /// Who held the keyboard at the moment the runner asked for it. Stays
    /// `nil` when the runner never asked, which is what makes `giveBack()`
    /// safe to call unconditionally.
    private weak var displaced: NSResponder?

    /// Whether the keyboard has already been taken once. A second `take()` —
    /// a click on a mark that is already focused — must not overwrite the
    /// borrowed responder with the runner's own slot, which would make
    /// `giveBack()` hand the keyboard to a view that is about to be removed.
    private var hasTaken = false

    /// Whether the runner has already asked for the keyboard, so the two
    /// places that ask do not both ask.
    var hasTakenKeyboard: Bool { hasTaken }

    /// Called from `viewDidMoveToWindow`, and only ever with a real window:
    /// the same call arrives with `nil` on the way out, and forgetting the
    /// window there would leave nothing to give the keyboard back to.
    func attach(to window: NSWindow) {
        self.window = window
    }

    /// Whether the keyboard is inside something the user is typing in.
    ///
    /// The window's own first responder, not the app's: two browser windows
    /// can be offline at once, and only this one's omnibox can be the one
    /// mid-word. Answers false with no window, which is why nothing asks
    /// before there is one.
    var textIsBeingEdited: Bool {
        switch window?.firstResponder {
        case let text as NSText:
            // The field editor — what actually holds the keyboard while a
            // `TextField` (the omnibox, find bar, rename field) is being typed
            // into.
            return text.isEditable
        case let field as NSTextField:
            // No field editor installed yet, but the field is the responder:
            // the same moment, one step earlier.
            return field.isEditable
        default:
            return false
        }
    }

    /// Remember who is losing the keyboard, immediately before taking it.
    func take() {
        guard !hasTaken else { return }
        hasTaken = true
        displaced = window?.firstResponder
    }

    /// The offline screen is gone. Hand the keyboard back to whoever the
    /// runner took it from, if they are still in this window to want it —
    /// otherwise the page that just came back would be left unable to scroll
    /// until it was clicked, which is the very complaint this feature started
    /// from.
    func giveBack() {
        guard let window, let displaced else { return }
        guard displaced !== window else {
            // Nobody held it; leave it held by nobody rather than by whatever
            // AppKit fell back to when the runner's slot was removed.
            window.makeFirstResponder(nil)
            return
        }
        guard let view = displaced as? NSView, view.window === window else { return }
        window.makeFirstResponder(view)
    }
}

/// A zero-size AppKit view whose only job is to tell the handover which window
/// the section ended up in. Same shape as `WindowConfigurator`: the one way
/// this app has of asking that question.
struct PearlKeyboardWindowReader: NSViewRepresentable {

    let handover: PearlKeyboardHandover

    /// Called once the window is known, because that is the earliest the
    /// runner can decide whether it may ask for the keyboard — and it may
    /// well be later than the section's own `onAppear`.
    let windowKnown: () -> Void

    func makeNSView(context: Context) -> NSView {
        Reader(handover: handover, windowKnown: windowKnown)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Reader: NSView {
        private let handover: PearlKeyboardHandover
        private let windowKnown: () -> Void

        init(handover: PearlKeyboardHandover, windowKnown: @escaping () -> Void) {
            self.handover = handover
            self.windowKnown = windowKnown
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Only on the way in. This same call arrives with a nil window
            // when the surface is torn down, and that is exactly when the
            // handover still needs the window to give the keyboard back to.
            guard let window else { return }
            handover.attach(to: window)
            windowKnown()
        }
    }
}
