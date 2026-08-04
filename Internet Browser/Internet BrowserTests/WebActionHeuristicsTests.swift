//
//  WebActionHeuristicsTests.swift
//  Internet BrowserTests
//
//  The probe corpus, as fixtures.
//
//  These rows are not invented. Each one is a real control from a real page,
//  measured while the rule was being tuned: nine pages, ~2,500 visible controls,
//  five genuine commitments among them. A verb regex over the accessible name
//  alone produced 20 flags and not one was a commitment; adding the structural
//  test removed all 20 and kept 4 of 5, and dropping four ambiguous verbs
//  recovered the fifth.
//
//  What this file is FOR is the next change. The rule was tuned against these
//  same nine pages, so this is a sanity check and not a precision estimate — but
//  it does mean a future edit has to say out loud which of these it breaks
//  rather than discovering it on someone's checkout page.
//

import XCTest
@testable import Cherry

final class WebActionHeuristicsTests: XCTestCase {

    // MARK: - Fixtures

    private static func button(_ name: String, type: String? = nil, inForm: Bool = false) -> WebActionElementDescriptor {
        WebActionElementDescriptor(role: "button", name: name, tag: "BUTTON", type: type, inForm: inForm)
    }

    private static func link(_ name: String, href: String = "/x", inForm: Bool = false) -> WebActionElementDescriptor {
        WebActionElementDescriptor(
            role: "link",
            name: name,
            tag: "A",
            hasHref: true,
            hrefIsNavigational: !href.isEmpty && href != "#" && !href.hasPrefix("javascript:"),
            inForm: inForm
        )
    }

    // MARK: - The corpus

    /// Every row the plan names, and the four extra true positives beside them.
    func testTheProbeCorpusClassifiesAsMeasured() {
        let corpus: [(String, WebActionElementDescriptor, WebActionCommitment)] = [
            // donate.wikimedia.org — the three true positives, all <button> in a form.
            ("Donate by credit/debit card",
             Self.button("Donate by credit/debit card", inForm: true), .irreversible(verb: "donate")),
            ("Apple Pay", Self.button("Apple Pay", inForm: true), .irreversible(verb: "pay")),
            ("Google Pay", Self.button("Google Pay", inForm: true), .irreversible(verb: "pay")),

            // en.wikipedia.org edit form — one true positive and the false one.
            ("Publish changes",
             Self.button("Publish changes", type: "submit", inForm: true), .irreversible(verb: "publish")),
            ("Template:Cite book", Self.link("Template:Cite book", href: "/wiki/Template:Cite_book", inForm: true), .ordinary),
            ("Donate (wikipedia sidebar)", Self.link("Donate", href: "/wiki/Special:Donate"), .ordinary),

            // amazon.com — 15 name-only flags, 0 commitment-shaped.
            ("Verified Purchase", Self.link("Verified Purchase", href: "/gp/help"), .ordinary),
            ("Self-Publish with Us", Self.link("Self-Publish with Us", href: "/gp/seller-account"), .ordinary),
            ("Goodreads Book reviews & recommendations",
             Self.link("Goodreads Book reviews & recommendations", href: "https://goodreads.com"), .ordinary),

            // github.com — one name-only flag, 0 commitment-shaped.
            ("Subscribe", Self.link("Subscribe", href: "/newsletter"), .ordinary),

            // en.wikipedia.org article — two name-only flags, 0 commitment-shaped.
            ("Learn how and when to remove this message",
             Self.link("Learn how and when to remove this message", href: "/wiki/Help"), .ordinary),
        ]

        for (label, element, expected) in corpus {
            XCTAssertEqual(WebActionHeuristics.classify(element), expected, label)
        }
    }

    /// The whole argument for the structural test, in one assertion: the name is
    /// identical and the answer is not, because one is a link and one is a button.
    func testTheSameNameIsFlaggedOnAButtonAndNotOnALink() {
        XCTAssertEqual(WebActionHeuristics.classify(Self.button("Donate")), .irreversible(verb: "donate"))
        XCTAssertEqual(WebActionHeuristics.classify(Self.link("Donate")), .ordinary)
    }

    /// A plain `<a href>` is a GET navigation and is never a commitment, whatever
    /// it is called and wherever it sits. This is what removed all 20 false
    /// positives, and `inForm` is deliberately not consulted — treating form
    /// membership as evidence is exactly what let "Template:Cite book" through.
    func testALinkThatActuallyLinksIsNeverFlagged() {
        for name in ["Buy now", "Delete account", "Send message", "Confirm payment", "Transfer funds"] {
            XCTAssertEqual(WebActionHeuristics.classify(Self.link(name)), .ordinary, name)
            XCTAssertEqual(WebActionHeuristics.classify(Self.link(name, inForm: true)), .ordinary, name)
        }
    }

    /// …and an `<a>` with nothing to navigate to is a JavaScript control wearing
    /// an anchor, which is exactly the shape that does commit things.
    func testALinkWithNoUsableHrefIsTreatedAsAControl() {
        for href in ["", "#", "javascript:void(0)"] {
            XCTAssertEqual(
                WebActionHeuristics.classify(Self.link("Delete this account", href: href)),
                .irreversible(verb: "delete"),
                href.isEmpty ? "(empty href)" : href
            )
        }
    }

    /// A page's own `role="button"` on a div is a control, because the page said
    /// so — but `role="button"` on a REAL link is still a navigation, or the
    /// `<a>` rule would be trivially bypassable in the wrong direction.
    func testExplicitRolesAreHonouredExceptOnRealLinks() {
        let div = WebActionElementDescriptor(role: "button", name: "Delete everything", tag: "DIV")
        XCTAssertEqual(WebActionHeuristics.classify(div), .irreversible(verb: "delete"))

        let styledLink = WebActionElementDescriptor(
            role: "button", name: "Delete everything", tag: "A",
            hasHref: true, hrefIsNavigational: true
        )
        XCTAssertEqual(WebActionHeuristics.classify(styledLink), .ordinary)
    }

    /// `<input type=submit>` and `<input type=image>` commit; the other input
    /// types are fields, not commitments.
    func testOnlySubmitAndImageInputsAreCommitmentShaped() {
        func input(_ type: String) -> WebActionElementDescriptor {
            WebActionElementDescriptor(role: "button", name: "Send", tag: "INPUT", type: type, inForm: true)
        }
        XCTAssertTrue(WebActionHeuristics.isCommitmentShaped(input("submit")))
        XCTAssertTrue(WebActionHeuristics.isCommitmentShaped(input("image")))

        let text = WebActionElementDescriptor(role: "textbox", name: "Send", tag: "INPUT", type: "text")
        XCTAssertFalse(WebActionHeuristics.isCommitmentShaped(text))
        XCTAssertEqual(WebActionHeuristics.classify(text), .ordinary)
    }

    // MARK: - The four verbs that were dropped, and why

    /// `book`, `order`, `remove` and `post` are common nouns in ordinary UI copy.
    /// They were removed after measurement, and putting one back would flag every
    /// citation template and every "remove this message" banner on Wikipedia.
    func testTheAmbiguousVerbsAreNotInTheList() {
        for word in ["book", "order", "remove", "post"] {
            XCTAssertFalse(WebActionHeuristics.commitmentVerbs.contains(word),
                           "\"\(word)\" is a common noun and was measured as a false positive")
        }
        XCTAssertEqual(WebActionHeuristics.classify(Self.button("Book a table")), .ordinary)
        XCTAssertEqual(WebActionHeuristics.classify(Self.button("Order of operations")), .ordinary)
    }

    /// The gaps this rule cannot close, asserted so that nothing downstream can
    /// quietly start describing it as protection.
    ///
    /// If one of these ever starts passing, that is not automatically a bug — but
    /// it IS a change in what the feature claims, and it should have to be made
    /// deliberately here rather than noticed later.
    func testTheKnownGapsAreStillGaps() {
        // An icon-only delete button has no verb to match.
        XCTAssertEqual(WebActionHeuristics.classify(Self.button("×")), .ordinary)
        XCTAssertEqual(WebActionHeuristics.classify(Self.button("")), .ordinary)

        // Non-English pages are not covered at all.
        XCTAssertEqual(WebActionHeuristics.classify(Self.button("Kaufen", inForm: true)), .ordinary)
        XCTAssertEqual(WebActionHeuristics.classify(Self.button("Satın al", inForm: true)), .ordinary)

        // And the wizard verbs are excluded on purpose: including them would flag
        // half of every multi-step form on the web and make the tool useless.
        for step in ["Continue", "Next", "Done", "OK", "Submit"] {
            XCTAssertEqual(WebActionHeuristics.classify(Self.button(step, type: "submit", inForm: true)),
                           .ordinary, step)
        }
    }

    // MARK: - Word matching

    /// Prefix-per-word, not substring: "payment" matches, "company" does not.
    func testVerbsMatchWholeWordsByPrefix() {
        XCTAssertEqual(WebActionHeuristics.commitmentVerb(in: "Confirm payment"), "confirm")
        XCTAssertEqual(WebActionHeuristics.commitmentVerb(in: "Complete your purchases"), "purchase")
        XCTAssertEqual(WebActionHeuristics.commitmentVerb(in: "Transferring funds"), "transfer")
        XCTAssertEqual(WebActionHeuristics.commitmentVerb(in: "Donate by credit/debit card"), "donate")

        for innocuous in ["Company profile", "Display options", "Repayment history is here", "Bandwidth"] {
            XCTAssertNil(WebActionHeuristics.commitmentVerb(in: innocuous), innocuous)
        }
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertEqual(WebActionHeuristics.classify(Self.button("DELETE ACCOUNT")), .irreversible(verb: "delete"))
        XCTAssertEqual(WebActionHeuristics.classify(Self.button("delete account")), .irreversible(verb: "delete"))
    }
}
