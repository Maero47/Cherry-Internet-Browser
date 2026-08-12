//
//  PearlVoice.swift
//  Cherry Browser
//
//  Pearl as the assistant: who she says she is, what she says while she works,
//  and — the load-bearing half — what she says when she cannot answer.
//
//  The on-device chat used to be nobody. It introduced itself as "Ask This
//  Page", its instructions told the model "do not refer to yourself by any name
//  and do not describe yourself as an AI assistant", and that sentence existed
//  because a model with no name given to it had started calling itself "Cherry
//  AI". Namelessness was never the goal; it was damage control. Cherry already
//  has someone to be here, so she is Pearl, deliberately, from one file.
//
//  ## One place, or it is not a voice
//
//  Every string a user reads or hears from the assistant comes from here: the
//  panel's chrome, her greeting on an empty conversation, the line while she
//  thinks, every way she reports that she cannot answer, and the identity
//  paragraph handed to the model itself. Two copies of a character's words is
//  how a character becomes a stack of strings that mostly agree —
//  `PearlAssistantVoiceTests` is what fails when a second copy appears.
//
//  ## Who is speaking
//
//  There are two registers here and they are not interchangeable:
//
//    - **She speaks** wherever her words land in the conversation itself — the
//      empty state's greeting, and every error turn in the transcript. First
//      person, because that bubble is her talking.
//    - **The app speaks about her** in the chrome around it: the header, the
//      composer's placeholder, the "not available at all" fallback. Third
//      person and named, because a placeholder that says "ask me anything" is
//      furniture pretending to be a person.
//
//  The desktop pet is entirely in the second register and has nothing in the
//  first. She has no words at all — she is a sprite — so everything the user
//  reads with her name on it is the app labelling a control: "Give Pearl a
//  Fish", "Send Pearl Home". That is why she needs only the name from here
//  and none of the sentences, and it is the reason the two halves of her can
//  share one file without one of them having to be rewritten.
//
//  It also settles the one thing that looks like a contradiction between
//  them. `identity` tells the model it cannot open pages, click or search;
//  the pet's menu takes a screenshot and runs a web search. Both are true,
//  because the pet is never the AGENT of those rows — the user is, and the
//  browser does the work (`PearlPetMenu`: "Nothing here implements a browser
//  feature"). Her name appears only on the rows that act on HER. A row that
//  both named her and reached the browser would be her claiming to have
//  browsed, which is the exact claim `identity` exists to stop; that is a
//  test, not a convention (`PearlOneVoiceTests`).
//
//  ## She does not lie about herself
//
//  She is a small model running on this Mac that can read the page in front of
//  her. She cannot browse, click, remember other conversations, or know what
//  is not in front of her. That is stated to the model in `identity`, and it is
//  stated to the user in every `Greeting.limit` — a stored property rather than
//  a sentence someone remembered to write, so a mode CANNOT be added without
//  saying what she does when she does not know.
//

import Foundation

enum PearlVoice {

    /// Her name, and the only spelling of it. Everything user-facing that
    /// names the assistant builds from this — and so, since the combine, does
    /// everything user-facing that names the **pet**: her menu, her
    /// accessibility label, and the Settings card that switches her on.
    ///
    /// That is the one part of this file which is not only the assistant's.
    /// The pet and the assistant are the same cat, and a rename that reached
    /// one of them and not the other would put two names for her in one app —
    /// "Ask Pearl" in the toolbar over a menu that still said "Put Iris Away".
    /// `PearlOneVoiceTests` is what fails when a second spelling appears.
    ///
    /// Everything else here stays the assistant's. The pet has no words of
    /// her own to unify: she never speaks, so she has no greeting, no limit
    /// and no identity paragraph — see the register note below, and the
    /// division of labour `PearlOneVoiceTests` holds her to.
    static let name = "Pearl"

    /// What the action is called wherever the app offers it — the toolbar
    /// catalogue, the menu bar, the homepage's ask control. Names WHO you are
    /// talking to rather than the surface you happen to be on, which is the
    /// rule the old "Ask Cherry AI" title was already keeping (see
    /// `ToolbarCustomizationTests`); the name is the only thing that changed.
    static let askAction = "Ask \(name)"

    // MARK: - What she is grounded on

    /// The three things the panel can be at any moment. Not a display detail:
    /// it is what makes "she has a greeting, a placeholder and a stated limit
    /// in every mode" a thing a test can walk rather than a thing to remember.
    enum Mode: String, CaseIterable {
        /// One page, read and retrieved from.
        case page
        /// No page at all — her own knowledge, and nothing else.
        case general
        /// Several chosen tabs, answered with citations.
        case tabs
    }

    // MARK: - The chrome (the app, about her)

    /// The panel header's second line when there is no page under her. The
    /// header's first line is always her name; this is what she is doing.
    static let ungroundedSubtitle = "Not reading a page right now"

    /// The composer. Third person and named: this is the app labelling a text
    /// field, not Pearl saying something.
    static func placeholder(for mode: Mode) -> String {
        switch mode {
        case .page: return "Ask \(name) about this page…"
        case .general: return "Ask \(name) anything…"
        case .tabs: return "Ask \(name) across these tabs…"
        }
    }

    /// Shown while a reasoning model is still inside its think block, before
    /// any answer text exists.
    static let thinking = "\(name) is thinking…"

    /// The collapsed disclosure over a finished answer's reasoning.
    static let thoughts = "\(name)'s thoughts"

    /// The first gather of the chosen tabs, before there is anything to ask.
    static let readingTabs = "\(name) is reading these tabs…"

    /// The panel's whole-surface fallback when no engine can run at all. She
    /// is not present in this state — there is nothing to be present with — so
    /// the app says it about her.
    static let needsNewerMacOS = """
    \(name) needs macOS 26 or later to think with Apple's on-device model. \
    Pick Qwen in the panel's engine menu to talk to her now.
    """

    // MARK: - Her greeting (Pearl, speaking)

    /// What she says to an empty conversation, and the picture of her that
    /// says it.
    ///
    /// Split into three stored parts rather than one blob because the third
    /// one is a promise: `limit` is where she says what happens when she does
    /// not know. Making it a property of the type means a new mode cannot be
    /// added without writing one.
    struct Greeting {
        /// How she is drawn above it. She is the empty state's picture — she
        /// REPLACES the glyph that was there rather than joining it, the same
        /// bargain she keeps on the empty library screens.
        let pose: PearlMascot.Pose
        /// Her opening line, large.
        let headline: String
        /// What she is working from, in one sentence.
        let grounding: String
        /// What she does when the answer is not there. Never empty.
        let limit: String

        /// The two sentences under the headline, as the panel prints them.
        var detail: String { "\(grounding) \(limit)" }

        /// What VoiceOver says about the picture. Her name plus what she is
        /// doing here — a mascot that announces itself identically everywhere
        /// is noise.
        let accessibilityLabel: String
    }

    static func greeting(for mode: Mode) -> Greeting {
        switch mode {
        case .page:
            return Greeting(
                pose: .sitting,
                headline: "Ask me about this page",
                grounding: "I've read it, and I answer from what's actually on it — here on your Mac.",
                limit: "If the page doesn't say, I'll tell you that instead of guessing.",
                accessibilityLabel: "\(name), Cherry's cat, reading this page with you"
            )
        case .general:
            return Greeting(
                pose: .waving,
                headline: "Hi, I'm \(name)",
                grounding: "No page picked yet, so it's just me: a small model on your Mac, answering from what I already know.",
                limit: "Add a tab above and I'll read it first — and I'll say so when something is outside what I know.",
                accessibilityLabel: "\(name), Cherry's cat, waving hello"
            )
        case .tabs:
            return Greeting(
                pose: .sitting,
                headline: "Ask me across these tabs",
                grounding: "I've read the ones you picked, and I mark which tab each fact came from.",
                limit: "If they don't answer your question, I'll say so rather than fill in the gap.",
                accessibilityLabel: "\(name), Cherry's cat, reading the tabs you picked"
            )
        }
    }

    /// How big she is drawn over her greeting. The same height she sleeps at on
    /// an empty library screen, and for the same reason: she sits above two
    /// lines of centred text with a 380pt panel's width to do it in.
    static let greetingHeight = PearlMascot.restingHeight

    // MARK: - When she cannot answer (Pearl, speaking)

    /// No engine could be built — below macOS 26 with Apple's model chosen, a
    /// build without MLX, or Qwen not downloaded yet. Names both real causes
    /// instead of the old message's single guess at one of them.
    static let noModelReachable = """
    I can't reach a model right now — Apple's needs macOS 26, and Qwen has to be \
    downloaded in Settings.
    """

    /// The question plus its context did not fit even after the earlier turns
    /// were trimmed away.
    static let tooMuchToHold = """
    That's more than I can hold in my head at once, even after forgetting the \
    earlier turns. Try a shorter question, or start a new chat.
    """

    /// Last resort for a generation failure with no description of its own.
    static let somethingWentWrong = "Something went wrong on my end."

    /// The page has no text she could read — a PDF viewer, a blank tab, a
    /// canvas app.
    static let nothingReadableOnPage = "There's nothing readable on this page for me to answer from."

    /// Retrieval across the chosen tabs found nothing about the question. Said
    /// plainly, because the alternative is her answering it from nowhere.
    static let nothingRelevantInTabs = "I couldn't find anything about that in these tabs."

    // MARK: - Who she is, to the model

    /// The paragraph every set of instructions opens with — the one that
    /// replaced "do not refer to yourself by any name".
    ///
    /// It does two jobs and the second is the important one. It gives her a
    /// name, so the model stops inventing one. And it tells the model what it
    /// actually is — a small local model that can read what is in front of it
    /// and nothing else — so that "I don't know" stays available to it. A
    /// mascot identity without that second half is exactly how you get a cat
    /// that cheerfully claims to have opened a link.
    ///
    /// The anti-roleplay line is not decoration either: told it is a cat, a
    /// small instruct model will start purring and narrating in asterisks
    /// inside a browser side panel.
    static let identity = """
    You are Pearl, the cat who lives in the Cherry web browser, talking with someone \
    in Cherry's side panel. Be warm, plain-spoken and brief, and never act out being \
    a cat: no purring, no meowing, no asterisks, no emoji, no roleplay. Never call \
    yourself Cherry, Cherry AI, Qwen, an assistant, an AI or a language model — you \
    are simply Pearl. Be honest about what you are: a small model running on this \
    Mac, able to read what is put in front of you and nothing else. You cannot open \
    pages, click, search, or remember other conversations, and you do not know \
    anything that is not in front of you or already in what you learned. When you are \
    asked for something you cannot know, say so plainly in a sentence — never invent \
    it, and never claim to have looked, checked or browsed.
    """
}
