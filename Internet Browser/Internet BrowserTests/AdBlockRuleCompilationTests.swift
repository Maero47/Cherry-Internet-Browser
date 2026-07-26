//
//  AdBlockRuleCompilationTests.swift
//  Internet BrowserTests
//
//  `url-filter` is parsed by WebKit's own restricted regex engine, NOT by
//  NSRegularExpression. A construct it doesn't support (alternation, say)
//  makes it reject the ENTIRE rule list — and `AdBlockManager` used to
//  swallow that error, so the failure mode was "the blocker silently does
//  nothing while the switch says it's on".
//
//  A string assertion cannot catch that. These tests push the real emitted
//  JSON through the real `WKContentRuleListStore`.
//

import WebKit
import XCTest
@testable import Cherry

final class AdBlockRuleCompilationTests: XCTestCase {

    /// Compiles `json` and returns WebKit's error, or nil on success.
    /// Uses a throwaway identifier so the app's own lists are untouched.
    private func compileError(_ json: String, identifier: String) async -> String? {
        let store = WKContentRuleListStore.default()
        let error: String? = await withCheckedContinuation { continuation in
            store?.compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: json
            ) { _, error in
                continuation.resume(returning: error?.localizedDescription)
            }
        }
        await withCheckedContinuation { continuation in
            store?.removeContentRuleList(forIdentifier: identifier) { _ in
                continuation.resume()
            }
        }
        return error
    }

    // MARK: - The real rule sets

    func testSupplementaryRuleListCompiles() async {
        let json = await MainActor.run { AdBlockManager.buildSupplementaryJSON() }
        let error = await compileError(json, identifier: "CherryTest_Supplementary")
        XCTAssertNil(error, "WebKit rejected the supplementary rule list — it would silently not block anything")
    }

    func testDomainRuleListCompiles() async {
        // A representative slice: the exception + /cdn-cgi/ tail is what
        // actually changed, and it is appended to every domain list.
        let json = AdBlockRuleBuilder.domainRulesJSON(for: [
            "doubleclick.net", "googlesyndication.com", "scorecardresearch.com",
            "optanon.blob.core.windows.net", "ads.example-tracker.co.uk",
        ])
        let error = await compileError(json, identifier: "CherryTest_Domains")
        XCTAssertNil(error, "WebKit rejected the EasyList-derived rule list")
    }

    func testCookiePolicyRuleListsCompile() async {
        for level in [CookieBlockingLevel.thirdParty, .all] {
            guard let json = await MainActor.run(body: { CookiePolicyManager.ruleJSON(for: level) }) else {
                XCTFail("no rules emitted for \(level.rawValue)")
                continue
            }
            let error = await compileError(json, identifier: "CherryTest_Cookies_\(level.id.replacingOccurrences(of: " ", with: "_"))")
            XCTAssertNil(error, "WebKit rejected the cookie policy for \(level.rawValue)")
        }
    }

    // MARK: - Per-pattern coverage

    /// Every distinct trigger shape the builder can emit, compiled one at a
    /// time so a failure names the pattern that broke rather than "something
    /// in a 45,000-rule list".
    func testEveryTriggerShapeCompilesIndividually() async {
        let shapes: [(String, [String: Any])] = [
            ("block", AdBlockRuleBuilder.blockRule(for: "doubleclick.net")),
            ("exception", AdBlockRuleBuilder.exceptionRule(for: "optanon.blob.core.windows.net")),
            ("cdn-cgi", AdBlockRuleBuilder.cdnCGIExceptionRule()),
            ("script-path", AdBlockRuleBuilder.scriptPathBlockRule(for: "ads.js")),
        ]
        for (name, rule) in shapes {
            let json = AdBlockRuleBuilder.json(from: [rule])
            let error = await compileError(json, identifier: "CherryTest_Shape_\(name)")
            XCTAssertNil(error, "WebKit rejected the \(name) trigger: \(json)")
        }
    }

    /// Negative control: proves the harness above can actually detect a
    /// rejected list. Without this, all the "compiles fine" assertions could
    /// be passing because the compile never really happened.
    ///
    /// The pattern is the one that shipped in `a482144` — `([?#]|$)` — which
    /// is what prompted this whole check.
    func testAlternationPatternIsRejectedByWebKit() async {
        let rule: [String: Any] = [
            "trigger": [
                "url-filter": "^https?://[^/]+(/[^?#]*)?/ads\\.js([?#]|$)",
                "resource-type": ["script"],
            ],
            "action": ["type": "block"],
        ]
        let error = await compileError(
            AdBlockRuleBuilder.json(from: [rule]),
            identifier: "CherryTest_NegativeControl"
        )
        XCTAssertNotNil(error, "WebKit accepted alternation — the compile harness is not proving anything")
    }

    // MARK: - The cookie list actually becomes available

    /// The previous `CookiePolicyManager` recorded the newly selected level
    /// *before* compiling and returned early on every later call, so the
    /// second policy a user picked silently did nothing. This drives two
    /// consecutive changes and waits for a real compiled list each time.
    @MainActor
    func testConsecutivePolicyChangesEachProduceACompiledList() async throws {
        let settings = SettingsManager.shared
        let original = settings.blockCookies
        defer { settings.blockCookies = original }

        for level in [CookieBlockingLevel.thirdParty, .all, .thirdParty] {
            settings.blockCookies = level          // didSet → applyCookiePolicy
            let manager = CookiePolicyManager.shared
            var attached = false
            for _ in 0..<100 {
                if manager.activeLevel == level, manager.compiledList != nil {
                    attached = true
                    break
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertTrue(attached, "no compiled cookie rule list for \(level.rawValue)")
            XCTAssertNil(manager.compileFailure)
        }
    }

    /// Web views built before a list finished compiling — every tab restored
    /// at launch — only learn about it from this notification. If it stops
    /// being posted, those tabs run with no rules and nothing says so.
    @MainActor
    func testCompilingAPolicyAnnouncesItToExistingWebViews() async throws {
        let settings = SettingsManager.shared
        let original = settings.blockCookies
        defer { settings.blockCookies = original }
        settings.blockCookies = .none

        var announced = false
        let token = NotificationCenter.default.addObserver(
            forName: .cherryContentRuleListsChanged, object: nil, queue: .main
        ) { _ in announced = true }
        defer { NotificationCenter.default.removeObserver(token) }

        settings.blockCookies = .thirdParty
        for _ in 0..<100 where !announced {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(announced, "nothing told existing web views to attach the new cookie rule list")
    }

    /// Selecting "Allow All" must clear the list rather than leave the last
    /// blocking list attached.
    @MainActor
    func testAllowAllClearsTheCompiledList() async throws {
        let settings = SettingsManager.shared
        let original = settings.blockCookies
        defer { settings.blockCookies = original }

        settings.blockCookies = .all
        for _ in 0..<100 where CookiePolicyManager.shared.compiledList == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        settings.blockCookies = .none
        XCTAssertNil(CookiePolicyManager.shared.compiledList)
        XCTAssertEqual(CookiePolicyManager.shared.activeLevel, .none)
    }

    /// Guards the specific mistake this round found: `url-filter` regexes must
    /// stay inside the subset WebKit's parser accepts.
    func testNoEmittedPatternUsesAlternation() {
        var patterns: [String] = [
            AdBlockRuleBuilder.hostPattern(for: "example.com"),
            AdBlockRuleBuilder.cdnCGIPathPattern,
        ]
        for filename in AdBlockRuleBuilder.blockedScriptFilenames {
            let rule = AdBlockRuleBuilder.scriptPathBlockRule(for: filename)
            let trigger = rule["trigger"] as? [String: Any]
            patterns.append(trigger?["url-filter"] as? String ?? "")
        }
        for pattern in patterns {
            XCTAssertFalse(pattern.contains("|"), "alternation is not part of WebKit's url-filter subset: \(pattern)")
        }
    }
}
