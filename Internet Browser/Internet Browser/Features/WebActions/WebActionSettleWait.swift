//
//  WebActionSettleWait.swift
//  Cherry Browser
//
//  "Has this click finished happening yet?" as a pure function.
//
//  Beside `WebAgentLoadWait` in shape and in test style, and deliberately NOT
//  reusing its constants. That policy waits on N background research tabs, some
//  of which never stop loading, so it is tuned to give up generously
//  (`maxWait: 5s`, `settledGrace: 2.5s`). A click is one tab and one question,
//  and a model waiting five seconds to be told "nothing happened" is a model
//  that has burned five seconds of the user's time on every miss.
//
//  ## The measurements this encodes
//
//  A `MutationObserver` installed immediately before the action, sampled at
//  250 ms, separated the three outcomes cleanly on real pages:
//
//  ```
//  click #nothing:  navStarted=0  t+250ms:0 t+500ms:0 … t+2000ms:0
//  click #mutate:   navStarted=0  t+250ms:1 t+500ms:1 … t+2000ms:1
//  click #slow:     navStarted=0  t+250ms:0 … t+1250ms:0 t+1500ms:1 t+1750ms:1
//  click #navigate: navStarted=1 navFinished=1  t+250ms:0 t+500ms:GONE(navigated)
//  ```
//
//  So: a no-op is silence for the whole window, an ordinary change lands inside
//  250 ms, a slow one by 1500 ms, and a navigation destroys the observer's world
//  by 500 ms — which is also precisely the signal that every element id is now
//  meaningless.
//
//  `quietPeriod` is what turns that into an answer that arrives early. A page
//  that mutated and then went quiet for 400 ms is a page that has finished
//  reacting; waiting out the rest of the clock buys nothing and costs the model
//  its latency. A page that has not mutated at all is only conclusive at the end
//  of the window, so silence never short-circuits.
//

import Foundation

nonisolated enum WebActionSettleWait {

    /// Default ceiling on one action's observation window.
    static let defaultWaitMS = 2_500

    /// The most a caller may ask for. Above this a tool call starts competing
    /// with the client's own first-byte timer.
    static let maximumWaitMS = 10_000

    /// A caller may ask for none at all — fire and report immediately.
    static let minimumWaitMS = 0

    /// How long the page must be quiet, after having changed, before the answer
    /// is reported.
    static let quietPeriodMS = 400

    /// How often the observer is sampled.
    static let pollIntervalMS = 100

    /// `wait_ms` as the tool will actually apply it.
    static func boundedWait(_ requested: Int?) -> Int {
        guard let requested else { return defaultWaitMS }
        return min(max(minimumWaitMS, requested), maximumWaitMS)
    }

    /// Whether observation should stop now.
    ///
    /// - Parameters:
    ///   - mutations: how many DOM changes the observer has counted since the
    ///     action fired.
    ///   - sinceLastMutationMS: how long ago the most recent one was. Ignored
    ///     while `mutations` is zero.
    ///   - elapsedMS: since the action fired.
    ///   - maxWaitMS: the bounded `wait_ms`.
    static func shouldStop(
        mutations: Int,
        sinceLastMutationMS: Int,
        elapsedMS: Int,
        maxWaitMS: Int
    ) -> Bool {
        if elapsedMS >= maxWaitMS { return true }
        // Silence is only conclusive at the end of the window: a page that has
        // not moved yet may still be the `#slow` case above.
        guard mutations > 0 else { return false }
        return sinceLastMutationMS >= quietPeriodMS
    }

    /// The outcome a completed observation window means.
    ///
    /// Navigation wins over everything: a page that navigated also mutated on the
    /// way out, and reporting `changed` for it would leave a model holding
    /// element ids it believes are still good.
    static func outcome(navigated: Bool, mutations: Int) -> WebActionOutcomeKind {
        if navigated { return .navigated }
        return mutations > 0 ? .changed : .noEffect
    }
}
