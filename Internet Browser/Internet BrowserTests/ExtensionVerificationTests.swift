//
//  ExtensionVerificationTests.swift
//  Internet BrowserTests
//
//  Live verification harness for the first-run extension shortlist
//  (`ExtensionShortlist`). Opt-in, like the screenshot tests: set
//  CHERRY_EXT_VERIFY_DIR (or TEST_RUNNER_CHERRY_EXT_VERIFY_DIR) to a directory
//  of candidate packages and each test loads one candidate into the app's real
//  `ExtensionManager`, opens a real tab in the hosted app's real window, and
//  probes for that extension's SPECIFIC observable effect — a content
//  blocker must actually block a request, a dark-mode extension must actually
//  restyle the page. Loading cleanly is never treated as passing.
//
//  A candidate that fails its probe is a RESULT, not a test failure: every
//  test writes a JSON evidence file (verdict + each check's observed value)
//  into `<verify dir>/../evidence/`, and the shortlist is built from those
//  files. XCTFail here means the HARNESS broke (no window, no tab, no
//  network), not that an extension is incompatible.
//
//  Package layout expected in CHERRY_EXT_VERIFY_DIR: `<key>.xpi` / `<key>.zip`
//  archives, each with an optional pre-unzipped `<key>.unpacked/` sibling; the
//  harness loads the archive exactly like the app's "Load Extension…" path,
//  and falls back to the unpacked directory if WebKit rejects the archive
//  form. Both forms go through `ExtensionManager.loadExtension(from:)`.
//
//  Every candidate is removed again via `ExtensionManager.remove` before the
//  test ends — the hosted app shares the real Application Support extensions
//  index, and leaking a 20 MB password manager into the user's persisted
//  extensions would outlive the test run.
//

import XCTest
import WebKit
@testable import Cherry

@MainActor
final class ExtensionVerificationTests: XCTestCase {

    private var packagesDirectory: URL!
    private var evidenceDirectory: URL!
    private var savedAdBlockEnabled = true
    /// Extensions already in the user's persistent index when the test
    /// started, with the enabled ones switched off for the duration and put
    /// back in tearDown. Every evidence file records what was found here, so
    /// no verdict rests on an unexamined starting state.
    private var preExistingExtensions: [(id: String, name: String, wasEnabled: Bool)] = []

    override func setUp() async throws {
        let environment = ProcessInfo.processInfo.environment
        let path = environment["CHERRY_EXT_VERIFY_DIR"] ?? environment["TEST_RUNNER_CHERRY_EXT_VERIFY_DIR"]
        try XCTSkipIf(path == nil, "live extension verification is opt-in")

        packagesDirectory = URL(fileURLWithPath: path!, isDirectory: true)
        evidenceDirectory = packagesDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)

        // Cherry's own ad blocker is on by default and its rule lists are baked
        // into every fresh webview at creation. Left on, the ad-fetch probe
        // would report "blocked" with no extension loaded at all. Flipped off
        // for the duration; the probe tab is created after this point so its
        // configuration never receives the lists.
        savedAdBlockEnabled = SettingsManager.shared.adBlockEnabled
        SettingsManager.shared.adBlockEnabled = false

        // The hosted app shares the USER'S real Application Support extension
        // index, and it is not guaranteed empty — round 1 left two enabled uBO
        // Lite copies in it. An already-loaded content blocker would answer
        // every ad probe below and a second copy of the candidate would make
        // "the extension did it" unattributable, so switch off whatever is
        // installed for the duration and put it back afterwards.
        preExistingExtensions = ExtensionManager.shared.installedExtensions
            .map { (id: $0.id, name: $0.displayName, wasEnabled: $0.enabled) }
        for existing in preExistingExtensions where existing.wasEnabled {
            ExtensionManager.shared.setEnabled(false, forExtensionID: existing.id)
        }
    }

    override func tearDown() async throws {
        if packagesDirectory != nil {
            SettingsManager.shared.adBlockEnabled = savedAdBlockEnabled
            for existing in preExistingExtensions where existing.wasEnabled {
                ExtensionManager.shared.setEnabled(true, forExtensionID: existing.id)
            }
        }
    }

    /// One line naming the user's own installed extensions, stamped into every
    /// evidence file.
    private var preExistingDescription: String {
        let described = preExistingExtensions
            .map { "\($0.name) [\($0.id)] was\($0.wasEnabled ? "" : " not") enabled" }
            .joined(separator: ", ")
        return described.isEmpty ? "none installed" : described
    }

    // MARK: - Evidence

    private struct Check: Codable {
        let name: String
        let observed: String
        let pass: Bool
    }

    private struct Evidence: Codable {
        let candidate: String
        let packageForm: String
        let displayName: String?
        let version: String?
        /// The user's own installed extensions at the start of the run, all
        /// disabled for its duration (see `setUp`).
        var preExisting: String = ""
        let loadErrors: [String]
        var runtimeErrors: [String]
        var checks: [Check]
        var verdict: String
    }

    private func writeEvidence(_ evidence: Evidence) throws {
        var evidence = evidence
        evidence.preExisting = preExistingDescription
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = evidenceDirectory.appendingPathComponent("\(evidence.candidate).json")
        try encoder.encode(evidence).write(to: url, options: .atomic)
    }

    // MARK: - Harness plumbing

    private var browserViewModel: BrowserViewModel {
        get throws {
            guard let viewModel = BrowserViewModel.windowViewModels.values.first(where: { !$0.isPrivateMode }) else {
                throw HarnessFailure.noWindow
            }
            return viewModel
        }
    }

    private enum HarnessFailure: Error {
        case noWindow
        case packageMissing(String)
        case loadFailed(archive: String, unpacked: String?)
        case tabNeverLoaded(String)
    }

    /// Polls `condition` on the main actor until it's true or `timeout`
    /// elapses. Sleeping (rather than blocking) is what lets WebKit and the
    /// extension's background machinery make progress between polls.
    private func poll(timeout: TimeInterval, every interval: TimeInterval = 0.1,
                      until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        return condition()
    }

    /// Loads one candidate through the app's real install path. Tries the
    /// archive file first (what "Load Extension…" hands over), then the
    /// pre-unzipped sibling directory. Returns the loaded extension plus which
    /// form succeeded, so the evidence records it.
    private func loadCandidate(_ key: String) async throws -> (ExtensionManager.LoadedExtension, String) {
        let fileManager = FileManager.default
        let archive = ["xpi", "zip"]
            .map { packagesDirectory.appendingPathComponent("\(key).\($0)") }
            .first { fileManager.fileExists(atPath: $0.path) }
        let unpacked = packagesDirectory.appendingPathComponent("\(key).unpacked", isDirectory: true)
        let hasUnpacked = fileManager.fileExists(atPath: unpacked.path)
        guard archive != nil || hasUnpacked else { throw HarnessFailure.packageMissing(key) }

        var archiveError = "no archive present"
        if let archive {
            do {
                return (try await ExtensionManager.shared.loadExtension(from: archive), "archive (\(archive.lastPathComponent))")
            } catch {
                archiveError = String(describing: error)
            }
        }
        if hasUnpacked {
            do {
                return (try await ExtensionManager.shared.loadExtension(from: unpacked), "unpacked directory")
            } catch {
                throw HarnessFailure.loadFailed(archive: archiveError, unpacked: String(describing: error))
            }
        }
        throw HarnessFailure.loadFailed(archive: archiveError, unpacked: nil)
    }

    /// Opens a real tab in the hosted app's window and waits for the page to
    /// finish loading. The tab is created AFTER the candidate loads, so the
    /// controller already knows about the extension when `tabOpened` announces
    /// the tab and content scripts inject on the initial navigation.
    private func openProbeTab(url: URL) async throws -> Tab {
        let tab = try browserViewModel.tabManager.newTab(url: url)
        let loaded = await poll(timeout: 30) {
            tab.webView != nil && tab.webView?.isLoading == false && tab.webView?.url != nil
        }
        guard loaded else {
            try browserViewModel.tabManager.closeTab(tab)
            throw HarnessFailure.tabNeverLoaded(url.absoluteString)
        }
        // One extra beat: `isLoading` clears at navigation-finish, which is
        // slightly before document_end content scripts have run.
        try await Task.sleep(nanoseconds: 500_000_000)
        return tab
    }

    private func closeProbeTab(_ tab: Tab) {
        try? browserViewModel.tabManager.closeTab(tab)
    }

    /// Holds a completion handler's answer for `evaluate`'s deadline loop.
    private final class ResultBox { var value: String? }

    /// Runs `body` as an async function in the page's JS world and returns its
    /// result, stringified, so evidence files hold exactly what was observed.
    ///
    /// Deliberately the completion-handler form behind a deadline rather than
    /// a bare `await`: when a web content process dies mid-call — which the
    /// Bitwarden popup did on this runtime — the async form's continuation is
    /// never resumed and the WHOLE ROUND hangs on one candidate, taking every
    /// later candidate's evidence with it. A candidate that wedges its web
    /// view is a result about that candidate; it is not a reason to lose the
    /// others, so the wait ends and says so.
    @discardableResult
    private func evaluate(_ body: String, arguments: [String: Any] = [:],
                          in webView: WKWebView, timeout: TimeInterval = 30) async -> String {
        let box = ResultBox()
        let work = Task { @MainActor in
            do {
                let value = try await webView.callAsyncJavaScript(
                    body, arguments: arguments, in: nil, contentWorld: .page)
                box.value = value.map { String(describing: $0) } ?? "null"
            } catch {
                box.value = "js-error: \(error.localizedDescription)"
            }
        }
        let answered = await poll(timeout: timeout) { box.value != nil }
        if !answered { work.cancel() }
        return answered ? (box.value ?? "null") : "js-timeout: no answer in \(Int(timeout))s"
    }

    /// The ad-request battery shared by the baseline and every content
    /// blocker: `no-cors` fetches from page JS; resolving (opaque) means the
    /// request went through, rejecting means something blocked it.
    ///
    /// A battery, not one URL, because WebKit ITSELF blocks some canonical ad
    /// hosts on this OS (the doubleclick probe came back blocked with no
    /// extension loaded — see 00-baseline evidence). Real ad hosts sit next
    /// to EasyList-bait paths on a benign host (httpbin is in nobody's
    /// tracker list, but `/advertisement.js`-style generic path rules match
    /// it third-party) and one control URL no list should ever touch. A
    /// blocker is judged ONLY on URLs the platform demonstrably let through
    /// moments earlier in the same test.
    ///
    /// Round 1's battery was ONLY the generic half below, and that is half of
    /// why it called uBO Lite a failure: a modern MV3 blocker ships converted
    /// DNR rules, not a filter list, and none of its 18,380 rules happen to
    /// name `/advertisement.js`. So the battery now also carries URLs built
    /// from rules uBO Lite DEMONSTRABLY ships (rule indices from the
    /// diagnosis round's read of its own `rulesets/main/*.json`), which is
    /// what makes "blocked nothing" mean "the blocker did nothing" rather
    /// than "we asked about rules it does not have".
    private static let hostProbeURLs: [String: String] = [
        "doubleclick": "https://static.doubleclick.net/instream/ad_status.js",
        "googlesyndication": "https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js",
        "google-analytics": "https://www.google-analytics.com/analytics.js",
        "generic advertisement.js": "https://httpbin.org/anything/advertisement.js",
        "generic adsbygoogle.js": "https://httpbin.org/anything/adsbygoogle.js",
    ]
    private static let ruleDerivedProbeURLs: [String: String] = [
        "ublock-filters#2144": "https://httpbin.org/anything/webtracking.min.js",
        "easylist#442": "https://httpbin.org/anything/-ad-manager/probe",
        "easyprivacy#618": "https://httpbin.org/anything/probe.beacon.min.js",
    ]
    private static let blockerProbeURLs: [String: String] =
        hostProbeURLs.merging(ruleDerivedProbeURLs) { first, _ in first }
    private static let adProbeURLs = blockerProbeURLs.values.sorted() + [controlURL]
    private static let controlURL = "https://httpbin.org/robots.txt"

    /// url → the probe name it was chosen for, so evidence lines read
    /// "easylist#442=blocked" rather than a bare URL.
    private static let probeNames: [String: String] =
        Dictionary(uniqueKeysWithValues: blockerProbeURLs.map { ($0.value, $0.key) })
            .merging([controlURL: "control"]) { _, new in new }

    private static func batteryLine(_ map: [String: String]) -> String {
        map.sorted { (probeNames[$0.key] ?? $0.key) < (probeNames[$1.key] ?? $1.key) }
            .map { "\(probeNames[$0.key] ?? $0.key)=\($0.value)" }
            .joined(separator: " | ")
    }

    /// Runs the battery in `tab` and returns url → "fetched"/"blocked".
    private func runAdBattery(in tab: Tab) async -> [String: String] {
        let body = """
            const out = {};
            for (const u of urls) {
                try { await fetch(u, {mode: 'no-cors', cache: 'no-store'}); out[u] = 'fetched'; }
                catch (e) { out[u] = 'blocked'; }
            }
            return JSON.stringify(out);
            """
        // Through the bounded `evaluate`: a battery whose page hangs must end
        // as one unreadable line in the timeline, not as a stuck round.
        let json = await evaluate(body, arguments: ["urls": Self.adProbeURLs], in: tab.webView!, timeout: 60)
        guard let data = json.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else {
            return ["error": json]
        }
        return map
    }

    /// `String(describing:)` on these yields just "WKNSError"; the domain,
    /// code and description are where the actual reason lives.
    private func describeErrors(_ errors: [any Error]) -> [String] {
        errors.map { error in
            let nsError = error as NSError
            return "\(nsError.domain)#\(nsError.code): \(nsError.localizedDescription)"
                + (nsError.userInfo.isEmpty ? "" : " \(nsError.userInfo)")
        }
    }

    private func loadErrorStrings(for loaded: ExtensionManager.LoadedExtension) -> [String] {
        describeErrors(loaded.webExtension.errors)
    }

    /// Shared load → probe → evidence → remove flow. `probes` receives the
    /// loaded extension and an already-loaded probe tab on `probeURL`, and
    /// returns the checks plus a verdict line.
    private func runCandidate(
        _ key: String,
        probeURL: URL = URL(string: "https://example.com/")!,
        probes: (ExtensionManager.LoadedExtension, Tab) async throws -> ([Check], String)
    ) async throws {
        let (loaded, form) = try await loadCandidate(key)
        var evidence = Evidence(
            candidate: key,
            packageForm: form,
            displayName: loaded.webExtension.displayName,
            version: loaded.webExtension.version,
            loadErrors: loadErrorStrings(for: loaded),
            runtimeErrors: [],
            checks: [],
            verdict: ""
        )
        defer {
            // Runtime errors accumulate on the CONTEXT while the extension
            // runs — capture them before remove() unloads it.
            evidence.runtimeErrors = describeErrors(loaded.context.errors)
            ExtensionManager.shared.remove(extensionID: loaded.id)
            try? writeEvidence(evidence)
        }

        let tab = try await openProbeTab(url: probeURL)
        defer { closeProbeTab(tab) }

        let (checks, verdict) = try await probes(loaded, tab)
        evidence.checks = checks
        evidence.verdict = verdict
    }

    // MARK: - Baseline

    /// No extension loaded: enough of the battery must be reachable for
    /// blocker verdicts to mean anything. This validates the harness's own
    /// probe (and documents what the PLATFORM blocks on its own), it does not
    /// judge any candidate.
    func test00BaselineAdRequestSucceedsWithNoExtension() async throws {
        let tab = try await openProbeTab(url: URL(string: "https://example.com/")!)
        defer { closeProbeTab(tab) }
        let battery = await runAdBattery(in: tab)
        let fetchable = battery.filter { $0.value == "fetched" }.keys.sorted()
        let checks = battery.sorted { $0.key < $1.key }.map {
            Check(name: "baseline fetch \($0.key)", observed: $0.value, pass: $0.value == "fetched")
        }
        try writeEvidence(Evidence(
            candidate: "00-baseline",
            packageForm: "none",
            displayName: nil, version: nil, loadErrors: [], runtimeErrors: [],
            checks: checks,
            verdict: "platform lets through: \(fetchable.joined(separator: ", "))"
        ))
        XCTAssertEqual(battery[Self.controlURL], "fetched",
                       "harness baseline: control URL must be reachable with no extension loaded")
        XCTAssertGreaterThan(fetchable.filter { $0 != Self.controlURL }.count, 0,
                             "harness baseline: at least one ad URL must survive the platform for blocker probes to discriminate")
    }

    /// Known-good fixture written by the harness itself, exercising every
    /// probe channel: content script → DOM marker, background script → badge
    /// text, popup → loadable popup web view. If THIS fails, the runtime or
    /// harness is at fault and every candidate verdict below is suspect.
    func test01FixtureExtensionValidatesHarness() async throws {
        let fixtureDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cherry-fixture-extension-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureDir) }

        let manifest = """
            {
              "manifest_version": 3,
              "name": "Cherry Harness Fixture",
              "version": "1.0",
              "description": "Proves content script, background, and popup channels are observable.",
              "host_permissions": ["<all_urls>"],
              "content_scripts": [{"matches": ["<all_urls>"], "js": ["content.js"], "run_at": "document_end"}],
              "background": {"scripts": ["bg.js"], "service_worker": "bg.js", "persistent": false},
              "action": {"default_popup": "popup.html", "default_title": "Fixture"}
            }
            """
        try manifest.write(to: fixtureDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "document.documentElement.setAttribute('data-cherry-fixture', 'injected');"
            .write(to: fixtureDir.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)
        try "(globalThis.browser ?? globalThis.chrome).action.setBadgeText({ text: 'OK' });"
            .write(to: fixtureDir.appendingPathComponent("bg.js"), atomically: true, encoding: .utf8)
        try "<!DOCTYPE html><html><body id=\"fixture-popup\">fixture</body></html>"
            .write(to: fixtureDir.appendingPathComponent("popup.html"), atomically: true, encoding: .utf8)

        let loaded = try await ExtensionManager.shared.loadExtension(from: fixtureDir)
        var checks: [Check] = []
        defer {
            ExtensionManager.shared.remove(extensionID: loaded.id)
            try? writeEvidence(Evidence(
                candidate: "01-fixture", packageForm: "unpacked directory",
                displayName: loaded.webExtension.displayName, version: loaded.webExtension.version,
                loadErrors: loadErrorStrings(for: loaded),
                runtimeErrors: describeErrors(loaded.context.errors),
                checks: checks,
                verdict: checks.allSatisfy(\.pass) ? "harness channels all observable" : "HARNESS BROKEN"
            ))
        }

        let tab = try await openProbeTab(url: URL(string: "https://example.com/")!)
        defer { closeProbeTab(tab) }

        let marker = await evaluate(
            "return document.documentElement.getAttribute('data-cherry-fixture');",
            in: tab.webView!
        )
        checks.append(Check(name: "content script sets DOM marker", observed: marker, pass: marker == "injected"))

        let badgeAppeared = await poll(timeout: 10) {
            loaded.context.action(for: nil)?.badgeText == "OK"
        }
        checks.append(Check(
            name: "background script sets badge",
            observed: loaded.context.action(for: nil)?.badgeText ?? "nil",
            pass: badgeAppeared
        ))

        var popupObserved = "no action"
        if let action = loaded.context.action(for: nil) {
            let popupWebView = action.popupWebView
            _ = await poll(timeout: 10) { popupWebView?.isLoading == false && popupWebView?.url != nil }
            if let popupWebView {
                popupObserved = await evaluate("return document.body ? document.body.id : 'no body';", in: popupWebView)
            }
        }
        checks.append(Check(name: "popup web view loads", observed: popupObserved, pass: popupObserved == "fixture-popup"))

        XCTAssertTrue(checks.allSatisfy(\.pass), "fixture must pass every channel: \(checks)")
    }

    // MARK: - Content blockers ("works" = the ad request is actually blocked)

    /// Self-controlled A/B: the same battery runs in a fresh tab immediately
    /// BEFORE the candidate loads and again in another fresh tab AFTER, in
    /// the same test. "Works" = at least one URL the platform let through in
    /// the before-run comes back blocked in the after-run; the control URL
    /// must stay fetchable (a blocker that kills everything is broken, not
    /// working).
    ///
    /// The settle window is POLLED, not slept through, for the second reason
    /// round 1 got uBO Lite wrong: it probed once at t+8s. A converted-rule
    /// blocker is not finished warming up then — the diagnosis round watched
    /// uBO Lite's first block land at t+10s and its last ruleset come into
    /// force around t+90s. So the battery re-runs in a fresh tab every
    /// `pollInterval` until every discriminator is blocked or `settleWindow`
    /// runs out, and the whole timeline goes into the evidence: the verdict
    /// needs the first block, the caveat the wizard shows needs the last one.
    private func runContentBlockerCandidate(_ key: String,
                                            settleWindow: TimeInterval = 120,
                                            pollInterval: TimeInterval = 10) async throws {
        let beforeTab = try await openProbeTab(url: URL(string: "https://example.com/")!)
        let before = await runAdBattery(in: beforeTab)
        closeProbeTab(beforeTab)
        let discriminators = before.filter { $0.value == "fetched" && $0.key != Self.controlURL }.keys.sorted()

        let (loaded, form) = try await loadCandidate(key)
        var evidence = Evidence(
            candidate: key, packageForm: form,
            displayName: loaded.webExtension.displayName,
            version: loaded.webExtension.version,
            loadErrors: loadErrorStrings(for: loaded),
            runtimeErrors: [], checks: [], verdict: ""
        )
        defer {
            evidence.runtimeErrors = describeErrors(loaded.context.errors)
            ExtensionManager.shared.remove(extensionID: loaded.id)
            try? writeEvidence(evidence)
        }

        // Blockers compile/register their rulesets asynchronously after load,
        // and how long that takes is itself a result. Each pass probes from a
        // fresh tab so rules apply from that tab's very first request.
        var timeline: [String] = []
        var after: [String: String] = [:]
        var everBlocked: Set<String> = []
        var firstBlock = "nothing blocked within \(Int(settleWindow))s"
        var lastNewBlock = ""
        var elapsed: TimeInterval = 0
        while elapsed < settleWindow {
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            elapsed += pollInterval
            let afterTab = try await openProbeTab(url: URL(string: "https://example.com/")!)
            after = await runAdBattery(in: afterTab)
            closeProbeTab(afterTab)
            timeline.append("t+\(Int(elapsed))s: \(Self.batteryLine(after))")
            let blockedNow = Set(discriminators.filter { after[$0] == "blocked" })
            if !blockedNow.subtracting(everBlocked).isEmpty {
                if everBlocked.isEmpty { firstBlock = "t+\(Int(elapsed))s" }
                lastNewBlock = "t+\(Int(elapsed))s"
                everBlocked.formUnion(blockedNow)
            }
            if everBlocked.count == discriminators.count { break }
        }

        evidence.checks.append(Check(
            name: "battery before load (platform only)",
            observed: Self.batteryLine(before),
            pass: !discriminators.isEmpty))
        evidence.checks.append(Check(
            name: "battery after load, one line per \(Int(pollInterval))s of warm-up",
            observed: timeline.joined(separator: "\n"),
            pass: true))
        evidence.checks.append(Check(
            name: "warm-up: first block / last newly blocked URL",
            observed: "first \(firstBlock)\(lastNewBlock.isEmpty ? "" : ", last new \(lastNewBlock)")",
            pass: !everBlocked.isEmpty))

        // Blocking anywhere in the window counts, not just in the last pass:
        // a rule that bites at t+10s has done its job even if a later pass
        // races a tab that opened before its ruleset re-registered.
        let newlyBlocked = discriminators.filter { everBlocked.contains($0) }
        evidence.checks.append(Check(
            name: "ad URLs newly blocked by the extension",
            observed: newlyBlocked.isEmpty ? "none"
                : newlyBlocked.map { Self.probeNames[$0] ?? $0 }.joined(separator: ", "),
            pass: !newlyBlocked.isEmpty))
        let controlSurvives = after[Self.controlURL] == "fetched"
        evidence.checks.append(Check(
            name: "control URL still fetchable",
            observed: after[Self.controlURL] ?? "missing",
            pass: controlSurvives))

        // Diagnostic, not a verdict input: the popup web view executes in the
        // extension's own origin, so it can ask the DNR API which static
        // rulesets actually registered — the difference between "rules never
        // enabled" and "rules enabled but ignored" is what the reject
        // evidence owes the next person.
        if let popupWebView = loaded.context.action(for: nil)?.popupWebView {
            _ = await poll(timeout: 10) { popupWebView.isLoading == false && popupWebView.url != nil }
            let rulesets = await evaluate("""
                const api = globalThis.browser ?? globalThis.chrome;
                if (!api?.declarativeNetRequest?.getEnabledRulesets) return 'DNR API unavailable in popup';
                try { return JSON.stringify(await api.declarativeNetRequest.getEnabledRulesets()); }
                catch (e) { return 'DNR query failed: ' + e; }
                """, in: popupWebView)
            evidence.checks.append(Check(name: "enabled DNR rulesets (diagnostic)", observed: rulesets, pass: true))
        }

        // Attribution leg: WebKit's own tracker blocking flapped on the real
        // ad hosts between tests in run 1, so "blocked after load" alone
        // could be the platform, not the extension. Unload the candidate and
        // re-run the battery — if the newly-blocked URLs become fetchable
        // again the moment the extension is gone, the blocking was its doing.
        var attributionHolds = true
        if !newlyBlocked.isEmpty {
            ExtensionManager.shared.setEnabled(false, forExtensionID: loaded.id)
            try await Task.sleep(nanoseconds: 5_000_000_000)
            let unloadedTab = try await openProbeTab(url: URL(string: "https://example.com/")!)
            defer { closeProbeTab(unloadedTab) }
            let unloaded = await runAdBattery(in: unloadedTab)
            let restored = newlyBlocked.filter { unloaded[$0] == "fetched" }
            attributionHolds = !restored.isEmpty
            let restoredNames = restored.map { Self.probeNames[$0] ?? $0 }.joined(separator: ", ")
            evidence.checks.append(Check(
                name: "unloading restores fetchability (attribution)",
                observed: Self.batteryLine(unloaded)
                    + " || restored: " + (restoredNames.isEmpty ? "none" : restoredNames),
                pass: attributionHolds))
        }

        evidence.verdict = newlyBlocked.isEmpty
            ? "FAILS — loads but blocks nothing the platform let through in \(Int(settleWindow))s"
            : !controlSurvives ? "BROKEN — blocks the control URL too"
            : attributionHolds ? "WORKS — blocks \(newlyBlocked.count)/\(discriminators.count) discriminator URLs, first at \(firstBlock), restored on unload"
            : "INCONCLUSIVE — URLs stayed blocked after unload; platform interference suspected"
    }

    func test10UBlockOrigin() async throws {
        try await runContentBlockerCandidate("ublock-origin")
    }

    func test11UBlockOriginLiteSafariBuild() async throws {
        try await runContentBlockerCandidate("uBOLite.safari")
    }

    func test12UBlockOriginLiteFirefoxBuild() async throws {
        try await runContentBlockerCandidate("uBOLite.firefox")
    }

    // MARK: - Dark Reader ("works" = page is actually restyled dark)

    func test20DarkReader() async throws {
        try await runCandidate("darkreader") { _, tab in
            var checks: [Check] = []
            var styleCount = "0"
            let appeared = await self.pollJS(timeout: 15, in: tab.webView!, body:
                "return String(document.querySelectorAll('style.darkreader').length);"
            ) { observed in styleCount = observed; return (Int(observed) ?? 0) > 0 }
            checks.append(Check(name: "darkreader <style> elements present", observed: styleCount, pass: appeared))

            let background = await self.evaluate(
                "return getComputedStyle(document.body).backgroundColor;", in: tab.webView!)
            // example.com's stock background is white-ish; Dark Reader must
            // have changed it to something dark.
            let darkened = appeared && !background.contains("255, 255, 255")
            checks.append(Check(name: "body background no longer white", observed: background, pass: darkened))
            return (checks, darkened ? "WORKS — page restyled dark" : "FAILS — no dark restyle observed")
        }
    }

    /// Polls a JS expression until `accept` returns true. Returns whether it
    /// ever did; the last observed value is delivered through `accept`.
    private func pollJS(timeout: TimeInterval, in webView: WKWebView, body: String,
                        accept: (String) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let observed = await evaluate(body, in: webView)
            if accept(observed) { return true }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return false
    }

    // MARK: - Bitwarden ("works" = popup UI actually renders; content script present)

    func test30Bitwarden() async throws {
        try await runCandidate("bitwarden-password-manager") { loaded, tab in
            var checks: [Check] = []

            let action = loaded.context.action(for: nil)
            checks.append(Check(name: "toolbar action with popup exists",
                                observed: action.map { "presentsPopup=\($0.presentsPopup)" } ?? "no action",
                                pass: action?.presentsPopup == true))

            var popupState = "no popup web view"
            var popupRendered = false
            if let popupWebView = action?.popupWebView {
                _ = await self.poll(timeout: 20) { popupWebView.isLoading == false && popupWebView.url != nil }
                // Run 1 accepted a 3-element, zero-text body here — that is
                // Angular's UNBOOTED app shell, not a working popup. Rendered
                // means dozens of elements and actual UI text (the logged-out
                // popup shows "Log in"/"Create account"), and it gets up to
                // 30s to boot before we call it.
                popupRendered = await self.pollJS(timeout: 30, in: popupWebView, body: """
                    return JSON.stringify({
                        elements: document.body ? document.body.querySelectorAll('*').length : 0,
                        text: document.body ? document.body.innerText.slice(0, 200) : ''
                    });
                    """) { observed in
                        popupState = observed
                        let hasBody = observed.range(of: "\"elements\":(\\d{2,})", options: .regularExpression) != nil
                        let hasText = !observed.contains("\"text\":\"\"")
                        return hasBody && hasText
                    }
            }
            checks.append(Check(name: "popup boots real UI (elements + visible text)",
                                observed: popupState, pass: popupRendered))

            // The autofill content script's presence is observable via the
            // attributes/elements Bitwarden leaves in the page. Record
            // whatever is there; presence is informative, absence damning.
            let contentMarker = await self.evaluate("""
                const attrs = [];
                for (const el of document.querySelectorAll('*')) {
                    for (const a of el.attributes) {
                        if (a.name.includes('bw') || a.name.includes('bitwarden')) attrs.push(a.name);
                    }
                }
                return JSON.stringify(attrs);
                """, in: tab.webView!)
            checks.append(Check(name: "content script artifacts in page (informative)",
                                observed: contentMarker, pass: true))

            let verdict = popupRendered
                ? "WORKS (popup renders) — verify login flow manually before shipping"
                : "FAILS — popup does not render"
            return (checks, verdict)
        }
    }

    // MARK: - Privacy Badger ("works" = GPC/DNT signals actually attached)

    func test40PrivacyBadger() async throws {
        try await runCandidate("privacy-badger17") { _, tab in
            var checks: [Check] = []
            // Privacy Badger's baseline observable effect is the Global
            // Privacy Control header it attaches to every request (its
            // tracker-learning takes days of browsing and can't be probed
            // here). httpbin echoes request headers back.
            let headers = await self.evaluate("""
                try {
                    const r = await fetch('https://httpbin.org/headers', {cache: 'no-store'});
                    const j = await r.json();
                    return JSON.stringify(j.headers);
                } catch (e) { return 'fetch failed: ' + e; }
                """, in: tab.webView!)
            let gpcPresent = headers.contains("Sec-Gpc") || headers.contains("Sec-GPC") || headers.contains("Dnt")
            checks.append(Check(name: "GPC/DNT header attached to requests", observed: headers, pass: gpcPresent))
            let verdict = gpcPresent
                ? "PARTIAL — GPC signal works; tracker blocking unverifiable in harness"
                : "FAILS — no observable effect on requests"
            return (checks, verdict)
        }
    }

    // MARK: - Vimium ("works" = a real keypress moves the page)

    /// Sends one key through AppKit rather than through `dispatchEvent`.
    ///
    /// This is the difference that decides Vimium: every one of its handlers
    /// is wrapped in `forTrusted` (`lib/utils.js`), which drops any event
    /// whose `isTrusted` is false — so the synthetic `KeyboardEvent` round 1
    /// dispatched could never have produced hints, no matter how well Vimium
    /// worked. An `NSEvent` delivered to the window becomes a REAL keydown in
    /// the page, `isTrusted` and all, which is exactly what Vimium is waiting
    /// for. Returns what happened, for the evidence.
    ///
    /// Delivery needs three things, and the first attempt at this only had
    /// one of them: the app has to be ACTIVE, the window has to be KEY, and
    /// the web view has to be first responder. With `windowIsKey=false` the
    /// event is simply dropped, and the resulting "Vimium did nothing" says
    /// something about the harness, not about Vimium — so all three are
    /// established and reported before any key goes out.
    @MainActor
    private func sendTrustedKey(_ character: String, keyCode: UInt16, to webView: WKWebView) async -> String {
        guard let window = webView.window else { return "web view is not in a window — cannot send a key" }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        let accepted = window.makeFirstResponder(webView)
        let becameKey = await poll(timeout: 5) { window.isKeyWindow && NSApplication.shared.isActive }
        guard becameKey else {
            return "window never became key (isKey=\(window.isKeyWindow), appActive=\(NSApplication.shared.isActive))"
                + " — a key event would be dropped, so none was sent"
        }
        let focused = await evaluate("return String(document.hasFocus());", in: webView, timeout: 5)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                             timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: window.windowNumber, context: nil,
                             characters: character, charactersIgnoringModifiers: character,
                             isARepeat: false, keyCode: keyCode)
        }
        guard let down = event(.keyDown), let up = event(.keyUp) else { return "could not build an NSEvent" }
        window.sendEvent(down)
        window.sendEvent(up)
        let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
        return "sent '\(character)' to \(responder) (makeFirstResponder=\(accepted), windowIsKey=true, documentHasFocus=\(focused))"
    }

    func test50Vimium() async throws {
        try await runCandidate("vimium-ff") { _, tab in
            var checks: [Check] = []
            let webView = tab.webView!

            // 1. Did the content scripts arrive at all? `vimium.css` defines a
            //    custom property on :root and a `.vimium-reset` rule that
            //    forces a div to `display: inline` — neither is true of a page
            //    the CSS never reached.
            var cssState = ""
            let cssApplied = await self.pollJS(timeout: 15, in: webView, body: """
                const probe = document.createElement('div');
                probe.className = 'vimium-reset';
                document.body.appendChild(probe);
                const display = getComputedStyle(probe).display;
                probe.remove();
                return JSON.stringify({
                    rootVar: getComputedStyle(document.documentElement).getPropertyValue('--vimium-background-color').trim(),
                    resetDivDisplay: display
                });
                """) { observed in cssState = observed; return observed.contains("\"resetDivDisplay\":\"inline\"") }
            checks.append(Check(name: "vimium.css injected (:root var + .vimium-reset rule)",
                                observed: cssState, pass: cssApplied))

            let artifacts = await self.evaluate("""
                const hits = [];
                for (const el of document.querySelectorAll('*')) {
                    if ((el.id + ' ' + el.className).match(/vimium/i)) hits.push(el.tagName + '#' + el.id + '.' + el.className);
                    if (el.shadowRoot) hits.push('shadow root on ' + el.tagName);
                }
                return JSON.stringify(hits);
                """, in: webView)
            checks.append(Check(name: "content script DOM artifacts at rest (informative)",
                                observed: artifacts, pass: true))

            // 2. Make the page tall enough to scroll and give Vimium's
            //    background time to answer its content script's "am I enabled
            //    for this URL?" query — it ignores keys until that lands.
            let prepared = await self.evaluate("""
                if (!document.getElementById('cherry-tall')) {
                    const filler = document.createElement('div');
                    filler.id = 'cherry-tall';
                    filler.style.height = '5000px';
                    document.body.appendChild(filler);
                }
                window.scrollTo(0, 0);
                await new Promise(r => setTimeout(r, 3000));
                return JSON.stringify({scrollHeight: document.documentElement.scrollHeight, scrollY: window.scrollY});
                """, in: webView)
            checks.append(Check(name: "page made scrollable before the keypress",
                                observed: prepared, pass: prepared.contains("\"scrollY\":0")))

            // 3. 'j' is Vimium's scrollDown. A trusted keydown that scrolls
            //    the page is Vimium doing its actual job: nothing else on
            //    example.com binds 'j', and the page does not scroll itself.
            let sendState = await self.sendTrustedKey("j", keyCode: 38, to: webView)
            checks.append(Check(name: "trusted 'j' delivered through AppKit", observed: sendState,
                                pass: sendState.hasPrefix("sent")))
            var scrollState = ""
            let scrolled = await self.pollJS(timeout: 8, in: webView, body:
                "return JSON.stringify({scrollY: window.scrollY});"
            ) { observed in scrollState = observed; return !observed.contains("\"scrollY\":0") }
            checks.append(Check(name: "'j' scrolls the page (Vimium's scrollDown)",
                                observed: scrollState, pass: scrolled))

            // 4. 'f' is link hints: example.com has exactly one link, so a
            //    working Vimium paints exactly one hint marker over it.
            _ = await self.sendTrustedKey("f", keyCode: 3, to: webView)
            var hintState = ""
            let hinted = await self.pollJS(timeout: 8, in: webView, body: """
                const markers = document.querySelectorAll('.vimiumHintMarker, .internal-vimium-hint-marker');
                return JSON.stringify({
                    markers: markers.length,
                    text: markers.length ? markers[0].innerText : '',
                    containers: document.querySelectorAll('[class*=vimium], [id*=vimium]').length
                });
                """) { observed in hintState = observed; return !observed.contains("\"markers\":0") }
            checks.append(Check(name: "'f' paints link hints", observed: hintState, pass: hinted))
            // Leave the page in its normal mode whatever happened.
            _ = await self.sendTrustedKey("\u{1B}", keyCode: 53, to: webView)

            let verdict: String
            if cssApplied && scrolled && hinted {
                verdict = "WORKS — content scripts inject and real keypresses scroll and paint hints"
            } else if cssApplied && scrolled {
                verdict = "PARTIAL — keyboard scrolling works, link hints did not appear"
            } else if cssApplied {
                verdict = "INCONCLUSIVE — content scripts inject but no keypress produced an effect"
            } else {
                verdict = "FAILS — content scripts never reached the page"
            }
            return (checks, verdict)
        }
    }

    // MARK: - Simple Translate ("works" = popup renders translation UI)

    func test60SimpleTranslate() async throws {
        try await runCandidate("simple-translate") { loaded, tab in
            var checks: [Check] = []
            let action = loaded.context.action(for: nil)
            var popupState = "no popup web view"
            if let popupWebView = action?.popupWebView {
                _ = await self.poll(timeout: 20) { popupWebView.isLoading == false && popupWebView.url != nil }
                try await Task.sleep(nanoseconds: 2_000_000_000)
                popupState = await self.evaluate("""
                    return JSON.stringify({
                        elements: document.body ? document.body.querySelectorAll('*').length : 0,
                        hasTextarea: !!document.querySelector('textarea'),
                        text: document.body ? document.body.innerText.slice(0, 120) : ''
                    });
                    """, in: popupWebView)
            }
            let rendered = popupState.contains("\"hasTextarea\":true")
                || (popupState.contains("\"elements\":") && !popupState.contains("\"elements\":0"))
            checks.append(Check(name: "popup renders translation UI", observed: popupState, pass: rendered))

            // Core-function probe: type into the popup's textarea and wait
            // for a translation to come back. This exercises the extension's
            // real work end to end (background fetch to the translate API
            // included), not just its markup.
            var translation = "popup never rendered"
            var translated = false
            if rendered, let popupWebView = action?.popupWebView {
                // Spanish in, English out: with the target language defaulting
                // to this machine's English locale, an English input would come
                // back verbatim and be indistinguishable from a plain echo.
                // Seeing "morning"/"friend" in the popup after typing Spanish
                // proves a real round trip through the translation backend.
                translated = await self.pollJS(timeout: 20, in: popupWebView, body: """
                    const ta = document.querySelector('textarea');
                    if (!ta) return 'no textarea';
                    if (ta.value !== 'buenos días amigo') {
                        const setter = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value').set;
                        setter.call(ta, 'buenos días amigo');
                        ta.dispatchEvent(new Event('input', {bubbles: true}));
                    }
                    return document.body.innerText;
                    """) { observed in
                        translation = observed
                        return observed.lowercased().contains("morning") || observed.lowercased().contains("friend")
                    }
                checks.append(Check(name: "Spanish input yields English translation",
                                    observed: String(translation.suffix(160)), pass: translated))
            }

            // Selection-button probe: select text, fire mouseup, look for the
            // injected translate button.
            let selectionButton = await self.evaluate("""
                const range = document.createRange();
                range.selectNodeContents(document.querySelector('p') || document.body);
                getSelection().removeAllRanges();
                getSelection().addRange(range);
                document.dispatchEvent(new MouseEvent('mouseup', {bubbles: true}));
                await new Promise(r => setTimeout(r, 1500));
                return JSON.stringify(document.querySelectorAll('#simple-translate, [id*=simple-translate], [class*=simple-translate]').length);
                """, in: tab.webView!)
            checks.append(Check(name: "selection shows translate button", observed: selectionButton,
                                pass: (Int(selectionButton) ?? 0) > 0))

            let verdict: String
            if rendered && translated {
                verdict = "WORKS — popup renders and returns real translations"
            } else if rendered {
                verdict = "PARTIAL — popup renders but no translation came back"
            } else {
                verdict = "FAILS — no UI observable"
            }
            return (checks, verdict)
        }
    }

    // MARK: - Video Speed Controller ("works" = controller attaches to <video>)

    func test70VideoSpeedController() async throws {
        try await runCandidate("videospeed") { _, tab in
            var checks: [Check] = []
            var observed = ""
            // Run 1 used a stub data-URI whose metadata never loads; VSC
            // ignores videos that never fire media events, so use a real
            // (tiny) mp4 and give the media pipeline time to start.
            let attached = await self.pollJS(timeout: 25, in: tab.webView!, body: """
                if (!document.querySelector('video')) {
                    const v = document.createElement('video');
                    v.src = 'https://interactive-examples.mdn.mozilla.net/media/cc0-videos/flower.mp4';
                    v.muted = true;
                    v.controls = true;
                    document.body.appendChild(v);
                    v.load();
                }
                const v = document.querySelector('video');
                const holders = document.querySelectorAll('.vsc-controller, [class*=vsc-]');
                return JSON.stringify({vscElements: holders.length, readyState: v ? v.readyState : -1});
                """) { result in observed = result; return result.contains("\"vscElements\":") && !result.contains("\"vscElements\":0") }
            checks.append(Check(name: "vsc controller attaches to real <video>", observed: observed, pass: attached))
            return (checks, attached ? "WORKS — speed controller attaches to video elements"
                                     : "FAILS — content script never attaches")
        }
    }

    // MARK: - Open in Reader View ("works" = anything observable at all)

    func test80ReaderView() async throws {
        try await runCandidate("reader-view") { loaded, tab in
            var checks: [Check] = []
            let action = loaded.context.action(for: tab)
            checks.append(Check(name: "toolbar action exists",
                                observed: action.map { "presentsPopup=\($0.presentsPopup)" } ?? "no action",
                                pass: action != nil))

            // `performAction(for:)` is the programmatic equivalent of the
            // toolbar click (it marks a user gesture on the tab), so an
            // action-triggered page rewrite IS verifiable: the tab's document
            // or URL must visibly change afterwards.
            let beforeState = await self.evaluate(
                "return JSON.stringify({url: location.href, text: document.body.innerText.slice(0, 80)});",
                in: tab.webView!)
            loaded.context.performAction(for: tab)
            var afterState = beforeState
            let changed = await self.poll(timeout: 15) {
                let current = tab.webView?.url?.absoluteString ?? ""
                return current.contains("safari-web-extension") || current != "https://example.com/"
            }
            afterState = await self.evaluate(
                "return JSON.stringify({url: location.href, text: document.body.innerText.slice(0, 80)});",
                in: tab.webView!)
            checks.append(Check(name: "performAction rewrites the page (before → after)",
                                observed: "\(beforeState) → \(afterState)",
                                pass: changed || afterState != beforeState))

            let pass = changed || afterState != beforeState
            return (checks, pass ? "WORKS — action converts the page to reader view"
                                 : "FAILS — action fires but the page never changes")
        }
    }
}
