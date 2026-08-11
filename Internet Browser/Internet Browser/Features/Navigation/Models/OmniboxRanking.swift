//
//  OmniboxRanking.swift
//  Cherry Browser
//
//  How the omnibox decides which history rows to show and in what order.
//
//  Everything here is pure: it takes candidate rows and a clock and returns an
//  order. No repository, no Core Data, no main actor. That is deliberate — the
//  ranking is the part that has to be argued about and pinned down by tests,
//  and none of that argument should require a store to exist.
//

import Foundation

/// Where in a candidate the query was found. The omnibox weighs this because
/// *where* a match lands says a lot about whether the user meant it: typing
/// "git" almost certainly means github.com, not an article whose tracking
/// parameter happens to contain "git".
///
/// The cases are declared best-first and their `weight`s are monotonically
/// decreasing, which is the whole ladder in one place.
enum OmniboxMatchKind: Int, CaseIterable, Comparable {
    /// The registrable host starts with the query — `git` → `github.com`.
    /// `www.` is ignored, so `app` matches `www.apple.com`.
    case hostPrefix
    /// The query appears inside the host but not at its start —
    /// `hub` → `github.com`.
    case hostSubstring
    /// The page title starts with the query.
    case titlePrefix
    /// The query appears inside the title.
    case titleSubstring
    /// The query appears in the URL's path.
    case pathSubstring
    /// The query appears only in the URL's query string or fragment — the
    /// weakest signal there is, and the one the brief singles out: "a hit at
    /// the start of the host beats a hit in the middle of a query string".
    case querySubstring

    /// Added to the frecency score. The span is chosen so that match position
    /// is worth roughly "a couple of doublings of visit count" — enough to
    /// reorder comparable rows, never enough to float a page visited once a
    /// year above one visited every morning.
    var weight: Double {
        switch self {
        case .hostPrefix: return 2.00
        case .hostSubstring: return 1.20
        case .titlePrefix: return 0.90
        case .titleSubstring: return 0.50
        case .pathSubstring: return 0.25
        case .querySubstring: return 0.05
        }
    }

    static func < (lhs: OmniboxMatchKind, rhs: OmniboxMatchKind) -> Bool {
        lhs.rawValue < rhs.rawValue   // lower raw value == better match
    }
}

/// One history row, reduced to exactly what ranking needs.
///
/// The folded text is an input rather than something this type derives: the
/// caller holds 20,000 of these and folding per keystroke is what made the old
/// search expensive. `HistoryItem` folds once, when the row is built, and hands
/// the result here. See `OmniboxSearchText`.
struct OmniboxCandidate: Equatable {
    let url: URL
    let title: String
    let visitCount: Int
    let lastVisit: Date
    let text: OmniboxSearchText

    init(url: URL, title: String, visitCount: Int, lastVisit: Date, text: OmniboxSearchText) {
        self.url = url
        self.title = title
        self.visitCount = visitCount
        self.lastVisit = lastVisit
        self.text = text
    }

    /// Folds the text itself. Convenient for tests and for one-off use; the hot
    /// path uses the initialiser above with text `HistoryItem` already folded.
    init(url: URL, title: String, visitCount: Int, lastVisit: Date) {
        self.init(
            url: url, title: title, visitCount: visitCount, lastVisit: lastVisit,
            text: OmniboxSearchText(url: url.absoluteString, title: title)
        )
    }

    static func == (lhs: OmniboxCandidate, rhs: OmniboxCandidate) -> Bool {
        lhs.url == rhs.url && lhs.title == rhs.title
            && lhs.visitCount == rhs.visitCount && lhs.lastVisit == rhs.lastVisit
    }
}

/// A candidate with the two things ranking decided about it. Kept around the
/// sort so the tie-break and the tests can see *why* something placed where it
/// did rather than just that it did.
struct RankedOmniboxCandidate: Equatable {
    let candidate: OmniboxCandidate
    let matchKind: OmniboxMatchKind
    let score: Double
}

enum OmniboxRanking {

    // MARK: - The decay curve

    /// How long it takes a visit's recency weight to halve.
    ///
    /// Ten days. The curve this names is `0.5 ^ (ageInDays / 10)`, so a page
    /// visited this morning carries ~1.0, one from last week ~0.6, one from a
    /// month ago ~0.12, and one from last year ~2e-11 — which is the brief's
    /// "a site you open daily beats one you opened forty times last year"
    /// stated as a number. Ten days is short enough that last week's research
    /// binge stops dominating the omnibox once it is over, and long enough
    /// that a site visited every Monday never falls out.
    static let recencyHalfLifeDays: Double = 10.0

    /// Recency can decay to effectively zero, and zero times any visit count is
    /// still zero — which would leave every ancient row tied and ordered by
    /// nothing. The floor keeps old rows separable by how often they were
    /// visited, while still placing all of them below anything recent.
    static let recencyFloor: Double = 0.001

    /// `0.5 ^ (age / halfLife)`, floored. 1.0 for a visit happening now;
    /// future timestamps (clock skew, a bad import) are clamped to 1.0 rather
    /// than allowed to score above everything.
    static func recencyWeight(lastVisit: Date, now: Date) -> Double {
        let ageDays = now.timeIntervalSince(lastVisit) / 86_400
        guard ageDays > 0 else { return 1.0 }
        return max(recencyFloor, pow(0.5, ageDays / recencyHalfLifeDays))
    }

    /// `log2(1 + visits)`, so the tenth visit matters much less than the
    /// second. Linear frequency would let a page opened in a loop by a script
    /// bury everything the user actually chose to visit.
    static func frequencyWeight(visitCount: Int) -> Double {
        log2(1 + Double(max(0, visitCount)))
    }

    /// The score itself: frecency, plus what the match position is worth.
    ///
    /// Additive rather than multiplicative on purpose. Multiplying would make
    /// the match bonus grow with the frecency it is applied to, so a
    /// host-prefix hit on an already-dominant row would run away with the
    /// list; added, it is a fixed nudge that reorders neighbours.
    static func score(
        visitCount: Int,
        lastVisit: Date,
        matchKind: OmniboxMatchKind,
        now: Date
    ) -> Double {
        frequencyWeight(visitCount: visitCount)
            * recencyWeight(lastVisit: lastVisit, now: now)
            + matchKind.weight
    }

    // MARK: - Matching

    /// Folds a typed query into the form the scan compares against.
    static func needle(for query: String) -> [UInt8] {
        Array(query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().utf8)
    }

    /// Where `needle` lands in `text`, or nil if it lands nowhere.
    ///
    /// Best match wins: a query that appears in both the host and the title is
    /// a host match, because the ladder in `OmniboxMatchKind` says so.
    ///
    /// Two byte searches per row and then integer comparisons — no
    /// `URLComponents`, no substring allocation, nothing that touches the heap
    /// for a row that is about to be discarded. That matters because this runs
    /// over every row in history on every keystroke.
    static func matchKind(for needle: [UInt8], in text: OmniboxSearchText) -> OmniboxMatchKind? {
        guard !needle.isEmpty else { return nil }

        var best: OmniboxMatchKind?

        if let hit = text.firstIndexInURL(of: needle) {
            if hit == text.hostStart {
                // Starts exactly where the registrable host does. A query that
                // runs on past the host ("example.com/docs") still counts: it
                // began at the strongest place there is.
                return .hostPrefix
            } else if hit < text.hostEnd {
                best = .hostSubstring
            } else if hit < text.pathEnd {
                best = .pathSubstring
            } else {
                best = .querySubstring
            }
        }

        if let hit = text.firstIndexInTitle(of: needle) {
            let titleKind: OmniboxMatchKind = hit == 0 ? .titlePrefix : .titleSubstring
            if best == nil || titleKind < best! { best = titleKind }
        }

        return best
    }

    /// String-taking convenience. The hot path folds the query once per
    /// keystroke and uses the byte form above.
    static func matchKind(for query: String, in candidate: OmniboxCandidate) -> OmniboxMatchKind? {
        matchKind(for: needle(for: query), in: candidate.text)
    }

    // MARK: - Ranking

    /// The dedup key: one entry per page, not one per visit.
    ///
    /// Scheme, a leading `www.` and a trailing slash are dropped, so
    /// `https://example.com/`, `https://example.com` and `http://example.com/`
    /// are one row. Query and fragment are kept, because `?q=swift` really is a
    /// different page.
    static func dedupKey(for candidate: OmniboxCandidate) -> String {
        var key = candidate.text.pageIdentity
        while key.hasSuffix("/") { key.removeLast() }
        return key
    }

    /// Ranks `candidates` against `query` and returns the best `limit`.
    ///
    /// - Rows that do not match at all are dropped.
    /// - A row whose whole URL *is* what the user has typed is dropped: they
    ///   are already typing it, so offering it back is a wasted line.
    /// - Duplicates collapse to the highest-scoring row for the page
    ///   (`dedupKey`), so a page cannot occupy the list more than once.
    /// - Ties break deterministically: better match position, then more recent,
    ///   then more visits, then URL ascending. The last step is arbitrary but
    ///   total, so the same history and the same query always give the same
    ///   list — an omnibox that reshuffles equal rows between keystrokes is
    ///   unusable even when every row in it is right.
    static func rank(
        _ candidates: [OmniboxCandidate],
        query: String,
        now: Date = Date(),
        limit: Int
    ) -> [RankedOmniboxCandidate] {
        let needle = needle(for: query)
        guard !needle.isEmpty, limit > 0 else { return [] }
        return rank(candidates, needle: needle, now: now, limit: limit)
    }

    /// The scored, deduplicated, ordered list. `needle` is the already-folded
    /// query — the caller folds once per keystroke, not once per row.
    ///
    /// Takes any sequence so the repository can pass a `lazy.map` over its
    /// rows: materialising 20,000 candidates to keep four of them is exactly
    /// the sort of per-row work this path exists to avoid.
    static func rank<Candidates: Sequence>(
        _ candidates: Candidates,
        needle: [UInt8],
        now: Date,
        limit: Int
    ) -> [RankedOmniboxCandidate] where Candidates.Element == OmniboxCandidate {
        guard !needle.isEmpty, limit > 0 else { return [] }

        // A running top-N rather than "score everything, then sort".
        //
        // A one-word query can match most of a large history, and the
        // per-row work that is NOT the score — building the page's dedup key,
        // hashing it, inserting it — is what that costs. Measured over 20,000
        // rows where the query matched nearly all of them, keeping every match
        // took 69 ms and keeping a bounded best-so-far takes a third of that.
        //
        // The bound is deliberately far above `limit`: dedup happens after,
        // over the survivors, so the buffer has to be deep enough that
        // duplicates of one page cannot crowd out distinct ones. Duplicates
        // arise only from `dedupKey`'s normalisation — a trailing slash, a
        // scheme, a `www.` — because the store is already one row per URL, so
        // a run of 29 variants of the same page ahead of every other match is
        // not a shape real history takes.
        let capacity = max(limit * 8, 32)
        var buffer: [RankedOmniboxCandidate] = []
        buffer.reserveCapacity(capacity + 1)
        var worstKept = -Double.greatestFiniteMagnitude

        for candidate in candidates {
            guard let kind = matchKind(for: needle, in: candidate.text) else { continue }
            let value = score(
                visitCount: candidate.visitCount,
                lastVisit: candidate.lastVisit,
                matchKind: kind,
                now: now
            )
            // Cannot reach the buffer, so it never pays for a dedup key.
            if buffer.count == capacity, value < worstKept { continue }
            // Already typing the whole thing: offering it back is a wasted line.
            guard candidate.text.urlBytes != needle else { continue }

            insert(
                RankedOmniboxCandidate(candidate: candidate, matchKind: kind, score: value),
                into: &buffer, capacity: capacity
            )
            worstKept = buffer[buffer.count - 1].score
        }

        // Dedup over the survivors, which are already best-first, so the row
        // kept for a page is the best row for that page.
        var seen = Set<String>()
        var result: [RankedOmniboxCandidate] = []
        result.reserveCapacity(limit)
        for ranked in buffer {
            guard seen.insert(dedupKey(for: ranked.candidate)).inserted else { continue }
            result.append(ranked)
            if result.count == limit { break }
        }
        return result
    }

    /// Insertion sort into a best-first buffer capped at `capacity`. Linear,
    /// which is the right shape at these sizes: the buffer holds a few dozen
    /// entries and almost every insertion lands near the end or is rejected.
    private static func insert(
        _ ranked: RankedOmniboxCandidate,
        into buffer: inout [RankedOmniboxCandidate],
        capacity: Int
    ) {
        var index = buffer.count
        while index > 0, isOrderedBefore(ranked, buffer[index - 1]) { index -= 1 }
        if index >= capacity { return }
        buffer.insert(ranked, at: index)
        if buffer.count > capacity { buffer.removeLast() }
    }

    /// The total order. Split out so dedup and sorting cannot disagree about
    /// which of two rows is "better".
    static func isOrderedBefore(_ lhs: RankedOmniboxCandidate, _ rhs: RankedOmniboxCandidate) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.matchKind != rhs.matchKind { return lhs.matchKind < rhs.matchKind }
        if lhs.candidate.lastVisit != rhs.candidate.lastVisit {
            return lhs.candidate.lastVisit > rhs.candidate.lastVisit
        }
        if lhs.candidate.visitCount != rhs.candidate.visitCount {
            return lhs.candidate.visitCount > rhs.candidate.visitCount
        }
        return lhs.candidate.url.absoluteString < rhs.candidate.url.absoluteString
    }
}
