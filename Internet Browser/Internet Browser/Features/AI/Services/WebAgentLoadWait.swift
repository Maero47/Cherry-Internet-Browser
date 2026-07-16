//
//  WebAgentLoadWait.swift
//  Cherry Browser
//
//  The web research agent's "when do we stop waiting for the opened result
//  tabs to load?" policy, factored out as pure, unit-testable logic. Opened
//  result pages are wildly uneven: some settle in under a second, others
//  (ads, trackers, streaming, bot challenges) keep `isLoading == true`
//  indefinitely. Waiting for ALL of them would burn the full cap nearly
//  every run, so the policy is: proceed the moment every tab settles,
//  proceed once MOST tabs have settled and the stragglers have had a fair
//  grace period, and never wait longer than `maxWait` in total — a page
//  that never stops loading must not hold up the answer. (A tab that's
//  still loading can still be extracted — `innerText` reads the current
//  DOM — so waiting is only about giving content a chance to render, not a
//  hard requirement.)
//

nonisolated enum WebAgentLoadWait {
    /// Hard cap on the whole wait. After this, whatever has rendered gets
    /// read — the agent must never appear stuck on "Reading results…".
    static let maxWait: Duration = .seconds(7)
    /// How long stragglers are given once a MAJORITY of tabs has settled:
    /// past this, the settled majority is plenty to answer from.
    static let majorityGrace: Duration = .seconds(2.5)
    /// Poll cadence for sampling `isLoading` across the opened tabs.
    static let pollInterval: Duration = .milliseconds(300)
    /// Post-settle beat so late JS-rendered content (SPAs) has a chance to
    /// land before extraction reads `innerText`.
    static let settleBeat: Duration = .milliseconds(500)

    /// Whether reading should proceed, given that `settled` of the `total`
    /// opened tabs have finished loading after `elapsed` of waiting:
    /// everything settled, or a strict majority settled once
    /// `majorityGrace` has passed, or `maxWait` reached regardless. Pure so
    /// the policy is testable without webviews or a real clock.
    static func shouldProceed(settled: Int, total: Int, elapsed: Duration) -> Bool {
        guard total > 0 else { return true }
        if settled >= total { return true }
        if elapsed >= maxWait { return true }
        return elapsed >= majorityGrace && settled * 2 > total
    }
}
