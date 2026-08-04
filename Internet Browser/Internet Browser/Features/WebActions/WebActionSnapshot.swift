//
//  WebActionSnapshot.swift
//  Cherry Browser
//
//  What one listing of a page's controls IS, before anyone decides how to say it.
//
//  These types are deliberately not MCP types. `WebActionBridge` sits BELOW MCP
//  — the plan's seam for local agent mode is exactly here — so the bridge
//  answers in Swift values and each consumer projects them into its own wire
//  shape (`MCPReadElementsPayload` for MCP, whatever the local agent loop wants
//  later). The one thing neither consumer gets to redecide is the rendering of a
//  row, which lives on `WebActionElement` below, because a row's shape is a
//  security property and not a formatting preference.
//

import Foundation

// MARK: - Scope

/// How much of the page a snapshot covers.
///
/// The default is `viewport`, and it is not a nicety. Measured on one Wikipedia
/// article: 961 elements ≈ 36,000 characters whole-page against 111 ≈ 2,800
/// characters on-screen — a third of a model's per-result hard limit, spent on
/// a list of footnote links. Build cost is 4–12 ms either way; this is a
/// context-window problem, not a performance one.
nonisolated enum WebActionScope: String, Sendable, CaseIterable {
    case viewport
    case page
}

// MARK: - One control

nonisolated struct WebActionElement: Sendable, Equatable {

    /// From the isolated world's `WeakMap`, never from a position in the list.
    let id: Int

    let role: String

    /// Already through `WebActionScripts.sanitiseName`. There is no path to a
    /// consumer that carries the raw one, which is the point.
    let name: String

    /// Whether this control looks like it commits something that cannot be
    /// undone. A flag in this slice, so a model knows before it asks; a refusal
    /// once there is something to refuse.
    let commitment: WebActionCommitment

    let disabled: Bool
    let checked: Bool?

    /// `"true"` / `"false"` from `aria-expanded`, else nil.
    let expanded: String?

    /// The field's current contents, sanitised and capped. Never a password
    /// field's — those are dropped in the isolated world and never cross.
    let value: String?

    /// Listed, but not currently on screen. Only possible under `scope: .page`.
    let offscreen: Bool

    /// The one line a model reads.
    ///
    /// One element is one line, always — see `WebActionScripts.sanitiseName` for
    /// the forged-row attack this shape exists to close. Everything variable in
    /// it has been through the sanitiser; the only characters this method itself
    /// contributes are the brackets, the quotes and the parentheses.
    var listingLine: String {
        var line = "[\(id)] \(role) \"\(name)\""
        var states: [String] = []
        if let verb = commitment.verb { states.append("commits=\(verb)") }
        if disabled { states.append("disabled") }
        if let checked { states.append(checked ? "checked" : "unchecked") }
        if let expanded { states.append("expanded=\(expanded)") }
        if let value, !value.isEmpty { states.append("value=\"\(value)\"") }
        if offscreen { states.append("offscreen") }
        if !states.isEmpty { line += " (" + states.joined(separator: ", ") + ")" }
        return line
    }
}

// MARK: - One listing

nonisolated struct WebActionSnapshot: Sendable {

    let tabID: String
    let windowID: String

    /// The LIVE document's address, as the isolated world reports it — not the
    /// tab model's, which diverges during navigation and across redirects.
    let url: String
    let title: String

    /// Incremented per snapshot, and per document. An action taken later carries
    /// the `generation` it was chosen from; nothing in this read-only slice reads
    /// them yet, and they are reported because a client that cannot see them
    /// cannot notice a page moving under it.
    let generation: Int
    let document: Int

    /// What the snapshot actually covered — which is not always what was asked
    /// for. See `pageVisible`.
    let scope: WebActionScope

    let elements: [WebActionElement]

    /// Interactive elements found in the main frame, before the layout, viewport,
    /// filter and size cuts.
    let matched: Int

    /// Elements that exist and have a role but are laid out nowhere.
    let droppedNoLayout: Int

    /// Elements a `viewport` scope declined to list.
    let offscreenNotListed: Int

    /// Elements a `filter` declined to list.
    let filteredOut: Int

    /// Frames in this tab, INCLUDING the main one. v1 lists the main frame only,
    /// so anything above 1 is content this version cannot see — reported so a
    /// model is told rather than left to infer an empty page.
    let frames: Int

    /// Custom elements that look like they hide a CLOSED shadow root. A
    /// heuristic — a closed root is unreachable and indistinguishable from no
    /// root at all — and reported as a count precisely because it cannot be
    /// resolved into a list.
    let closedShadowHosts: Int

    /// Open shadow roots the walk went into. A plain `querySelectorAll` cannot,
    /// so the recursion is not optional.
    let shadowRootsEntered: Int

    /// False when the web view has no viewport to speak of — hidden, zero-framed,
    /// or off the hierarchy — in which case `scope` fell back to `.page` and the
    /// on-screen notion did not apply at all.
    let pageVisible: Bool

    /// `document.visibilityState`, verbatim.
    let visibility: String

    /// The walk hit its node ceiling and stopped early.
    let walkCapped: Bool

    /// Elements were dropped to fit the result budget.
    let truncated: Bool

    /// What was cut and what to do about it. Never nil while anything was cut:
    /// a silent 200-of-961 reads to a model as "these are all the controls".
    let note: String?
}
