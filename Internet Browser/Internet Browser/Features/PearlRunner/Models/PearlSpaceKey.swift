//
//  PearlSpaceKey.swift
//  Cherry Browser
//
//  Who the space bar belongs to on a failure screen.
//
//  ## Why this is a value and not an `if` inside the key handler
//
//  Space is the most contested key in a browser. It scrolls the page, it
//  presses whatever button holds the keyboard, and — on exactly one screen —
//  it is the thing that puts Pearl on the ground running. A rule that decides
//  between those cannot live inside a SwiftUI `onKeyPress` closure, because
//  nothing in this project can reach it: the test host cannot activate the app
//  or post a trusted key event, so a rule expressed only in a view is a rule
//  that ships unverified.
//
//  So the decision is a pure function of the four facts the view knows, and it
//  answers with who the press belongs to. The view's whole job is to obey the
//  answer and to hand the key back untouched — `.ignored`, on up the responder
//  chain — whenever that answer is `notOurs`.
//
//  ## The two guards, and what each one refuses
//
//  * `offersRunner` is `NavigationFailure.offersPearlRunner`: the offline
//    screen is a wait, every other family is an instruction. Space on an
//    instruction screen scrolls it, as it always did.
//  * `runnerHasKeyboardFocus` is the runner's own slot holding focus. It is
//    what keeps this from being a global hotkey: if the omnibox, a sheet, a
//    find bar or the page itself has the keyboard, the runner never sees the
//    press, and if a press reaches it anyway it still refuses.
//
//  Past those two, the answer is the state of the run: nothing yet means
//  start, a run in flight means jump and nothing else, a crash screen means
//  run again.
//

nonisolated enum PearlSpaceKey {

    /// What one space bar press means right now.
    enum Meaning: Equatable {
        /// Not the runner's key. It belongs to the page, the scroll view, or
        /// whatever else has the keyboard; hand it straight back.
        case notOurs
        /// The offline screen with nothing running yet: start the run. This is
        /// the Chrome-dino path — no button is pressed first.
        case start
        /// A run is in flight: space is the jump, and only the jump.
        case jump
        /// The crash screen: space runs again.
        case restart
    }

    /// - Parameters:
    ///   - offersRunner: whether this failure screen carries the game at all.
    ///   - runnerHasKeyboardFocus: whether the runner's own slot holds the
    ///     keyboard. False means something else does, and the press is theirs.
    ///   - hasStarted: whether the player has ever asked for a run here.
    ///   - phase: the run's phase, which only matters once it has started.
    static func meaning(
        offersRunner: Bool,
        runnerHasKeyboardFocus: Bool,
        hasStarted: Bool,
        phase: PearlRunnerGame.Phase
    ) -> Meaning {
        guard offersRunner else { return .notOurs }
        guard runnerHasKeyboardFocus else { return .notOurs }
        guard hasStarted else { return .start }
        return phase == .crashed ? .restart : .jump
    }
}
