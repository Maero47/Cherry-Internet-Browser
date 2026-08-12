//
//  PearlOneVoiceTests.swift
//  Internet BrowserTests
//
//  The pet and the assistant are the same cat, and this is what says so.
//
//  Two rounds arrived at Pearl from opposite ends. `pearl-assistant` gave the
//  on-device chat a name and put every word of it in one file, `PearlVoice`,
//  with a test that holds the assistant's own surfaces to reading the name as
//  a symbol. That test's list is deliberately short, and its comment says why:
//
//      Scoped to the assistant on purpose: her other selves — the desktop pet,
//      the setup wizard, the runner — are older features with their own copy…
//
//  `pearl-pet-plus` then grew the pet's menu from two rows to six, and four of
//  the new rows spell "Pearl" out in full. Separately, each is fine. In one
//  tree they are two answers to "what is this cat called", and a rename would
//  only ever reach one of them: "Ask Pearl" in the toolbar over a menu that
//  still said "Put Iris Away". So the pet's surfaces join the rule here.
//
//  ## The name is not the whole seam
//
//  The harder half is her MANNER, and it has one real point of friction.
//  `PearlVoice.identity` is the paragraph that keeps the assistant honest —
//  "You cannot open pages, click, search" — and it exists because a nameless
//  model had started inventing both a name and a browsing history for itself.
//  Meanwhile the pet's menu takes a screenshot and runs a web search.
//
//  Those two only contradict each other if Pearl is the agent of the menu's
//  rows, and she is not: the user is, and `PearlPetMenu` calls the methods
//  `BrowserViewModel` already had. What makes that visible rather than merely
//  arguable is where her name falls. It is on the rows that act on HER — a
//  fish, her size, her way home, her off switch — and on none of the rows that
//  reach the browser. `testHerNameIsOnlyOnTheRowsThatActOnHer` is that rule,
//  and a row like "Ask Pearl to Take a Screenshot" is what it is for.
//
//  ## What is deliberately still outside the rule
//
//  The setup wizard, the library's sleeping cat and the runner's mark still
//  write her name out. They are not in this combine, nothing in it touched
//  them, and the assistant round's reason for leaving them alone has not
//  changed. What has changed is that the two features THIS branch merged now
//  agree, which is what was asked. The list below is the promise, and it is
//  the thing to extend when one of those three is next opened.
//

import AppKit
import XCTest
@testable import Cherry

@MainActor
private final class VoiceHostSpy: PearlPetHost {
    var reached: [String] = []
    var selection: String?

    func captureScreenshot() { reached.append("screenshot") }
    func newTab(url: URL?) { reached.append("newTab") }
    func performSearch(_ query: String) { reached.append("search") }
    func readPageSelection(_ completion: @escaping (String?) -> Void) {
        reached.append("selection")
        completion(selection)
    }
}

// MARK: - One spelling of her name

@MainActor
final class PearlOneVoiceTests: XCTestCase {

    /// The pet's own surfaces, plus the Settings card that switches her on.
    ///
    /// `Features/Settings` was off the assistant's list because its Pearl rows
    /// were the pet's copy rather than the assistant's. Now that the pet reads
    /// the name, that reason is gone and the file joins.
    private static let petSurfaces = [
        "Features/PearlPet/Views/PearlPetView.swift",
        "Features/PearlPet/Views/PearlPetOverlay.swift",
        "Features/PearlPet/Models/PearlPetMenu.swift",
        "Features/PearlPet/Models/PearlPetSize.swift",
        "Features/Settings/Views/GeneralSettingsView.swift",
    ]

    /// Her name reaches the pet's code as a symbol and never as text — the
    /// same rule the assistant's surfaces are held to, narrowed to the place
    /// text lives.
    ///
    /// The assistant's version reads whole lines of code, which it can afford
    /// because none of its surfaces has an identifier ending in her name. The
    /// pet's do: `isOnPearl` is the per-pixel hit test this whole feature
    /// stands on. So this reads STRING LITERALS, which is what a user can
    /// actually end up looking at. Inside one, an occurrence is still allowed
    /// only where it is part of a longer word — `\(PearlVoice.name)` in an
    /// interpolation, `showPearlPet` in a defaults key — and never as her name
    /// standing alone.
    ///
    /// Dies on: `"Give Pearl a Fish"`, `"Pearl's Size"`, `"Send Pearl Home"`,
    /// `"Put Pearl Away"`, `setAccessibilityLabel("Pearl")` or the Settings
    /// card's title being typed back in as text.
    func testThePetSpellsHerNameNowhereOfItsOwn() throws {
        for path in Self.petSurfaces {
            let source = try AppSourceTree.read(path)
            for (number, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                // Comments talk about her by name on purpose, as they do
                // everywhere else in this feature.
                let code = String(line).components(separatedBy: "//").first ?? ""
                for text in Self.stringLiterals(in: code) {
                    var index = text.startIndex
                    while let found = text.range(of: PearlVoice.name, range: index..<text.endIndex) {
                        let next = found.upperBound < text.endIndex ? text[found.upperBound] : " "
                        XCTAssertTrue(
                            next.isLetter,
                            """
                            \(path):\(number + 1) writes her name out instead of reading it \
                            from PearlVoice: "\(text)"
                            """
                        )
                        index = found.upperBound
                    }
                }
            }
        }
    }

    /// The double-quoted spans of one line of code, escapes honoured. Crude on
    /// purpose: it is reading Swift written by hand, not parsing it, and the
    /// only thing that matters is that a literal is never mistaken for the
    /// code around it.
    private static func stringLiterals(in code: String) -> [String] {
        var found: [String] = []
        var current: String?
        var escaped = false
        for character in code {
            if var open = current {
                if escaped {
                    open.append(character)
                    current = open
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                    current = open
                } else if character == "\"" {
                    found.append(open)
                    current = nil
                } else {
                    open.append(character)
                    current = open
                }
            } else if character == "\"" {
                current = ""
            }
        }
        // An unterminated quote is a multi-line literal's opening line; take
        // what is on it rather than dropping the line.
        if let open = current { found.append(open) }
        return found
    }

    /// The one preference key that must NOT follow a rename. It is on disk in
    /// every existing install, and a key built out of `PearlVoice.name` would
    /// silently switch the pet off for everybody the day she is renamed.
    ///
    /// Dies on: `showPearlPet` being rewritten as `"show\(PearlVoice.name)Pet"`.
    func testHerStoredKeyIsNotBuiltFromHerName() throws {
        let source = try AppSourceTree.read("Features/Settings/ViewModels/SettingsManager.swift")
        XCTAssertTrue(
            source.contains(#"static let showPearlPet = "showPearlPet""#),
            "the pet's defaults key is no longer the literal it has to stay"
        )
    }

    /// And the two features really do read the same symbol — the source rule
    /// above says "no literal", this says "and the value that arrived is
    /// hers". Together they are what makes a rename reach both halves.
    ///
    /// Dies on: the pet naming her from a constant of its own that happens to
    /// hold the same word today.
    func testTheMenuAndTheAssistantAreNamingTheSameCat() {
        let view = PearlPetView()
        view.frame = CGRect(origin: .zero, size: PearlPetPlacement.hostSize(for: .default))
        let titles = view.menuItems(selection: nil, host: VoiceHostSpy())
            .filter { !$0.isSeparator }
            .map(\.title)

        let named = titles.filter { $0.contains(PearlVoice.name) }
        XCTAssertEqual(
            named.count, 4,
            "the rows that name her are \(named) — expected the fish, her size, "
                + "her way home and her off switch"
        )
        XCTAssertEqual(view.accessibilityLabel(), PearlVoice.name)
        XCTAssertTrue(
            PearlVoice.askAction.contains(PearlVoice.name),
            "the assistant's own action stopped naming her"
        )
    }

    // MARK: - Her manner: what she is, and is not, the agent of

    /// Her name is on the rows that act on HER, and on no row that reaches the
    /// browser. That is the whole reconciliation between the pet's menu and
    /// `PearlVoice.identity`'s "you cannot open pages, click, search": the cat
    /// never claims to have done any of it.
    ///
    /// Each row is actually RUN against a spy, so this is not a reading of the
    /// titles — it is which rows touch `PearlPetHost` and which do not.
    ///
    /// Dies on: a row named "Ask Pearl to Take a Screenshot", or "Give Pearl a
    /// Fish" being wired to anything that reaches the browser.
    func testHerNameIsOnlyOnTheRowsThatActOnHer() {
        let view = PearlPetView()
        view.frame = CGRect(origin: .zero, size: PearlPetPlacement.hostSize(for: .default))
        view.spot = PearlPetSpot(x: 0.5, y: 0.5)  // so "Send … Home" is enabled

        for item in view.menuItems(selection: "sea otters", host: VoiceHostSpy()) {
            guard !item.isSeparator else { continue }
            let spy = VoiceHostSpy()
            // Rebuilt per row: running one row must not be able to make the
            // next row's spy look busy.
            let rows = view.menuItems(selection: "sea otters", host: spy)
            guard let row = rows.first(where: { $0.title == item.title }),
                  case .action(let perform) = row.kind
            else { continue }

            // The selection read happens while the menu is being built, not
            // when a row is chosen.
            spy.reached.removeAll()
            perform()

            if row.title.contains(PearlVoice.name) {
                XCTAssertTrue(
                    spy.reached.isEmpty,
                    """
                    "\(row.title)" names Pearl and reaches the browser \(spy.reached) — \
                    that row is her claiming to have browsed, which is the claim \
                    PearlVoice.identity exists to refuse
                    """
                )
            } else {
                XCTAssertFalse(
                    spy.reached.isEmpty,
                    """
                    "\(row.title)" does not name her and does not reach the browser \
                    either — it is neither of the two kinds of row her menu has
                    """
                )
            }
        }
    }

    /// The pet has no words in the first person, because the pet has no words
    /// at all: she is a sprite, and every string with her name on it is the
    /// app labelling a control. This is the register `PearlVoice` writes down,
    /// stated as a fact about the only strings she has.
    ///
    /// Dies on: a speech bubble, a tooltip in her voice, or an accessibility
    /// label rewritten as "I'm Pearl".
    func testTheCatNeverSpeaks() {
        let view = PearlPetView()
        view.frame = CGRect(origin: .zero, size: PearlPetPlacement.hostSize(for: .default))
        let strings = view.menuItems(selection: "sea otters", host: VoiceHostSpy())
            .filter { !$0.isSeparator }
            .map(\.title)
            + [view.accessibilityLabel() ?? ""]

        for text in strings {
            let words = text.lowercased().split { !$0.isLetter && $0 != "'" }.map(String.init)
            for firstPerson in ["i", "i'm", "me", "my", "mine"] where words.contains(firstPerson) {
                XCTFail("\"\(text)\" is Pearl speaking; the pet's chrome is the app talking about her")
            }
        }
    }

    /// And the assistant, whose half of the register IS first person, still
    /// has it. The two halves are different on purpose; a test that only
    /// pinned the pet's silence would be satisfied by nobody speaking at all.
    func testTheAssistantStillSpeaksForHerself() {
        for mode in PearlVoice.Mode.allCases {
            let greeting = PearlVoice.greeting(for: mode)
            let words = (greeting.headline + " " + greeting.detail)
                .lowercased()
                .split { !$0.isLetter && $0 != "'" }
                .map(String.init)
            XCTAssertTrue(
                words.contains { ["i", "i'm", "i've", "me", "my", "ill"].contains($0) }
                    || greeting.headline.contains(PearlVoice.name),
                "\(mode)'s greeting is nobody talking: \(greeting.headline) / \(greeting.detail)"
            )
        }
    }
}
