//
//  PearlKeyboardClaim.swift
//  Cherry Browser
//
//  Whether the runner may take the keyboard when the offline screen appears.
//
//  ## Why there is a rule here at all
//
//  `PearlSpaceKey` answers "who does this press belong to", and its second
//  guard is `runnerHasKeyboardFocus`. That guard is only worth anything if the
//  runner can actually come to hold the keyboard on a screen nobody has
//  clicked — and for two rounds it could not. The offer said "Space to run
//  while you wait", the press went up an empty responder chain, and macOS
//  beeped.
//
//  So the missing half of the space bar is written down the same way the
//  press was: a pure function of the facts the view knows, answered before
//  anything is done, so the decision can be read and tested without a window,
//  a key event or a running app.
//
//  ## The two facts, and what each one refuses
//
//  * `offersRunner` is `NavigationFailure.offersPearlRunner` again, and it is
//    the same fact for the same reason: the offline screen is a wait, every
//    other family is an instruction. An instruction screen has no game to
//    start, so it has no business holding the keyboard — space there scrolls
//    the column, exactly as it always did.
//  * `textIsBeingEdited` is somebody typing, in this window, right now. A
//    failure that arrives while the user is mid-word in the omnibox must not
//    swallow the rest of the word. The runner asks for the keyboard; it never
//    takes it out of a text field.
//
//  Nothing else is asked. In particular, "something else holds the keyboard"
//  is deliberately NOT a refusal: on the offline screen the something else is
//  the web view the failure surface is drawn over, and the whole point is to
//  take it from there. Which is also why the taking is reversible — see
//  `PearlKeyboardHandover`, which gives it back when the screen goes away.
//

nonisolated enum PearlKeyboardClaim {

    /// - Parameters:
    ///   - offersRunner: whether this failure screen carries the game at all.
    ///   - textIsBeingEdited: whether the keyboard is currently inside
    ///     something the user is typing in.
    static func mayClaim(offersRunner: Bool, textIsBeingEdited: Bool) -> Bool {
        guard offersRunner else { return false }
        guard !textIsBeingEdited else { return false }
        return true
    }
}
