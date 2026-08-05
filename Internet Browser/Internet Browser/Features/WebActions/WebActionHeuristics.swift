//
//  WebActionHeuristics.swift
//  Cherry Browser
//
//  Whether a control looks like it commits something the user cannot take back.
//
//  ## What this is, stated before anything else
//
//  This is a HEURISTIC over English words and HTML shape. It is containment, not
//  prevention, and every sentence below is written so that nothing downstream —
//  a tool description, a Settings string, a comment — can quietly upgrade it
//  into a guarantee.
//
//  What it structurally cannot catch:
//
//  * **An icon-only control.** A trash-can `<button aria-label="">`, or one
//    labelled `"×"`, has no verb to match. Deleting by clicking an unlabelled
//    icon is entirely possible and entirely unflagged.
//  * **Non-English pages.** The verb list is English. A German "Kaufen" or a
//    Turkish "Satın al" passes straight through. That is not a small gap for a
//    browser, and it has not been probed at all.
//  * **Innocuous names on committing controls.** "Continue", "Next", "Done" and
//    "OK" are step 3 of 4 in most checkouts. They are deliberately NOT in the
//    verb list: adding them would flag half of every wizard on the web and make
//    the tool useless, and leaving them out means checkouts complete.
//  * **Two-step commitments.** "Add to cart" is reversible. This function sees
//    one click at a time and has no notion of a transaction.
//
//  There is no measured precision here. The corpus below is nine real pages,
//  and the rule was tuned against those same nine — that is a sanity check, not
//  an estimate, and `WebActionHeuristicsTests` encodes it as fixtures so a
//  future change has to say out loud which of them it breaks.
//
//  ## Why the structural test carries the weight
//
//  A verb regex over the accessible name alone, run over every visible control
//  on the corpus, produced 20 flags and not one of them was a commitment:
//  "Verified Purchase" ×12 (review metadata), "Self-Publish with Us"
//  (marketing), "Subscribe" (a newsletter link), "Donate" (a link), "Learn how
//  and when to remove this message". Every single one was a plain `<a href>` —
//  a GET navigation.
//
//  Requiring the control to be commitment-SHAPED as well removed all 20 and kept
//  4 of 5 true positives. The one survivor, `"Template:Cite book" <a href> in a
//  form`, is instructive twice over: `book` is a verb in only one of its senses,
//  and the "an `<a>` inside a `<form>` counts as a control" relaxation is what
//  let it through. Both are fixed here — `book`, `order`, `remove` and `post`
//  are absent from the verb list because they are common nouns that appear
//  constantly in ordinary link text, and an `<a>` needs a non-navigational href
//  to be considered at all, whether or not it sits in a form.
//
//  ## Isolation
//
//  `nonisolated`, like `MCPToolRegistry`, so it is pure, testable without a
//  browser, and callable from the SDK's executor without a hop.
//

import Foundation

// MARK: - What the classifier is given

/// The facts about one element that the commitment rule is allowed to see.
///
/// Deliberately small and deliberately `Sendable`: it is built inside
/// `WebActionBridge` from the isolated world's JSON and then classified off any
/// actor, and nothing here can reach back into a `WKWebView`.
nonisolated struct WebActionElementDescriptor: Sendable, Equatable {

    /// The role the listing shows — the page's explicit `role` when it set one,
    /// else derived from the tag and `input.type`.
    let role: String

    /// The accessible name, RAW. Sanitisation is for display; matching a verb
    /// against the sanitised form would mean `"Buy\u{2028}now"` matched
    /// differently from `"Buy now"`, and an attacker chooses which one to write.
    let name: String

    /// Upper-case tag name, as `Element.tagName` reports it.
    let tag: String

    /// The `type` attribute, for `<input>`. Nil when absent.
    let type: String?

    /// Whether an `href` attribute is present at all.
    let hasHref: Bool

    /// Whether that `href` actually navigates — present, non-empty, not `"#"`,
    /// not `javascript:`. This is the whole `<a>` test: a link is navigation.
    let hrefIsNavigational: Bool

    /// Whether the element sits inside a `<form>`.
    ///
    /// Recorded and NOT consulted. Treating form membership as evidence is
    /// exactly what let `"Template:Cite book"` — an ordinary wiki link that
    /// happens to sit inside the edit form — be flagged as a commitment. It is
    /// kept on the descriptor because the audit log in a later slice records it,
    /// and because its absence from the rule should be visible rather than
    /// inferred from a missing field.
    let inForm: Bool

    init(
        role: String,
        name: String,
        tag: String,
        type: String? = nil,
        hasHref: Bool = false,
        hrefIsNavigational: Bool = false,
        inForm: Bool = false
    ) {
        self.role = role
        self.name = name
        self.tag = tag
        self.type = type
        self.hasHref = hasHref
        self.hrefIsNavigational = hrefIsNavigational
        self.inForm = inForm
    }
}

// MARK: - What it answers

nonisolated enum WebActionCommitment: Sendable, Equatable {

    /// Nothing about this control suggests it commits anything. This is the
    /// answer for the overwhelming majority of controls, including plenty that
    /// do commit something — see the file header.
    case ordinary

    /// The control is commitment-shaped and its name carries `verb`.
    ///
    /// In this slice that is a FLAG on a listing row, so a model knows before it
    /// asks. When the acting slice lands it also becomes a refusal.
    case irreversible(verb: String)

    var isIrreversible: Bool {
        if case .irreversible = self { return true }
        return false
    }

    var verb: String? {
        if case .irreversible(let verb) = self { return verb }
        return nil
    }
}

// MARK: - The rule

nonisolated enum WebActionHeuristics {

    /// Words whose presence in a control's name suggests a commitment.
    ///
    /// Every entry is a verb whose ordinary-English noun senses are rare in UI
    /// copy. The four that were removed after measurement — `book`, `order`,
    /// `remove`, `post` — all fail that test: "Cite book", "in order to",
    /// "remove this message", "post" as a noun on every forum on the web.
    ///
    /// Matched per WORD and by prefix, so "payment", "purchases", "confirming"
    /// and "transferring" match while "company" and "display" do not. A plain
    /// substring test would match "pay" inside far too much.
    static let commitmentVerbs: Set<String> = [
        "buy", "checkout", "confirm", "delete", "donate", "pay", "publish",
        "purchase", "reserve", "send", "subscribe", "transfer", "withdraw",
    ]

    /// `.ordinary`, or `.irreversible` naming the word that matched.
    static func classify(_ element: WebActionElementDescriptor) -> WebActionCommitment {
        guard isCommitmentShaped(element) else { return .ordinary }
        guard let verb = commitmentVerb(in: element.name) else { return .ordinary }
        return .irreversible(verb: verb)
    }

    /// Whether the element is the KIND of thing that commits: a button, a submit
    /// control, something the page itself calls a button, or a link that does not
    /// actually link anywhere and is therefore a JavaScript control wearing an
    /// `<a>`.
    ///
    /// The `<a>` test comes first and is absolute. A page can put
    /// `role="button"` on a real link, and a real link is still a GET
    /// navigation — flagging it would reintroduce every false positive the
    /// structural test was added to remove.
    static func isCommitmentShaped(_ element: WebActionElementDescriptor) -> Bool {
        if element.tag == "A" { return !element.hrefIsNavigational }
        if element.role == "button" { return true }
        if element.tag == "BUTTON" { return true }
        if element.tag == "INPUT", let type = element.type?.lowercased() {
            return type == "submit" || type == "image"
        }
        return false
    }

    /// The first commitment verb in `name`, or nil.
    ///
    /// Case-insensitive, split on anything that is not a letter or a digit, so
    /// "Donate by credit/debit card" yields `donate` and "Self-Publish with Us"
    /// yields `publish` — the latter being a case the structural test above is
    /// what rejects, not this.
    static func commitmentVerb(in name: String) -> String? {
        let words = name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        for word in words {
            for verb in commitmentVerbs where word.hasPrefix(verb) {
                return verb
            }
        }
        return nil
    }
}
