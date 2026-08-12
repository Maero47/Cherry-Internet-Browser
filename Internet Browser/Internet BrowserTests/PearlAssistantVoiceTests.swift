//
//  PearlAssistantVoiceTests.swift
//  Internet BrowserTests
//
//  Pearl as the assistant: that she is one character rather than a set of
//  strings that currently agree, and that being a character has not made her
//  dishonest.
//
//  Two claims, and both of them rot quietly if nothing checks them:
//
//    1. **She is written in one place.** The panel, the two chat sessions, the
//       inference service and every entry point that offers her get her name
//       and her words from `PearlVoice`. The failure mode this catches is the
//       ordinary one — somebody adds a mode, a state or a menu item and types
//       "Ask Pearl" into it — after which her name has two spellings and her
//       introduction has two versions.
//
//    2. **She still says when she cannot answer.** A mascot is exactly the kind
//       of change that eats a refusal: the prompts get rewritten for warmth,
//       the grounding rules go with them, and a small model that has just been
//       told it is a friendly cat starts making things up. So the refusal
//       sentences in the instructions are pinned, every greeting must carry a
//       stated limit, and the no-engine path is driven for real and checked to
//       produce her admission rather than an answer.
//
//  The source-tree claims come through `AppSourceTree`, which skips (with a
//  reason) rather than parking the suite when the checkout is TCC-gated.
//

import AppKit
import SwiftUI
import XCTest
@testable import Cherry

/// One of the app's sources with its comment lines dropped.
///
/// Every claim in this file is about what the app SAYS, and a comment is the
/// one place allowed to quote what it no longer says — the retired anonymity
/// instruction is written out verbatim in `PageAIService`'s own doc comment,
/// beside the identity that replaced it. Scanning raw text would make that
/// history read as a live prompt (and, the other way round, would let a
/// commented-out refusal count as a refusal that ships).
private func code(of path: String) throws -> String {
    try AppSourceTree.read(path)
        .split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")
}

/// Every value of type `T` inside a SwiftUI view value, however deep — the
/// codebase's established way of asking what a view is made of.
private func collectValues<T>(_ type: T.Type, in value: Any, depth: Int = 0) -> [T] {
    if let hit = value as? T { return [hit] }
    guard depth < 60 else { return [] }
    return Mirror(reflecting: value).children.flatMap {
        collectValues(type, in: $0.value, depth: depth + 1)
    }
}

// MARK: - One voice, one place

final class PearlVoiceSingleSourceTests: XCTestCase {

    /// Everywhere the ASSISTANT is named to a user or instructed as a model.
    /// A new surface that speaks as her belongs on this list.
    ///
    /// Scoped to the assistant on purpose: her other selves — the desktop pet,
    /// the setup wizard, the runner — are older features with their own copy,
    /// and dragging them behind this file would be a rename of three features
    /// wearing a test's clothes. (`Features/Settings` is off the list for
    /// exactly that reason: its Pearl rows are the pet's, and the one line
    /// there that is about the assistant reads `PearlVoice.name`.)
    private static let surfaces = [
        "Features/AI/Views/AskThisPagePanel.swift",
        "Features/AI/Services/PageAIService.swift",
        "Features/AI/Services/PageChatSession.swift",
        "Features/AI/Services/TabsResearchSession.swift",
        "Features/Navigation/Models/ToolbarButtonID.swift",
        "Features/Navigation/Views/NavigationBarView.swift",
        "Features/HomePage/Views/HomePageView.swift",
        "Features/Browser/Views/CommandPaletteView.swift",
        "Internet_BrowserApp.swift",
    ]

    /// Her name reaches those files as a SYMBOL and never as text. Anything
    /// else means a second spelling of her exists — which is how "Ask Pearl",
    /// "Ask pearl" and "Ask Pearl AI" end up on three different surfaces.
    ///
    /// Dies on: a literal `"…Pearl…"` typed into a placeholder, a menu title,
    /// an empty state, an error turn or a set of model instructions.
    func testHerNameIsSpelledInExactlyOneFile() throws {
        for path in Self.surfaces {
            let source = try AppSourceTree.read(path)
            for (number, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                // Comments talk ABOUT her by name on purpose.
                let code = String(line).components(separatedBy: "//").first ?? ""
                var index = code.startIndex
                while let found = code.range(of: PearlVoice.name, range: index..<code.endIndex) {
                    let next = found.upperBound < code.endIndex ? code[found.upperBound] : " "
                    XCTAssertTrue(next.isLetter,
                                  """
                                  \(path):\(number + 1) writes her name out instead of \
                                  reading it from PearlVoice: \(code.trimmingCharacters(in: .whitespaces))
                                  """)
                    index = found.upperBound
                }
            }
        }
    }

    /// The instruction that this whole change replaced. It existed because a
    /// nameless model had started calling itself "Cherry AI"; leaving it in
    /// beside her identity would be two answers to "who are you" inside one
    /// prompt, and the older, blunter one usually wins.
    ///
    /// Dies on: a prompt rewrite that reinstates the anonymity clause.
    func testNoInstructionStillTellsTheModelToBeNobody() throws {
        let source = try code(of: "Features/AI/Services/PageAIService.swift")
        for banned in ["Do not refer to yourself by any name", "describe yourself as an AI assistant"] {
            XCTAssertFalse(source.contains(banned),
                           "the anonymity instruction is back in the prompts: \(banned)")
        }
    }

    /// Every set of instructions OPENS with the same identity paragraph, taken
    /// from `PearlVoice`. Four hand-written identities are four identities,
    /// and they drift one prompt-tweak at a time.
    ///
    /// Dies on: a fifth instruction block that forgets her, or one of these
    /// four growing its own description of who she is.
    func testEveryInstructionBlockOpensWithTheOneIdentity() throws {
        let source = try code(of: "Features/AI/Services/PageAIService.swift")
        let blocks = ["chatInstructionsPrefix", "generalChatInstructions",
                      "researchInstructions", "qaInstructions"]

        for block in blocks {
            XCTAssertTrue(source.contains("static let \(block) = \"\"\"\n    \\(PearlVoice.identity)"),
                          "\(block) does not open with PearlVoice.identity")
        }
        XCTAssertEqual(source.components(separatedBy: "\\(PearlVoice.identity)").count - 1, blocks.count,
                       "PearlVoice.identity is used somewhere other than the \(blocks.count) instruction blocks")
    }

    /// She is drawn twice in the panel — the header's avatar and the empty
    /// conversation's greeting — and NOWHERE inside the bubble builder. A face
    /// on every assistant message is the same face forty times: noise, and the
    /// fastest way to make a character annoying.
    ///
    /// Dies on: a portrait added beside `chatBubble`'s assistant case.
    func testSheIsNeverDrawnBesideAMessage() throws {
        let source = try code(of: "Features/AI/Views/AskThisPagePanel.swift")
        XCTAssertEqual(source.components(separatedBy: "PearlPortrait(").count - 1, 2,
                       "the panel draws Pearl a number of times that is not two")

        let bubbleBuilder = try XCTUnwrap(
            source.components(separatedBy: "private func chatBubble(for turn: PageChatTurn)").last?
                .components(separatedBy: "private func copyButton").first,
            "the bubble builder moved; this test no longer reads it"
        )
        XCTAssertFalse(bubbleBuilder.contains("PearlPortrait"),
                       "Pearl turned up beside every message")
    }
}

// MARK: - What she says, per mode

final class PearlVoiceCopyTests: XCTestCase {

    /// Each mode has its own placeholder, and each one names her rather than
    /// speaking as her: a text field that says "ask me anything" is furniture
    /// pretending to be a person.
    func testEveryModeHasItsOwnPlaceholderNamingHer() {
        let placeholders = PearlVoice.Mode.allCases.map { PearlVoice.placeholder(for: $0) }
        XCTAssertEqual(Set(placeholders).count, PearlVoice.Mode.allCases.count,
                       "two modes share a placeholder")
        for placeholder in placeholders {
            XCTAssertTrue(placeholder.contains(PearlVoice.name), "\(placeholder) does not name her")
        }
    }

    /// The honesty half of her greeting, and the reason `limit` is a stored
    /// property: a mode cannot be added without writing the sentence that says
    /// what she does when she does not know.
    ///
    /// Dies on: a new mode whose greeting promises answers and nothing else.
    func testEveryGreetingStatesWhatSheDoesWhenSheCannotAnswer() {
        var limits: Set<String> = []
        for mode in PearlVoice.Mode.allCases {
            let greeting = PearlVoice.greeting(for: mode)
            XCTAssertFalse(greeting.headline.isEmpty, "\(mode) has no opening line")
            XCTAssertFalse(greeting.grounding.isEmpty, "\(mode) does not say what she is reading")
            XCTAssertFalse(greeting.limit.isEmpty, "\(mode) does not say what she does when she can't answer")
            XCTAssertTrue(greeting.limit.contains("I'll say") || greeting.limit.contains("I'll tell"),
                          "\(mode)'s limit doesn't promise she'll say so: \(greeting.limit)")
            XCTAssertTrue(greeting.detail.contains(greeting.grounding) && greeting.detail.contains(greeting.limit),
                          "\(mode)'s printed detail drops one of its halves")
            limits.insert(greeting.limit)
        }
        XCTAssertEqual(limits.count, PearlVoice.Mode.allCases.count,
                       "two modes make the same promise about different grounding")
    }

    /// She speaks in the conversation (first person) and is spoken about in
    /// the chrome (third person, named). Mixing the two is what makes a
    /// character read as marketing copy.
    func testSheSpeaksInHerGreetingAndIsNamedInTheChrome() {
        for mode in PearlVoice.Mode.allCases {
            let greeting = PearlVoice.greeting(for: mode)
            XCTAssertTrue(greeting.grounding.contains("I") || greeting.grounding.contains("me"),
                          "\(mode)'s greeting is not in her voice")
            XCTAssertFalse(greeting.grounding.contains("\(PearlVoice.name) "),
                           "\(mode)'s greeting has her talking about herself in the third person")
        }
        for chrome in [PearlVoice.thinking, PearlVoice.thoughts,
                       PearlVoice.readingTabs, PearlVoice.needsNewerMacOS] {
            XCTAssertTrue(chrome.contains(PearlVoice.name), "the chrome stopped naming her: \(chrome)")
        }
    }

    /// The poses her greeting asks for are drawings the app actually ships,
    /// and she is drawn at a size a 380pt panel can hold.
    func testHerGreetingPosesResolveOutOfTheShippedCatalog() {
        for mode in PearlVoice.Mode.allCases {
            let pose = PearlVoice.greeting(for: mode).pose
            XCTAssertNotNil(NSImage(named: pose.assetName),
                            "\(mode) greets with a pose the catalog does not have")
        }
        XCTAssertEqual(PearlVoice.greetingHeight, PearlMascot.restingHeight)
        XCTAssertLessThan(PearlVoice.greetingHeight, 380 - 40,
                          "she is wider than the panel she greets from")
        XCTAssertLessThan(PearlMascot.avatarHeight, PearlVoice.greetingHeight,
                          "the header avatar is not smaller than the greeting")
        XCTAssertLessThanOrEqual(PearlMascot.avatarHeight, 34,
                                 "at this size the header avatar is a second portrait, not an identifier")
    }
}

// MARK: - Who she tells the model she is

final class PearlModelIdentityTests: XCTestCase {

    /// The paragraph handed to the model names her, and — the load-bearing
    /// half — tells it what it actually is, so that "I don't know" stays
    /// available to it. An identity without the second half is how you get a
    /// cat that cheerfully claims to have opened a link.
    func testTheIdentityNamesHerAndKeepsHerHonest() {
        let identity = PearlVoice.identity

        XCTAssertTrue(identity.contains("You are Pearl"), "the model isn't told who it is")
        XCTAssertTrue(identity.contains("small model running on this Mac"),
                      "the model isn't told what it is")
        XCTAssertTrue(identity.contains("never invent"), "nothing forbids invention")
        XCTAssertTrue(identity.contains("cannot know"), "she is never told to admit not knowing")
        XCTAssertTrue(identity.contains("never claim to have looked, checked or browsed"),
                      "nothing stops her claiming to have done things she cannot do")

        // The names she used to reach for when nobody gave her one.
        for name in ["Cherry AI", "Qwen", "an assistant", "a language model"] {
            XCTAssertTrue(identity.contains(name),
                          "\(name) is not in the list of things she must not call herself")
        }

        // Told it is a cat, a small instruct model starts purring in asterisks.
        for tell in ["no purring", "no asterisks", "no roleplay"] {
            XCTAssertTrue(identity.contains(tell), "the anti-roleplay rule lost: \(tell)")
        }
    }

    /// Her identity did not replace the grounding rules. These three sentences
    /// are the ones that make her say "it isn't in there" instead of answering
    /// from nowhere, one per grounded instruction block.
    ///
    /// Dies on: a personality rewrite that carries the refusals away with it.
    func testTheGroundedInstructionsStillRefuseWhatTheyCannotSee() throws {
        let source = try code(of: "Features/AI/Services/PageAIService.swift")
        let refusals = [
            "If the answer isn't in the provided content, say so plainly",
            "If the excerpts don't contain the answer, say",
            "say plainly that the page doesn't contain that information",
        ]
        for refusal in refusals {
            XCTAssertTrue(source.contains(refusal), "a grounding refusal is gone: \(refusal)")
        }
    }
}

// MARK: - The cannot-answer path, driven

@MainActor
final class PearlCannotAnswerTests: XCTestCase {

    /// A chat with no engine behind it — below macOS 26 on Apple's model, a
    /// build without MLX, Qwen not downloaded — answers NOTHING and says so in
    /// her voice. The transcript must hold her admission and no assistant
    /// bubble at all: an empty bubble, or a cheerful one, is the exact failure
    /// this whole file exists to prevent.
    func testAChatWithNoEngineSaysSoInsteadOfAnswering() {
        let session = PageChatSession()
        session.send("what does this page say about pricing?")

        XCTAssertEqual(session.turns.count, 1, "she started a conversation she cannot have")
        XCTAssertEqual(session.turns.first?.role, .error)
        XCTAssertEqual(session.turns.first?.text, PearlVoice.noModelReachable)
        XCTAssertFalse(session.turns.contains { $0.role == .assistant },
                       "an assistant turn exists with no engine to have written it")
        XCTAssertFalse(session.isResponding)
    }

    /// And what she says there is honest about the two real reasons, rather
    /// than the single guess ("requires macOS 26") the panel used to make at
    /// whichever one it wasn't.
    func testHerNoEngineLineNamesBothRealCauses() {
        XCTAssertTrue(PearlVoice.noModelReachable.contains("macOS 26"))
        XCTAssertTrue(PearlVoice.noModelReachable.contains("Qwen"))
        XCTAssertFalse(PearlVoice.noModelReachable.contains("Ask This Page"),
                       "the old brand is still in her mouth")
    }

    /// Blank input is not a question, so it is not something she failed to
    /// answer: nothing is said and nothing is appended.
    func testAnEmptyQuestionProducesNoTurnAtAll() {
        let session = PageChatSession()
        session.send("   \n ")
        XCTAssertTrue(session.turns.isEmpty)
    }
}

// MARK: - Where she is drawn in the panel

@MainActor
final class PearlInTheChatPanelTests: XCTestCase {

    private func panel() -> AskThisPagePanel {
        AskThisPagePanel(
            pageTitle: "", pageText: "",
            tabManager: TabManager(createDefaultTab: false),
            onDismiss: {}
        )
    }

    /// The header carries exactly one Pearl, at avatar size, whatever the
    /// panel is showing underneath — including the "no engine at all"
    /// fallback, where she is the only thing identifying whose panel this is.
    ///
    /// Dies on: the header falling back to the `sparkles` glyph it replaced,
    /// or a second portrait appearing beside it.
    func testTheHeaderAlwaysCarriesExactlyOnePearl() {
        let portraits = collectValues(PearlPortrait.self, in: panel().body)
        let avatars = portraits.filter { $0.height == PearlMascot.avatarHeight }

        XCTAssertEqual(avatars.count, 1, "the panel header draws a number of Pearls that is not one")
        XCTAssertEqual(avatars.first?.pose, .sitting)
        for portrait in portraits where portrait.height != PearlMascot.avatarHeight {
            XCTAssertEqual(portrait.height, PearlVoice.greetingHeight,
                           "a Pearl is drawn at a size that is neither the avatar nor the greeting")
        }
    }

    /// Her greeting, in every mode: one portrait — REPLACING the glyph each
    /// empty state used to head with, not joining it — over the two lines she
    /// actually says.
    func testHerGreetingIsHerPortraitAndHerWordsInEveryMode() throws {
        for mode in PearlVoice.Mode.allCases {
            let greeting = PearlVoice.greeting(for: mode)
            let body = PearlGreeting(mode: mode).body

            let portraits = collectValues(PearlPortrait.self, in: body)
            XCTAssertEqual(portraits.count, 1, "\(mode)'s greeting draws Pearl \(portraits.count) times")
            XCTAssertEqual(portraits.first?.pose, greeting.pose)
            XCTAssertEqual(portraits.first?.height, PearlVoice.greetingHeight)
            XCTAssertNotNil(portraits.first?.artwork, "\(mode)'s greeting resolved no artwork")

            let strings = collectValues(String.self, in: body)
            XCTAssertTrue(strings.contains(greeting.headline), "\(mode)'s greeting lost her opening line")
            XCTAssertTrue(strings.contains(greeting.detail), "\(mode)'s greeting lost her two sentences")

            // The glyphs the empty states used to lead with, gone rather than
            // demoted to sit beside her.
            for glyph in ["bubble.left.and.bubble.right", "square.stack.3d.up"] {
                XCTAssertFalse(strings.contains(glyph), "\(mode)'s greeting still leads with a glyph")
            }
        }
    }
}
