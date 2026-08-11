//
//  ExtensionGapDiagnosisTests.swift
//  Internet BrowserTests
//
//  Diagnostic harness for the extensions `ExtensionShortlist` rejected. Where
//  `ExtensionVerificationTests` answers "does this candidate do its job in
//  Cherry" with a yes/no, this file answers "WHICH mechanism failed" — the
//  step before deciding whether Cherry could bridge the gap.
//
//  Same shape as the verification harness, deliberately: opt-in via
//  CHERRY_EXT_VERIFY_DIR, one JSON evidence file per probe (written to
//  `<verify dir>/../diagnosis/`), and a failing probe is a RESULT, not a test
//  failure. XCTFail here means the harness broke.
//
//  These tests BUILD NOTHING. They install no bridge, patch no manifest in
//  the shipped packages, and leave no extension loaded. Where a probe needs a
//  modified package (the Vimium `file:///` question), it writes a throwaway
//  copy into the temporary directory and deletes it again — the shipped
//  artifact is never touched.
//

import XCTest
import WebKit
@testable import Cherry

@MainActor
final class ExtensionGapDiagnosisTests: XCTestCase {

    private var packagesDirectory: URL!
    private var diagnosisDirectory: URL!
    private var savedAdBlockEnabled = true
    /// Extensions already installed in the app's persistent index when the
    /// test started, disabled for the duration and restored in tearDown.
    private var preExistingExtensions: [(id: String, name: String)] = []

    override func setUp() async throws {
        let environment = ProcessInfo.processInfo.environment
        let path = environment["CHERRY_EXT_VERIFY_DIR"] ?? environment["TEST_RUNNER_CHERRY_EXT_VERIFY_DIR"]
        try XCTSkipIf(path == nil, "live extension diagnosis is opt-in")

        packagesDirectory = URL(fileURLWithPath: path!, isDirectory: true)
        diagnosisDirectory = packagesDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("diagnosis", isDirectory: true)
        try FileManager.default.createDirectory(at: diagnosisDirectory, withIntermediateDirectories: true)

        // Cherry's own blocker bakes its rule lists into every fresh web view,
        // so left on it would answer the ad battery for the extension. Off for
        // the duration; probe tabs are created after this point.
        savedAdBlockEnabled = SettingsManager.shared.adBlockEnabled
        SettingsManager.shared.adBlockEnabled = false

        // The hosted app shares the user's real Application Support extension
        // index, and it is NOT empty — the previous round left uBO Lite
        // installed there. An already-loaded content blocker would answer
        // every probe below, so switch off whatever is there for the duration
        // and put it back afterwards. Each finding records what was found, so
        // no verdict rests on an unexamined starting state.
        preExistingExtensions = ExtensionManager.shared.installedExtensions
            .filter(\.enabled)
            .map { (id: $0.id, name: $0.displayName) }
        for existing in preExistingExtensions {
            ExtensionManager.shared.setEnabled(false, forExtensionID: existing.id)
        }
    }

    override func tearDown() async throws {
        if packagesDirectory != nil {
            SettingsManager.shared.adBlockEnabled = savedAdBlockEnabled
            for existing in preExistingExtensions {
                ExtensionManager.shared.setEnabled(true, forExtensionID: existing.id)
            }
        }
    }

    private var preExistingNote: Note {
        Note(name: "extensions already installed in the app (disabled for this probe)",
             observed: preExistingExtensions.map { "\($0.name) [\($0.id)]" }
                 .joined(separator: ", ").ifEmpty("none"))
    }

    // MARK: - Evidence

    private struct Note: Codable {
        let name: String
        let observed: String
    }

    private struct Finding: Codable {
        let probe: String
        var notes: [Note]
        var conclusion: String
    }

    private func write(_ finding: Finding) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = diagnosisDirectory.appendingPathComponent("\(finding.probe).json")
        try? encoder.encode(finding).write(to: url, options: .atomic)
        print("[diagnosis] \(finding.probe): \(finding.conclusion)")
        for note in finding.notes {
            print("[diagnosis]   \(note.name) => \(note.observed.prefix(2000))")
        }
    }

    // MARK: - Plumbing (mirrors ExtensionVerificationTests)

    private enum HarnessFailure: Error {
        case noWindow
        case packageMissing(String)
        case loadFailed(String)
        case tabNeverLoaded(String)
    }

    private var browserViewModel: BrowserViewModel {
        get throws {
            guard let viewModel = BrowserViewModel.windowViewModels.values.first(where: { !$0.isPrivateMode }) else {
                throw HarnessFailure.noWindow
            }
            return viewModel
        }
    }

    private func poll(timeout: TimeInterval, every interval: TimeInterval = 0.1,
                      until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        return condition()
    }

    private func openProbeTab(url: URL = URL(string: "https://example.com/")!) async throws -> Tab {
        let tab = try browserViewModel.tabManager.newTab(url: url)
        let loaded = await poll(timeout: 30) {
            tab.webView != nil && tab.webView?.isLoading == false && tab.webView?.url != nil
        }
        guard loaded else {
            try browserViewModel.tabManager.closeTab(tab)
            throw HarnessFailure.tabNeverLoaded(url.absoluteString)
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        return tab
    }

    private func closeProbeTab(_ tab: Tab) {
        try? browserViewModel.tabManager.closeTab(tab)
    }

    @discardableResult
    private func evaluate(_ body: String, in webView: WKWebView) async -> String {
        do {
            let result = try await webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
            return result.map { String(describing: $0) } ?? "null"
        } catch {
            return "js-error: \(error.localizedDescription)"
        }
    }

    private func describeErrors(_ errors: [any Error]) -> String {
        errors.isEmpty ? "none" : errors.map { error in
            let nsError = error as NSError
            return "\(nsError.domain)#\(nsError.code): \(nsError.localizedDescription)"
        }.joined(separator: " | ")
    }

    private func loadCandidate(_ key: String) async throws -> ExtensionManager.LoadedExtension {
        let fileManager = FileManager.default
        let archive = ["xpi", "zip"]
            .map { packagesDirectory.appendingPathComponent("\(key).\($0)") }
            .first { fileManager.fileExists(atPath: $0.path) }
        let unpacked = packagesDirectory.appendingPathComponent("\(key).unpacked", isDirectory: true)

        if let archive, let loaded = try? await ExtensionManager.shared.loadExtension(from: archive) {
            return loaded
        }
        guard fileManager.fileExists(atPath: unpacked.path) else {
            throw HarnessFailure.packageMissing(key)
        }
        do {
            return try await ExtensionManager.shared.loadExtension(from: unpacked)
        } catch {
            throw HarnessFailure.loadFailed(String(describing: error))
        }
    }

    /// Writes an unpacked extension from a `[relative path: contents]` map and
    /// returns its directory. Caller deletes it.
    private func makeFixture(_ name: String, files: [String: String]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cherry-diag-\(name)-\(UUID().uuidString)", isDirectory: true)
        for (relative, contents) in files {
            let url = directory.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return directory
    }

    // MARK: - Request battery

    /// Two URLs the platform demonstrably lets through (`00-baseline`
    /// evidence) plus one control nothing should touch. Deliberately NOT the
    /// real ad hosts: WebKit's own tracker blocking already kills those, which
    /// is what produced the previous round's false positive.
    private static let adURLs = [
        "https://httpbin.org/anything/advertisement.js",
        "https://httpbin.org/anything/adsbygoogle.js",
    ]
    private static let controlURL = "https://httpbin.org/robots.txt"

    private func runBattery(in tab: Tab) async -> [String: String] {
        let body = """
            const out = {};
            for (const u of urls) {
                try { await fetch(u, {mode: 'no-cors', cache: 'no-store'}); out[u] = 'fetched'; }
                catch (e) { out[u] = 'blocked'; }
            }
            return JSON.stringify(out);
            """
        do {
            let result = try await tab.webView!.callAsyncJavaScript(
                body, arguments: ["urls": Self.adURLs + [Self.controlURL]], in: nil, contentWorld: .page)
            guard let json = result as? String, let data = json.data(using: .utf8),
                  let map = try? JSONDecoder().decode([String: String].self, from: data) else {
                return ["error": String(describing: result ?? "nil")]
            }
            return map
        } catch {
            return ["error": "js-error: \(error.localizedDescription)"]
        }
    }

    private func batteryLine(_ map: [String: String]) -> String {
        map.sorted { $0.key < $1.key }.map { "\($0.key.replacingOccurrences(of: "https://httpbin.org", with: ""))=\($0.value)" }
            .joined(separator: " | ")
    }

    /// Runs the battery in a FRESH tab, so rules apply from that tab's very
    /// first request rather than needing to affect an already-open page.
    private func runBatteryInFreshTab() async throws -> [String: String] {
        let tab = try await openProbeTab()
        defer { closeProbeTab(tab) }
        return await runBattery(in: tab)
    }

    // MARK: - Shared DNR question set

    /// Everything the popup can tell us about DNR, in one round trip. Runs in
    /// the extension's own origin, so the API is the real one the extension
    /// sees — not a page-world shim.
    private static let dnrInterrogation = """
        const api = globalThis.browser ?? globalThis.chrome;
        const dnr = api?.declarativeNetRequest;
        const out = {};
        out.apiPresent = !!dnr;
        if (!dnr) return JSON.stringify(out);
        out.methods = Object.keys(dnr).filter(k => typeof dnr[k] === 'function').sort();
        out.constants = {};
        for (const k of Object.keys(dnr)) {
            if (typeof dnr[k] === 'number' || typeof dnr[k] === 'string') out.constants[k] = dnr[k];
        }
        const call = async (name, ...args) => {
            try {
                if (typeof dnr[name] !== 'function') return 'absent';
                const r = await dnr[name](...args);
                return r === undefined ? 'undefined' : JSON.stringify(r);
            } catch (e) { return 'threw: ' + e; }
        };
        out.enabledRulesets = await call('getEnabledRulesets');
        out.availableStaticRuleCount = await call('getAvailableStaticRuleCount');
        out.dynamicRules = await call('getDynamicRules');
        out.sessionRules = await call('getSessionRules');
        out.matchedRules = await call('getMatchedRules', {});
        out.regexSupported = await call('isRegexSupported', {regex: 'ads?\\\\d+'});
        out.testMatchOutcome = await call('testMatchOutcome',
            {url: 'https://httpbin.org/anything/advertisement.js', type: 'xmlhttprequest', initiator: 'https://example.com'});
        return JSON.stringify(out);
        """

    private func popupWebView(for loaded: ExtensionManager.LoadedExtension, timeout: TimeInterval = 20) async -> WKWebView? {
        guard let popup = loaded.context.action(for: nil)?.popupWebView else { return nil }
        _ = await poll(timeout: timeout) { popup.isLoading == false && popup.url != nil }
        return popup
    }

    // MARK: - Probe 1: does ANY static DNR rule reach the request pipeline?

    /// The floor test the whole uBO Lite question rests on. One MV3 extension,
    /// one static ruleset, two rules, no scale and no exotic conditions. If
    /// this does not block, uBO Lite's 18,380 rules were never the problem.
    func test00StaticDNRFloor() async throws {
        var finding = Finding(probe: "00-dnr-static-floor", notes: [], conclusion: "")
        defer { write(finding) }
        finding.notes.append(preExistingNote)

        let before = try await runBatteryInFreshTab()
        finding.notes.append(Note(name: "battery before load", observed: batteryLine(before)))

        let fixture = try makeFixture("dnr-static", files: [
            "manifest.json": """
                {
                  "manifest_version": 3,
                  "name": "Cherry DNR Static Probe",
                  "version": "1.0",
                  "permissions": ["declarativeNetRequest", "declarativeNetRequestFeedback", "storage"],
                  "host_permissions": ["<all_urls>"],
                  "background": {"scripts": ["bg.js"], "service_worker": "bg.js", "persistent": false},
                  "action": {"default_popup": "popup.html", "default_title": "DNR"},
                  "declarative_net_request": {
                    "rule_resources": [{"id": "probe", "enabled": true, "path": "rules.json"}]
                  }
                }
                """,
            "rules.json": """
                [
                  {"id": 1, "priority": 1, "action": {"type": "block"},
                   "condition": {"urlFilter": "advertisement.js"}},
                  {"id": 2, "priority": 1, "action": {"type": "block"},
                   "condition": {"urlFilter": "adsbygoogle.js"}}
                ]
                """,
            "bg.js": "(globalThis.browser ?? globalThis.chrome).action.setBadgeText({ text: 'UP' });",
            "popup.html": "<!DOCTYPE html><html><body id=\"dnr-probe\">probe</body></html>",
        ])
        defer { try? FileManager.default.removeItem(at: fixture) }

        let loaded = try await ExtensionManager.shared.loadExtension(from: fixture)
        defer { ExtensionManager.shared.remove(extensionID: loaded.id) }

        finding.notes.append(Note(name: "manifest parse errors", observed: describeErrors(loaded.webExtension.errors)))
        let backgroundUp = await poll(timeout: 15) { loaded.context.action(for: nil)?.badgeText == "UP" }
        finding.notes.append(Note(name: "background ran (badge)", observed: backgroundUp ? "UP" : "never set"))

        // Generous: a two-rule list has nothing to compile slowly.
        try await Task.sleep(nanoseconds: 8_000_000_000)
        let after = try await runBatteryInFreshTab()
        finding.notes.append(Note(name: "battery after load", observed: batteryLine(after)))

        if let popup = await popupWebView(for: loaded) {
            finding.notes.append(Note(name: "DNR API as the extension sees it",
                                      observed: await evaluate(Self.dnrInterrogation, in: popup)))
        } else {
            finding.notes.append(Note(name: "DNR API as the extension sees it", observed: "no popup web view"))
        }

        let newlyBlocked = Self.adURLs.filter { before[$0] == "fetched" && after[$0] == "blocked" }
        finding.notes.append(Note(name: "newly blocked", observed: newlyBlocked.isEmpty ? "none" : newlyBlocked.joined(separator: ", ")))
        finding.notes.append(Note(name: "runtime errors", observed: describeErrors(loaded.context.errors)))
        finding.conclusion = newlyBlocked.isEmpty
            ? "static DNR rules do NOT reach the request pipeline, even at two rules"
            : "static DNR rules DO block (\(newlyBlocked.count)/\(Self.adURLs.count)) — uBO Lite's failure is not the DNR mechanism as such"
    }

    // MARK: - Probe 2: dynamic and session rules

    /// Static rulesets are read from the package at load; dynamic/session
    /// rules go in through the API at runtime. If one path works and the
    /// other doesn't, that pins where the rules die.
    func test01DynamicAndSessionDNR() async throws {
        var finding = Finding(probe: "01-dnr-dynamic-session", notes: [], conclusion: "")
        defer { write(finding) }
        finding.notes.append(preExistingNote)

        let before = try await runBatteryInFreshTab()
        finding.notes.append(Note(name: "battery before rules", observed: batteryLine(before)))

        let fixture = try makeFixture("dnr-dynamic", files: [
            "manifest.json": """
                {
                  "manifest_version": 3,
                  "name": "Cherry DNR Dynamic Probe",
                  "version": "1.0",
                  "permissions": ["declarativeNetRequest", "declarativeNetRequestFeedback", "storage"],
                  "host_permissions": ["<all_urls>"],
                  "background": {"scripts": ["bg.js"], "service_worker": "bg.js", "persistent": false},
                  "action": {"default_popup": "popup.html", "default_title": "DNR"}
                }
                """,
            "bg.js": "(globalThis.browser ?? globalThis.chrome).action.setBadgeText({ text: 'UP' });",
            "popup.html": "<!DOCTYPE html><html><body id=\"dnr-probe\">probe</body></html>",
        ])
        defer { try? FileManager.default.removeItem(at: fixture) }

        let loaded = try await ExtensionManager.shared.loadExtension(from: fixture)
        defer { ExtensionManager.shared.remove(extensionID: loaded.id) }

        guard let popup = await popupWebView(for: loaded) else {
            finding.conclusion = "HARNESS: no popup web view to drive the API from"
            return
        }

        let install = await evaluate("""
            const api = globalThis.browser ?? globalThis.chrome;
            const dnr = api?.declarativeNetRequest;
            const out = {};
            if (!dnr) return JSON.stringify({apiPresent: false});
            const rule = (id, filter) => ({id, priority: 1, action: {type: 'block'}, condition: {urlFilter: filter}});
            try { await dnr.updateDynamicRules({addRules: [rule(101, 'advertisement.js')], removeRuleIds: [101]});
                  out.dynamic = 'accepted'; }
            catch (e) { out.dynamic = 'threw: ' + e; }
            try { await dnr.updateSessionRules({addRules: [rule(201, 'adsbygoogle.js')], removeRuleIds: [201]});
                  out.session = 'accepted'; }
            catch (e) { out.session = 'threw: ' + e; }
            try { out.readBackDynamic = JSON.stringify(await dnr.getDynamicRules()); }
            catch (e) { out.readBackDynamic = 'threw: ' + e; }
            try { out.readBackSession = JSON.stringify(await dnr.getSessionRules()); }
            catch (e) { out.readBackSession = 'threw: ' + e; }
            return JSON.stringify(out);
            """, in: popup)
        finding.notes.append(Note(name: "rule installation", observed: install))

        try await Task.sleep(nanoseconds: 5_000_000_000)
        let after = try await runBatteryInFreshTab()
        finding.notes.append(Note(name: "battery after rules", observed: batteryLine(after)))

        let dynamicTarget = "https://httpbin.org/anything/advertisement.js"
        let sessionTarget = "https://httpbin.org/anything/adsbygoogle.js"
        let dynamicWorked = before[dynamicTarget] == "fetched" && after[dynamicTarget] == "blocked"
        let sessionWorked = before[sessionTarget] == "fetched" && after[sessionTarget] == "blocked"
        finding.notes.append(Note(name: "runtime errors", observed: describeErrors(loaded.context.errors)))
        finding.conclusion = "dynamic rule blocks: \(dynamicWorked); session rule blocks: \(sessionWorked)"
    }

    // MARK: - Probe 3: uBO Lite, probed with its OWN rules

    /// URLs chosen by reading uBO Lite's shipped rulesets, one per major
    /// enabled ruleset, each hitting an **unconditioned block rule** — no
    /// `initiatorDomains`, no `requestDomains`, no excluded resource types,
    /// so nothing about the probe's context can excuse a miss:
    ///
    ///   ublock-filters #2144  urlFilter "/webtracking.min.js"
    ///   ublock-filters #2162  urlFilter "/iframe.php?spotid="
    ///   easylist       #442   urlFilter "-ad-manager/"
    ///   easylist       #450   urlFilter ".ashx?adid="
    ///   easyprivacy    #618   urlFilter ".beacon.min.js"
    ///   easyprivacy    #660   urlFilter "/.webscale/rum?"
    ///
    /// They live on httpbin.org — a host no blocklist targets and which the
    /// baseline shows reachable — so a block can only come from the rule.
    /// (The previous round's battery used generic ad-ish paths that uBO
    /// Lite's converted rules do not actually contain, so a miss there was
    /// ambiguous. These are not.) Two rules per ruleset, one whose
    /// `urlFilter` contains a `?` and one whose does not, so "this ruleset
    /// never applied" can be told from "this pattern shape didn't survive".
    private static let uboRuleURLs = [
        "ublock-filters#2144": "https://httpbin.org/anything/webtracking.min.js",
        "ublock-filters#2162 (?)": "https://httpbin.org/anything/iframe.php?spotid=1",
        "easylist#442": "https://httpbin.org/anything/-ad-manager/probe",
        "easylist#450 (?)": "https://httpbin.org/anything/probe.ashx?adid=1",
        "easyprivacy#618": "https://httpbin.org/anything/probe.beacon.min.js",
        "easyprivacy#660 (?)": "https://httpbin.org/anything/.webscale/rum?x=1",
    ]

    private func runRuleBattery(in tab: Tab) async -> [String: String] {
        let body = """
            const out = {};
            for (const u of urls) {
                try { await fetch(u, {mode: 'no-cors', cache: 'no-store'}); out[u] = 'fetched'; }
                catch (e) { out[u] = 'blocked'; }
            }
            return JSON.stringify(out);
            """
        let urls = Self.uboRuleURLs.values.sorted() + [Self.controlURL]
        do {
            let result = try await tab.webView!.callAsyncJavaScript(
                body, arguments: ["urls": urls], in: nil, contentWorld: .page)
            guard let json = result as? String, let data = json.data(using: .utf8),
                  let map = try? JSONDecoder().decode([String: String].self, from: data) else {
                return ["error": String(describing: result ?? "nil")]
            }
            return map
        } catch {
            return ["error": "js-error: \(error.localizedDescription)"]
        }
    }

    private func runRuleBatteryInFreshTab() async throws -> [String: String] {
        let tab = try await openProbeTab()
        defer { closeProbeTab(tab) }
        return await runRuleBattery(in: tab)
    }

    private func namedBatteryLine(_ map: [String: String]) -> String {
        (Self.uboRuleURLs.sorted { $0.key < $1.key }.map { "\($0.key)=\(map[$0.value] ?? "?")" }
            + ["control=\(map[Self.controlURL] ?? "?")"]).joined(separator: " | ")
    }

    /// The previous round waited 8 seconds and probed URLs uBO Lite's rules
    /// do not cover. This one probes rules it demonstrably ships, polls for
    /// two minutes, and interrogates the DNR API from uBO Lite's own popup.
    func test10UBOLiteDeepProbe() async throws {
        var finding = Finding(probe: "10-ubolite-deep", notes: [], conclusion: "")
        defer { write(finding) }
        finding.notes.append(preExistingNote)

        let identifiersBefore = await contentRuleListIdentifiers()
        let before = try await runRuleBatteryInFreshTab()
        finding.notes.append(Note(name: "rule battery before load", observed: namedBatteryLine(before)))
        finding.notes.append(Note(name: "WKContentRuleListStore identifiers before",
                                  observed: identifiersBefore.sorted().joined(separator: ", ").ifEmpty("none")))

        let loaded = try await loadCandidate("uBOLite.firefox")
        defer { ExtensionManager.shared.remove(extensionID: loaded.id) }
        finding.notes.append(Note(name: "loaded", observed: "\(loaded.webExtension.displayName ?? "?") \(loaded.webExtension.version ?? "?")"))
        finding.notes.append(Note(name: "manifest parse errors", observed: describeErrors(loaded.webExtension.errors)))

        // Polls to the end rather than stopping at the first block: the
        // easylist claim rests on those two URLs STAYING fetchable, so one
        // sample would not carry it. Stops early only when all six are
        // blocked, which would settle the question the other way.
        var blockedAt = "nothing blocked within 120s"
        var timeline: [String] = []
        var everBlocked: Set<String> = []
        for step in 0..<12 {
            try await Task.sleep(nanoseconds: 10_000_000_000)
            let battery = try await runRuleBatteryInFreshTab()
            let newly = Self.uboRuleURLs.filter { before[$0.value] == "fetched" && battery[$0.value] == "blocked" }
            timeline.append("t+\((step + 1) * 10)s: \(namedBatteryLine(battery))")
            if everBlocked.isEmpty && !newly.isEmpty {
                blockedAt = "t+\((step + 1) * 10)s (\(newly.keys.sorted().joined(separator: ", ")))"
            }
            everBlocked.formUnion(newly.keys)
            if everBlocked.count == Self.uboRuleURLs.count { break }
        }
        finding.notes.append(Note(name: "battery timeline", observed: timeline.joined(separator: "\n")))
        finding.notes.append(Note(name: "first block", observed: blockedAt))
        finding.notes.append(Note(name: "never blocked in 120s",
                                  observed: Set(Self.uboRuleURLs.keys).subtracting(everBlocked)
                                      .sorted().joined(separator: ", ").ifEmpty("none — all six blocked")))

        if let popup = await popupWebView(for: loaded, timeout: 30) {
            finding.notes.append(Note(name: "DNR API as uBO Lite sees it",
                                      observed: await evaluate(Self.dnrInterrogation, in: popup)))
            finding.notes.append(Note(name: "uBO Lite's own stored filtering state", observed: await evaluate("""
                const api = globalThis.browser ?? globalThis.chrome;
                try {
                    const all = await api.storage.local.get(null);
                    const out = {};
                    for (const k of Object.keys(all)) {
                        const v = all[k];
                        out[k] = typeof v === 'object' ? JSON.stringify(v).slice(0, 200) : String(v).slice(0, 200);
                    }
                    return JSON.stringify(out);
                } catch (e) { return 'threw: ' + e; }
                """, in: popup)))
            // Force a ruleset re-registration: if disabling and re-enabling
            // makes blocking start, the rules were parsed and the failure is
            // in when they get applied, not whether they were understood.
            let toggle = await evaluate("""
                const dnr = (globalThis.browser ?? globalThis.chrome).declarativeNetRequest;
                if (!dnr?.updateEnabledRulesets) return 'updateEnabledRulesets absent';
                try {
                    await dnr.updateEnabledRulesets({disableRulesetIds: ['ublock-filters']});
                    const off = JSON.stringify(await dnr.getEnabledRulesets());
                    await dnr.updateEnabledRulesets({enableRulesetIds: ['ublock-filters']});
                    const on = JSON.stringify(await dnr.getEnabledRulesets());
                    return 'off=' + off + ' on=' + on;
                } catch (e) { return 'threw: ' + e; }
                """, in: popup)
            finding.notes.append(Note(name: "disable/re-enable ublock-filters", observed: toggle))

            try await Task.sleep(nanoseconds: 20_000_000_000)
            let afterToggle = try await runRuleBatteryInFreshTab()
            finding.notes.append(Note(name: "battery after ruleset toggle", observed: namedBatteryLine(afterToggle)))

            // Ask the matcher itself. `getMatchedRules` wants a tabId in this
            // runtime, so run the battery in a tab that stays open and query
            // against it: a rule that matched but did not stop the request is
            // a different failure from a rule that never matched.
            let matchTab = try await openProbeTab()
            _ = await runRuleBattery(in: matchTab)
            finding.notes.append(Note(name: "getMatchedRules for the battery tab", observed: await evaluate("""
                const api = globalThis.browser ?? globalThis.chrome;
                const dnr = api.declarativeNetRequest;
                try {
                    const tabs = await api.tabs.query({active: true, currentWindow: true});
                    const tabId = tabs?.[0]?.id;
                    if (tabId == null) return 'no tab id';
                    return 'tab ' + tabId + ' url=' + tabs[0].url + ' -> '
                        + JSON.stringify(await dnr.getMatchedRules({tabId}));
                } catch (e) { return 'threw: ' + e; }
                """, in: popup)))
            closeProbeTab(matchTab)

            // The one structural difference between uBO Lite and the fixture
            // in probe 14 that carries its exact six rulesets: uBO Lite also
            // installs 28 dynamic rules at startup. Take them away and see
            // whether the ruleset that was not applying starts to.
            let cleared = await evaluate("""
                const dnr = (globalThis.browser ?? globalThis.chrome).declarativeNetRequest;
                try {
                    const dynamic = await dnr.getDynamicRules();
                    const session = await dnr.getSessionRules();
                    await dnr.updateDynamicRules({removeRuleIds: dynamic.map(r => r.id)});
                    await dnr.updateSessionRules({removeRuleIds: session.map(r => r.id)});
                    return 'removed ' + dynamic.length + ' dynamic and ' + session.length + ' session rules; '
                        + 'now ' + (await dnr.getDynamicRules()).length + ' dynamic';
                } catch (e) { return 'threw: ' + e; }
                """, in: popup)
            finding.notes.append(Note(name: "dynamic/session rules removed", observed: cleared))
            try await Task.sleep(nanoseconds: 20_000_000_000)
            finding.notes.append(Note(name: "battery with no dynamic rules",
                                      observed: namedBatteryLine(try await runRuleBatteryInFreshTab())))
        } else {
            finding.notes.append(Note(name: "DNR API as uBO Lite sees it", observed: "no popup web view"))
        }

        let identifiersAfter = await contentRuleListIdentifiers()
        finding.notes.append(Note(name: "WKContentRuleListStore identifiers added while loaded",
                                  observed: identifiersAfter.subtracting(identifiersBefore).sorted().joined(separator: ", ").ifEmpty("none")))

        // Attribution: the leg that caught the previous round's false
        // positive, run in the other direction. Switch uBO Lite off and the
        // URLs it blocked must come back.
        ExtensionManager.shared.setEnabled(false, forExtensionID: loaded.id)
        try await Task.sleep(nanoseconds: 5_000_000_000)
        let unloaded = try await runRuleBatteryInFreshTab()
        finding.notes.append(Note(name: "battery with uBO Lite switched off (attribution)",
                                  observed: namedBatteryLine(unloaded)))

        finding.notes.append(Note(name: "runtime errors", observed: describeErrors(loaded.context.errors)))
        finding.conclusion = "first observed block: \(blockedAt)"
    }

    private func contentRuleListIdentifiers() async -> Set<String> {
        await withCheckedContinuation { continuation in
            WKContentRuleListStore.default().getAvailableContentRuleListIdentifiers { identifiers in
                continuation.resume(returning: Set(identifiers ?? []))
            }
        }
    }

    // MARK: - Probe 3b: at what size does a static ruleset stop being honoured?

    /// Static DNR works at two rules (probe 00) and does nothing at uBO
    /// Lite's 18,380. This walks the gap using uBO Lite's OWN rules: a
    /// minimal extension whose single ruleset is the first N rules of
    /// `ublock-filters.json`, with two canary rules appended INSIDE that same
    /// ruleset. The canaries block if and only if the runtime accepted the
    /// ruleset, so the size at which they stop blocking is the size at which
    /// the ruleset is being thrown away.
    func test11StaticRulesetSizeLadder() async throws {
        var finding = Finding(probe: "11-dnr-ruleset-size-ladder", notes: [], conclusion: "")
        defer { write(finding) }
        finding.notes.append(preExistingNote)

        let source = packagesDirectory
            .appendingPathComponent("uBOLite.firefox.unpacked/rulesets/main/ublock-filters.json")
        guard let data = try? Data(contentsOf: source),
              let all = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            finding.conclusion = "HARNESS: could not read ublock-filters.json from the package"
            return
        }
        finding.notes.append(Note(name: "source ruleset", observed: "ublock-filters.json, \(all.count) rules"))

        let before = try await runBatteryInFreshTab()
        finding.notes.append(Note(name: "canary battery before any load", observed: batteryLine(before)))

        var lastWorkingSize = 0
        var firstFailingSize = -1
        for size in [10, 100, 1_000, 5_000, all.count] where size <= all.count {
            let slice = Array(all.prefix(size))
            let (blocked, seconds) = try await canaryVerdict(rules: slice, label: "\(size) rules")
            finding.notes.append(Note(name: "ruleset of \(size) real rules + 2 canaries",
                                      observed: "canaries blocked: \(blocked)\(blocked ? " after \(seconds)s" : "")"))
            if blocked { lastWorkingSize = size } else if firstFailingSize < 0 { firstFailingSize = size }
        }

        finding.conclusion = firstFailingSize < 0
            ? "every size up to \(all.count) real rules was honoured — size alone is not the cutoff"
            : "honoured at \(lastWorkingSize) rules, ignored at \(firstFailingSize)"
    }

    /// Loads a throwaway MV3 extension whose one static ruleset is `rules`
    /// plus two canaries, then polls for up to 90s for the canaries to bite.
    /// Returns whether they ever did and how long it took.
    private func canaryVerdict(rules: [[String: Any]], label: String) async throws -> (Bool, Int) {
        var withCanaries = rules
        withCanaries.append(["id": 900_001, "priority": 1, "action": ["type": "block"],
                             "condition": ["urlFilter": "advertisement.js"]])
        withCanaries.append(["id": 900_002, "priority": 1, "action": ["type": "block"],
                             "condition": ["urlFilter": "adsbygoogle.js"]])
        let json = String(data: try JSONSerialization.data(withJSONObject: withCanaries), encoding: .utf8)!

        let fixture = try makeFixture("ladder", files: [
            "manifest.json": """
                {
                  "manifest_version": 3,
                  "name": "Cherry DNR Ladder \(label)",
                  "version": "1.0",
                  "description": "Ruleset size probe.",
                  "permissions": ["declarativeNetRequest", "storage"],
                  "host_permissions": ["<all_urls>"],
                  "background": {"scripts": ["bg.js"], "service_worker": "bg.js", "persistent": false},
                  "declarative_net_request": {
                    "rule_resources": [{"id": "probe", "enabled": true, "path": "rules.json"}]
                  }
                }
                """,
            "rules.json": json,
            "bg.js": "// nothing to do",
        ])
        defer { try? FileManager.default.removeItem(at: fixture) }

        let loaded = try await ExtensionManager.shared.loadExtension(from: fixture)
        defer { ExtensionManager.shared.remove(extensionID: loaded.id) }

        // uBO Lite's full 18,380 rules bite by t+10s (probe 10), so 40s is
        // four times the observed budget rather than an arbitrary cutoff.
        for step in 1...4 {
            try await Task.sleep(nanoseconds: 10_000_000_000)
            let battery = try await runBatteryInFreshTab()
            if Self.adURLs.allSatisfy({ battery[$0] == "blocked" }) { return (true, step * 10) }
        }
        return (false, 0)
    }

    // MARK: - Probe 3bb: which ruleset is the one that does not apply

    /// Probe 10 says uBO Lite blocks through `ublock-filters` and
    /// `easyprivacy` but not `easylist`, even though `getEnabledRulesets()`
    /// lists all six. This loads each ruleset file on its own, in a minimal
    /// extension, with two canary rules appended INSIDE it — so a ruleset
    /// that the runtime throws away announces itself by its canaries not
    /// biting — and then narrows `easylist` down by halves.
    func test13WhichRulesetIsDropped() async throws {
        var finding = Finding(probe: "13-which-ruleset-is-dropped", notes: [], conclusion: "")
        defer { write(finding) }
        finding.notes.append(preExistingNote)

        func load(_ name: String) -> [[String: Any]]? {
            let url = packagesDirectory
                .appendingPathComponent("uBOLite.firefox.unpacked/rulesets/main/\(name).json")
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        }
        func requestDomainCount(_ rule: [String: Any]) -> Int {
            ((rule["condition"] as? [String: Any])?["requestDomains"] as? [String])?.count ?? 0
        }

        guard let easylist = load("easylist") else {
            finding.conclusion = "HARNESS: could not read easylist.json"
            return
        }
        let biggest = easylist.map(requestDomainCount).max() ?? 0
        finding.notes.append(Note(name: "easylist shape",
                                  observed: "\(easylist.count) rules; largest requestDomains list \(biggest)"))

        var variants: [(String, [[String: Any]])] = []
        for name in ["easyprivacy", "ublock-filters", "easylist", "pgl", "ublock-badware", "urlhaus-full"] {
            if let rules = load(name) { variants.append((name + " verbatim", rules)) }
        }
        variants.append(("easylist first half", Array(easylist.prefix(easylist.count / 2))))
        variants.append(("easylist second half", Array(easylist.suffix(easylist.count - easylist.count / 2))))
        variants.append(("easylist minus rules with any requestDomains",
                         easylist.filter { requestDomainCount($0) == 0 }))
        variants.append(("easylist ONLY its rules with requestDomains",
                         easylist.filter { requestDomainCount($0) > 0 }))

        var honoured: [String] = []
        var ignored: [String] = []
        for (label, rules) in variants {
            let (blocked, seconds) = try await canaryVerdict(rules: rules, label: label)
            finding.notes.append(Note(name: "\(label) (\(rules.count) rules)",
                                      observed: blocked ? "canaries blocked after \(seconds)s" : "canaries never blocked"))
            if blocked { honoured.append(label) } else { ignored.append(label) }
        }
        finding.conclusion = "honoured: \(honoured.joined(separator: "; ").ifEmpty("none")) || ignored: \(ignored.joined(separator: "; ").ifEmpty("none"))"
    }

    // MARK: - Probe 3d: is there a budget across rulesets?

    /// Every one of uBO Lite's six rulesets is honoured on its own (probe
    /// 13), yet loaded together `easylist` is the one that does not bite
    /// (probe 10). That points at a budget spent across rulesets rather than
    /// at any single ruleset being malformed. This rebuilds uBO Lite's
    /// structure — the real files, as separate `rule_resources` — in
    /// combinations of growing total size, with the canaries inside the
    /// `easylist` copy, and reports the total rule count at which easylist
    /// stops applying.
    func test14MultiRulesetBudget() async throws {
        var finding = Finding(probe: "14-multi-ruleset-budget", notes: [], conclusion: "")
        defer { write(finding) }
        finding.notes.append(preExistingNote)

        let combinations: [[String]] = [
            ["easylist"],
            ["easylist", "ublock-filters"],
            ["easylist", "easyprivacy"],
            ["easylist", "ublock-filters", "pgl", "ublock-badware", "urlhaus-full"],
            ["easylist", "ublock-filters", "easyprivacy"],
            ["ublock-filters", "easylist", "easyprivacy", "pgl", "ublock-badware", "urlhaus-full"],
        ]
        var summary: [String] = []
        for names in combinations {
            let (canary, battery, total) = try await multiRulesetVerdict(names, canaryIn: "easylist")
            let line = "\(names.joined(separator: "+")) = \(total) rules -> easylist canaries \(canary ? "BLOCK" : "do nothing")"
            finding.notes.append(Note(name: line, observed: battery))
            summary.append(line)
        }
        finding.conclusion = summary.joined(separator: " ;; ")
    }

    /// Builds one extension carrying `names` as separate static rulesets, the
    /// canaries appended to the `canaryIn` one, and reports whether the
    /// canaries bite plus what the real-rule battery does.
    private func multiRulesetVerdict(_ names: [String], canaryIn: String) async throws -> (Bool, String, Int) {
        var files: [String: String] = ["bg.js": "// nothing"]
        var resources: [String] = []
        var total = 0
        for name in names {
            let url = packagesDirectory
                .appendingPathComponent("uBOLite.firefox.unpacked/rulesets/main/\(name).json")
            guard let data = try? Data(contentsOf: url),
                  var rules = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
            if name == canaryIn {
                rules.append(["id": 900_001, "priority": 1, "action": ["type": "block"],
                              "condition": ["urlFilter": "advertisement.js"]])
                rules.append(["id": 900_002, "priority": 1, "action": ["type": "block"],
                              "condition": ["urlFilter": "adsbygoogle.js"]])
            }
            total += rules.count
            files["\(name).json"] = String(data: try JSONSerialization.data(withJSONObject: rules), encoding: .utf8)!
            resources.append("{\"id\": \"\(name)\", \"enabled\": true, \"path\": \"\(name).json\"}")
        }
        files["manifest.json"] = """
            {
              "manifest_version": 3,
              "name": "Cherry Multi-Ruleset Probe",
              "version": "1.0",
              "description": "uBO Lite's own rulesets, recombined.",
              "permissions": ["declarativeNetRequest", "storage"],
              "host_permissions": ["<all_urls>"],
              "background": {"scripts": ["bg.js"], "service_worker": "bg.js", "persistent": false},
              "declarative_net_request": {"rule_resources": [\(resources.joined(separator: ", "))]}
            }
            """

        let fixture = try makeFixture("multi", files: files)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let loaded = try await ExtensionManager.shared.loadExtension(from: fixture)
        defer { ExtensionManager.shared.remove(extensionID: loaded.id) }

        var canaryBlocked = false
        for _ in 1...4 {
            try await Task.sleep(nanoseconds: 10_000_000_000)
            let battery = try await runBatteryInFreshTab()
            if Self.adURLs.allSatisfy({ battery[$0] == "blocked" }) { canaryBlocked = true; break }
        }
        let ruleBattery = try await runRuleBatteryInFreshTab()
        return (canaryBlocked, namedBatteryLine(ruleBattery), total)
    }

    // MARK: - Probe 3c: what a WKContentRuleList translation would cost

    /// The proposed bridge, measured rather than guessed: read uBO Lite's six
    /// enabled rulesets out of its package, translate every rule a
    /// `WKContentRuleList` trigger/action can express, hand the result to the
    /// real `WKContentRuleListStore`, and time it. Then attach the compiled
    /// list to a plain `WKWebView` and check that the three rules probe 10
    /// targets actually block through it.
    ///
    /// This builds nothing into the app. The translator lives here, in the
    /// test, and the compiled list is removed from the store afterwards.
    func test12TranslateUBOLiteRulesToContentRuleList() async throws {
        var finding = Finding(probe: "12-dnr-to-contentrulelist", notes: [], conclusion: "")
        defer { write(finding) }
        finding.notes.append(preExistingNote)

        // Alternation first: Cherry's own rule builder says WebKit's
        // url-filter parser rejects it, and whether it does decides whether a
        // 3,435-domain rule stays one rule or becomes 3,435.
        let alternation = await compile(identifier: "CherryDiagAlternation", rules: [
            ["trigger": ["url-filter": "^https?://([^/]+\\.)?(alpha\\.example|beta\\.example)[/:]"],
             "action": ["type": "block"]],
        ])
        finding.notes.append(Note(name: "does WebKit's url-filter accept alternation?",
                                  observed: alternation.error ?? "accepted"))

        let rulesetNames = ["ublock-filters", "easylist", "easyprivacy", "pgl", "ublock-badware", "urlhaus-full"]
        var stats = TranslationStats()
        var translated: [[String: Any]] = []
        for name in rulesetNames {
            let url = packagesDirectory
                .appendingPathComponent("uBOLite.firefox.unpacked/rulesets/main/\(name).json")
            guard let data = try? Data(contentsOf: url),
                  let rules = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                finding.notes.append(Note(name: "ruleset \(name)", observed: "could not read"))
                continue
            }
            let out = Self.translate(rules, expandRequestDomains: !alternation.succeeded, into: &stats)
            finding.notes.append(Note(name: "ruleset \(name)",
                                      observed: "\(rules.count) DNR rules -> \(out.count) content-rule-list rules"))
            translated.append(contentsOf: out)
        }

        finding.notes.append(Note(name: "translation totals", observed: stats.summary(emitted: translated.count)))
        finding.notes.append(Note(name: "dropped by action type", observed: stats.render(stats.droppedByAction)))
        finding.notes.append(Note(name: "dropped by condition", observed: stats.render(stats.droppedByCondition)))

        // Compile the whole thing, then bisect down if WebKit refuses it, so
        // the evidence says how much it WILL take rather than only that the
        // full set failed.
        var attempt = translated
        var results: [String] = []
        var compiled: WKContentRuleList?
        while !attempt.isEmpty {
            let start = Date()
            let outcome = await compile(identifier: "CherryDiagUBOL", rules: attempt)
            let elapsed = Date().timeIntervalSince(start)
            results.append("\(attempt.count) rules: \(outcome.error ?? "compiled") in \(String(format: "%.1f", elapsed))s")
            if let list = outcome.list { compiled = list; break }
            attempt = Array(attempt.prefix(attempt.count / 2))
        }
        finding.notes.append(Note(name: "WKContentRuleListStore compile attempts", observed: results.joined(separator: "\n")))

        if let compiled {
            let configuration = WKWebViewConfiguration()
            configuration.userContentController.add(compiled)
            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
            let recorder = NavigationActionRecorder()
            webView.navigationDelegate = recorder
            webView.load(URLRequest(url: URL(string: "https://example.com/")!))
            _ = await poll(timeout: 30) { recorder.didFinish }
            let probed = (try? await webView.callAsyncJavaScript("""
                const out = {};
                for (const u of urls) {
                    try { await fetch(u, {mode: 'no-cors', cache: 'no-store'}); out[u] = 'fetched'; }
                    catch (e) { out[u] = 'blocked'; }
                }
                return JSON.stringify(out);
                """, arguments: ["urls": Self.uboRuleURLs.values.sorted() + [Self.controlURL]],
                in: nil, contentWorld: .page)) as? String
            finding.notes.append(Note(name: "the same three uBO rules, through the translated list",
                                      observed: probed ?? "probe failed"))
        }
        await remove(identifier: "CherryDiagUBOL")
        await remove(identifier: "CherryDiagAlternation")

        finding.conclusion = "\(stats.input) DNR rules in, \(translated.count) content-rule-list rules out"
    }

    private func compile(identifier: String, rules: [[String: Any]]) async -> (list: WKContentRuleList?, error: String?, succeeded: Bool) {
        guard let data = try? JSONSerialization.data(withJSONObject: rules),
              let json = String(data: data, encoding: .utf8) else {
            return (nil, "could not serialise rules", false)
        }
        return await withCheckedContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: identifier, encodedContentRuleList: json
            ) { list, error in
                continuation.resume(returning: (list, error?.localizedDescription, list != nil))
            }
        }
    }

    private func remove(identifier: String) async {
        await withCheckedContinuation { continuation in
            WKContentRuleListStore.default().removeContentRuleList(forIdentifier: identifier) { _ in
                continuation.resume()
            }
        }
    }

    // MARK: - DNR -> WKContentRuleList translation (test-only)

    struct TranslationStats {
        var input = 0
        var emitted = 0
        var expandedRules = 0
        var expandedInto = 0
        var droppedByAction: [String: Int] = [:]
        var droppedByCondition: [String: Int] = [:]

        mutating func dropAction(_ key: String) { droppedByAction[key, default: 0] += 1 }
        mutating func dropCondition(_ key: String) { droppedByCondition[key, default: 0] += 1 }

        func render(_ map: [String: Int]) -> String {
            map.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ").ifEmpty("none")
        }

        func summary(emitted: Int) -> String {
            let dropped = droppedByAction.values.reduce(0, +) + droppedByCondition.values.reduce(0, +)
            return "\(input) DNR rules in; \(input - dropped) expressible; \(dropped) dropped; "
                + "\(expandedRules) host-list rules expanded into \(expandedInto); \(emitted) rules emitted"
        }
    }

    /// DNR resource types that have a `WKContentRuleList` counterpart.
    private static let resourceTypeMap: [String: String] = [
        "main_frame": "document", "sub_frame": "document", "stylesheet": "style-sheet",
        "script": "script", "image": "image", "font": "font", "object": "other",
        "xmlhttprequest": "fetch", "ping": "ping", "csp_report": "other",
        "media": "media", "websocket": "websocket", "other": "other",
    ]

    /// Translates DNR rules into content-rule-list rules, dropping whatever a
    /// WebKit trigger/action cannot express and counting why. Deliberately
    /// conservative: a rule that could only be approximated (and would then
    /// over-block) is dropped rather than guessed at.
    static func translate(_ rules: [[String: Any]], expandRequestDomains: Bool,
                          into stats: inout TranslationStats) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for rule in rules {
            stats.input += 1
            let condition = rule["condition"] as? [String: Any] ?? [:]
            guard let actionDictionary = rule["action"] as? [String: Any],
                  let actionType = actionDictionary["type"] as? String else {
                stats.dropAction("malformed"); continue
            }
            let mappedAction: String
            switch actionType {
            case "block": mappedAction = "block"
            case "allow", "allowAllRequests": mappedAction = "ignore-previous-rules"
            case "upgradeScheme": mappedAction = "make-https"
            default: stats.dropAction(actionType); continue
            }

            // Conditions with no WebKit equivalent at all.
            var unsupported: String?
            for key in ["requestMethods", "excludedRequestMethods", "responseHeaders",
                        "excludedResponseHeaders", "tabIds", "excludedTabIds", "excludedRequestDomains"]
            where condition[key] != nil {
                unsupported = key
            }
            if let unsupported { stats.dropCondition(unsupported); continue }

            var trigger: [String: Any] = [:]
            if let caseSensitive = condition["isUrlFilterCaseSensitive"] as? Bool {
                trigger["url-filter-is-case-sensitive"] = caseSensitive
            }

            let requestDomains = condition["requestDomains"] as? [String] ?? []
            var urlFilters: [String] = []
            if let regexFilter = condition["regexFilter"] as? String {
                if !requestDomains.isEmpty { stats.dropCondition("regexFilter+requestDomains"); continue }
                urlFilters = [regexFilter]
            } else if let filter = condition["urlFilter"] as? String {
                if !requestDomains.isEmpty {
                    // Two independent URL constraints; WebKit has one
                    // url-filter and no lookahead to AND them together.
                    stats.dropCondition("urlFilter+requestDomains"); continue
                }
                urlFilters = [urlFilterRegex(filter)]
            } else if !requestDomains.isEmpty {
                if expandRequestDomains {
                    stats.expandedRules += 1
                    stats.expandedInto += requestDomains.count
                    urlFilters = requestDomains.map { "^[^:]+://([^/]+\\.)?\(escapeForRegex($0))[/:]" }
                } else {
                    let alternation = requestDomains.map(escapeForRegex).joined(separator: "|")
                    urlFilters = ["^[^:]+://([^/]+\\.)?(\(alternation))[/:]"]
                }
            } else {
                urlFilters = [".*"]
            }

            if let types = condition["resourceTypes"] as? [String] {
                let mapped = Set(types.compactMap { resourceTypeMap[$0] })
                if mapped.isEmpty { stats.dropCondition("resourceTypes"); continue }
                trigger["resource-type"] = mapped.sorted()
            } else if let excluded = condition["excludedResourceTypes"] as? [String] {
                let excludedSet = Set(excluded.compactMap { resourceTypeMap[$0] })
                let remaining = Set(resourceTypeMap.values).subtracting(excludedSet)
                if remaining.isEmpty { stats.dropCondition("excludedResourceTypes"); continue }
                trigger["resource-type"] = remaining.sorted()
            }

            switch condition["domainType"] as? String {
            case "firstParty": trigger["load-type"] = ["first-party"]
            case "thirdParty": trigger["load-type"] = ["third-party"]
            default: break
            }

            // DNR's initiator domain matches the domain or any subdomain;
            // WebKit's if-domain needs a leading `*` to mean the same.
            if let initiators = condition["initiatorDomains"] as? [String] {
                trigger["if-domain"] = initiators.map { "*\($0)" }
            }
            if let excluded = condition["excludedInitiatorDomains"] as? [String] {
                trigger["unless-domain"] = excluded.map { "*\($0)" }
            }

            for filter in urlFilters {
                var one = trigger
                one["url-filter"] = filter
                out.append(["trigger": one, "action": ["type": mappedAction]])
                stats.emitted += 1
            }
        }
        return out
    }

    private static func escapeForRegex(_ text: String) -> String {
        var out = ""
        for character in text {
            if "\\^$.|?*+()[]{}".contains(character) { out += "\\\(character)" } else { out.append(character) }
        }
        return out
    }

    /// DNR `urlFilter` syntax (`||` domain anchor, `|` boundary anchor, `*`
    /// wildcard, `^` separator) rendered as the unanchored regex WebKit's
    /// `url-filter` expects. `^` is approximated by a separator class — DNR
    /// also lets it match end-of-URL, which this cannot express.
    static func urlFilterRegex(_ filter: String) -> String {
        var body = Substring(filter)
        var prefix = ""
        var suffix = ""
        if body.hasPrefix("||") {
            body = body.dropFirst(2)
            prefix = "^[^:]+://([^/]+\\.)?"
        } else if body.hasPrefix("|") {
            body = body.dropFirst()
            prefix = "^"
        }
        if body.hasSuffix("|") {
            body = body.dropLast()
            suffix = "$"
        }
        var out = ""
        for character in body {
            switch character {
            case "*": out += ".*"
            case "^": out += "[/:?&=]"
            default: out += escapeForRegex(String(character))
            }
        }
        return prefix + out + suffix
    }

    // MARK: - Probe 4: MV2 blocking webRequest

    /// uBlock Origin and Privacy Badger both need a synchronous, cancelling
    /// `webRequest` listener. This asks the runtime directly: does the API
    /// object exist, does `addListener` with `["blocking"]` throw, does the
    /// listener ever fire, and does returning `{cancel: true}` stop anything.
    /// Reported separately, because "the API is missing" and "the API is
    /// there but observational" are different bridging problems.
    func test20MV2BlockingWebRequest() async throws {
        var finding = Finding(probe: "20-mv2-blocking-webrequest", notes: [], conclusion: "")
        defer { write(finding) }
        finding.notes.append(preExistingNote)

        let before = try await runBatteryInFreshTab()
        finding.notes.append(Note(name: "battery before load", observed: batteryLine(before)))

        let fixture = try makeFixture("mv2-webrequest", files: [
            "manifest.json": """
                {
                  "manifest_version": 2,
                  "name": "Cherry webRequest Probe",
                  "version": "1.0",
                  "permissions": ["webRequest", "webRequestBlocking", "storage", "<all_urls>"],
                  "background": {"scripts": ["bg.js"], "persistent": true},
                  "browser_action": {"default_popup": "popup.html", "default_title": "WR"}
                }
                """,
            "bg.js": """
                const api = globalThis.browser ?? globalThis.chrome;
                const state = {
                  apiObject: typeof api,
                  webRequest: typeof api?.webRequest,
                  onBeforeRequest: typeof api?.webRequest?.onBeforeRequest,
                  onBeforeSendHeaders: typeof api?.webRequest?.onBeforeSendHeaders,
                  addListener: 'not attempted',
                  addHeaderListener: 'not attempted',
                  fired: 0,
                  cancelAttempts: 0,
                  headerFired: 0,
                  headerAttempts: 0,
                  sampleURLs: [],
                };
                function save() { try { api.storage.local.set({probe: JSON.stringify(state)}); } catch (e) {} }
                try {
                  api.webRequest.onBeforeRequest.addListener(function (details) {
                    state.fired += 1;
                    if (state.sampleURLs.length < 8) state.sampleURLs.push(details.url.slice(0, 120));
                    save();
                    if (details.url.indexOf('advertisement.js') !== -1) {
                      state.cancelAttempts += 1;
                      save();
                      return { cancel: true };
                    }
                    return {};
                  }, { urls: ['<all_urls>'] }, ['blocking']);
                  state.addListener = 'accepted';
                } catch (e) { state.addListener = 'threw: ' + e; }
                // Privacy Badger's baseline effect is a header, not a
                // cancellation — the other half of blocking webRequest.
                try {
                  api.webRequest.onBeforeSendHeaders.addListener(function (details) {
                    state.headerFired += 1;
                    const headers = details.requestHeaders || [];
                    headers.push({ name: 'Sec-GPC', value: '1' });
                    headers.push({ name: 'DNT', value: '1' });
                    state.headerAttempts += 1;
                    save();
                    return { requestHeaders: headers };
                  }, { urls: ['<all_urls>'] }, ['blocking', 'requestHeaders']);
                  state.addHeaderListener = 'accepted';
                } catch (e) { state.addHeaderListener = 'threw: ' + e; }
                save();
                """,
            "popup.html": "<!DOCTYPE html><html><body id=\"wr-probe\">probe</body></html>",
        ])
        defer { try? FileManager.default.removeItem(at: fixture) }

        let loaded = try await ExtensionManager.shared.loadExtension(from: fixture)
        defer { ExtensionManager.shared.remove(extensionID: loaded.id) }
        finding.notes.append(Note(name: "manifest parse errors", observed: describeErrors(loaded.webExtension.errors)))
        finding.notes.append(Note(name: "permissions the runtime granted",
                                  observed: loaded.context.currentPermissions.map(\.rawValue).sorted().joined(separator: ", ").ifEmpty("none")))

        try await Task.sleep(nanoseconds: 5_000_000_000)
        let after = try await runBatteryInFreshTab()
        finding.notes.append(Note(name: "battery after load", observed: batteryLine(after)))

        // httpbin echoes the headers it received, so whether the listener's
        // `requestHeaders` were honoured is directly observable.
        let headerTab = try await openProbeTab()
        finding.notes.append(Note(name: "headers httpbin actually received", observed: await evaluate("""
            try {
                const r = await fetch('https://httpbin.org/headers', {cache: 'no-store'});
                const j = await r.json();
                return JSON.stringify(j.headers);
            } catch (e) { return 'fetch failed: ' + e; }
            """, in: headerTab.webView!)))
        closeProbeTab(headerTab)

        if let popup = await popupWebView(for: loaded) {
            let state = await evaluate("""
                const api = globalThis.browser ?? globalThis.chrome;
                try {
                    const stored = await api.storage.local.get('probe');
                    return stored?.probe ?? 'nothing stored';
                } catch (e) { return 'storage read threw: ' + e; }
                """, in: popup)
            finding.notes.append(Note(name: "background state", observed: state))
        } else {
            finding.notes.append(Note(name: "background state", observed: "no popup web view to read it from"))
        }

        let target = "https://httpbin.org/anything/advertisement.js"
        let cancelled = before[target] == "fetched" && after[target] == "blocked"
        finding.notes.append(Note(name: "runtime errors", observed: describeErrors(loaded.context.errors)))
        finding.conclusion = cancelled
            ? "blocking webRequest CANCELS requests in this runtime"
            : "returning {cancel:true} from onBeforeRequest changed nothing"
    }

    /// The other half of the webRequest question: if the extension API can't
    /// cancel, can the EMBEDDER? Records which WKWebView-level hooks see a
    /// subresource request at all. `decidePolicyFor` is the only synchronous-
    /// looking interception point WKWebView exposes; this measures what it
    /// actually gets called for.
    func test21EmbedderInterceptionSurface() async throws {
        var finding = Finding(probe: "21-embedder-interception", notes: [], conclusion: "")
        defer { write(finding) }
        finding.notes.append(preExistingNote)

        finding.notes.append(Note(name: "WKWebView.handlesURLScheme(\"https\")",
                                  observed: String(WKWebView.handlesURLScheme("https"))))
        finding.notes.append(Note(name: "WKWebView.handlesURLScheme(\"http\")",
                                  observed: String(WKWebView.handlesURLScheme("http"))))

        let recorder = NavigationActionRecorder()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        webView.navigationDelegate = recorder
        webView.load(URLRequest(url: URL(string: "https://example.com/")!))
        _ = await poll(timeout: 30) { recorder.didFinish }
        let afterPageLoad = recorder.snapshot()

        _ = try? await webView.callAsyncJavaScript("""
            for (const u of urls) { try { await fetch(u, {mode: 'no-cors', cache: 'no-store'}); } catch (e) {} }
            const img = document.createElement('img');
            img.src = 'https://httpbin.org/image/png';
            document.body.appendChild(img);
            const s = document.createElement('script');
            s.src = 'https://httpbin.org/anything/advertisement.js';
            document.body.appendChild(s);
            await new Promise(r => setTimeout(r, 2500));
            return 'done';
            """, arguments: ["urls": Self.adURLs], in: nil, contentWorld: .page)

        let afterSubresources = recorder.snapshot()
        finding.notes.append(Note(name: "decidePolicyForNavigationAction calls during page load",
                                  observed: afterPageLoad.joined(separator: " | ").ifEmpty("none")))
        finding.notes.append(Note(name: "decidePolicyForNavigationAction calls added by fetch/img/script subresources",
                                  observed: Array(afterSubresources.dropFirst(afterPageLoad.count)).joined(separator: " | ").ifEmpty("none")))
        finding.conclusion = afterSubresources.count > afterPageLoad.count
            ? "the navigation delegate DOES see subresource requests"
            : "the navigation delegate sees navigations only; subresource loads never reach it"
    }

    // MARK: - Probe 5: Bitwarden's popup

    /// The popup stops at Angular's unbooted shell (`<app-root><div
    /// id="loading">`, 3 elements, no text). This captures the popup's own
    /// console and error events — by installing a document-start user script
    /// and reloading it — plus which of its four bundles actually loaded, so
    /// "the scripts never ran" and "a script threw" can be told apart.
    func test30BitwardenPopupConsole() async throws {
        var finding = Finding(probe: "30-bitwarden-popup", notes: [], conclusion: "")
        defer { write(finding) }
        finding.notes.append(preExistingNote)

        let loaded = try await loadCandidate("bitwarden-password-manager")
        defer { ExtensionManager.shared.remove(extensionID: loaded.id) }
        finding.notes.append(Note(name: "manifest parse errors", observed: describeErrors(loaded.webExtension.errors)))

        let tab = try await openProbeTab()
        defer { closeProbeTab(tab) }

        guard let action = loaded.context.action(for: nil), let popup = action.popupWebView else {
            finding.conclusion = "no popup web view at all"
            return
        }
        _ = await poll(timeout: 30) { popup.isLoading == false && popup.url != nil }
        finding.notes.append(Note(name: "popup URL", observed: popup.url?.absoluteString ?? "nil"))

        // Console output is only capturable from inside the page, and only if
        // the hook is in place before the bundles run — hence user script plus
        // reload rather than a plain evaluate.
        popup.configuration.userContentController.addUserScript(WKUserScript(
            source: Self.consoleCaptureJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        popup.reload()
        _ = await poll(timeout: 30) { popup.isLoading == false }
        try await Task.sleep(nanoseconds: 20_000_000_000)

        finding.notes.append(Note(name: "captured console + error events", observed: await evaluate("""
            return JSON.stringify(window.__cherryDiag ?? ['capture script never ran']);
            """, in: popup)))

        finding.notes.append(Note(name: "bundles that actually loaded", observed: await evaluate("""
            return JSON.stringify(performance.getEntriesByType('resource')
                .map(r => ({file: r.name.split('/').pop(), bytes: r.decodedBodySize, ms: Math.round(r.duration)})));
            """, in: popup)))

        finding.notes.append(Note(name: "bootstrap markers", observed: await evaluate("""
            const api = globalThis.browser ?? globalThis.chrome;
            return JSON.stringify({
                elements: document.body ? document.body.querySelectorAll('*').length : 0,
                text: document.body ? document.body.innerText.slice(0, 120) : '',
                zone: typeof globalThis.Zone,
                zoneSymbol: typeof globalThis.__zone_symbol__setTimeout,
                appRootChildren: document.querySelector('app-root')?.children.length ?? -1,
                scripts: [...document.scripts].map(s => s.src.split('/').pop()),
                chrome: typeof globalThis.chrome,
                browserNS: typeof globalThis.browser,
                runtimeId: (() => { try { return api?.runtime?.id ?? 'none'; } catch (e) { return 'threw'; } })(),
                getBackgroundPage: typeof api?.extension?.getBackgroundPage,
                runtimeConnect: typeof api?.runtime?.connect,
                webRequest: typeof api?.webRequest,
            });
            """, in: popup)))

        // What the popup's own API calls do, one at a time, each with a
        // deadline: a promise that never settles is the classic "Angular app
        // stuck on the splash" cause and is invisible in the DOM.
        finding.notes.append(Note(name: "API calls the popup makes at boot", observed: await evaluate("""
            const api = globalThis.browser ?? globalThis.chrome;
            const race = (p) => Promise.race([
                Promise.resolve(p).then(v => 'resolved: ' + JSON.stringify(v ?? null).slice(0, 160), e => 'rejected: ' + e),
                new Promise(r => setTimeout(() => r('NEVER SETTLED (10s)'), 10000)),
            ]);
            const out = {};
            try { out.storageLocalGet = await race(api.storage.local.get(null)); } catch (e) { out.storageLocalGet = 'threw: ' + e; }
            try { out.sendMessage = await race(api.runtime.sendMessage({command: 'checkFido2FeatureEnabled'})); } catch (e) { out.sendMessage = 'threw: ' + e; }
            try {
                const port = api.runtime.connect({name: 'popup'});
                out.connect = port ? 'port created' : 'no port';
            } catch (e) { out.connect = 'threw: ' + e; }
            try { out.getBackgroundPage = await race(api.extension?.getBackgroundPage?.()); } catch (e) { out.getBackgroundPage = 'threw: ' + e; }
            try { out.tabsQuery = await race(api.tabs.query({active: true, currentWindow: true})); } catch (e) { out.tabsQuery = 'threw: ' + e; }
            return JSON.stringify(out);
            """, in: popup)))

        finding.notes.append(Note(
            name: "controller's webViewConfiguration.applicationNameForUserAgent",
            observed: ExtensionManager.shared.controller.configuration
                .webViewConfiguration.applicationNameForUserAgent ?? "nil (never set)"))

        // The popup's user agent is the one thing about it Cherry does not
        // configure: `applicationNameForUserAgent` is set on TAB
        // configurations only, never on the extension controller's
        // `webViewConfiguration`. Record what the popup actually sends, and
        // evaluate Bitwarden's own browser detectors against it.
        finding.notes.append(Note(name: "popup user agent and Bitwarden's detectors", observed: await evaluate("""
            const ua = navigator.userAgent;
            return JSON.stringify({
                userAgent: ua,
                isFirefox: ua.indexOf(' Firefox/') !== -1 || ua.indexOf(' Gecko/') !== -1,
                isChrome: !!globalThis.chrome && ua.indexOf(' Chrome/') !== -1,
                isEdge: ua.indexOf(' Edg/') !== -1,
                isVivaldi: ua.indexOf(' Vivaldi/') !== -1,
                isOpera: !!(globalThis.opr?.addons) || !!globalThis.opera || ua.indexOf(' OPR/') >= 0,
                isSafari: ua.indexOf(' Safari/') !== -1,
            });
            """, in: popup)))

        // Causality leg, test-only: give the popup web view a Safari user
        // agent and reload it. If the Angular app boots, the missing product
        // token in the default WKWebView UA is the cause, not a coincidence.
        // `customUserAgent` is set on this throwaway popup web view alone and
        // nothing is written to the app.
        popup.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15"
        popup.reload()
        _ = await poll(timeout: 30) { popup.isLoading == false }
        try await Task.sleep(nanoseconds: 20_000_000_000)
        finding.notes.append(Note(name: "same popup, reloaded with a Safari user agent", observed: await evaluate("""
            return JSON.stringify({
                userAgent: navigator.userAgent,
                elements: document.body ? document.body.querySelectorAll('*').length : 0,
                text: document.body ? document.body.innerText.slice(0, 200) : '',
                errors: (window.__cherryDiag ?? []).slice(0, 3),
            });
            """, in: popup)))

        finding.notes.append(Note(name: "content script artifacts in the page", observed: await evaluate("""
            const attrs = new Set();
            for (const el of document.querySelectorAll('*')) {
                for (const a of el.attributes) if (/bw|bitwarden/i.test(a.name)) attrs.add(a.name);
            }
            return JSON.stringify({
                attributes: [...attrs],
                autofillCSS: getComputedStyle(document.documentElement).getPropertyValue('--bw-toggle') || 'none',
                sheets: [...document.styleSheets].map(s => (s.href || 'inline').split('/').pop()),
            });
            """, in: tab.webView!)))

        finding.notes.append(Note(name: "runtime errors", observed: describeErrors(loaded.context.errors)))
        finding.conclusion = "see captured console + API-call notes"
    }

    private static let consoleCaptureJS = """
        (function () {
            const log = [];
            window.__cherryDiag = log;
            // Safari's Error.stack does NOT include the message, so a bare
            // stack loses the one line that says what went wrong.
            const show = (x) => {
                try {
                    if (x instanceof Error || (x && typeof x.stack === 'string')) {
                        return (x.name || 'Error') + ': ' + (x.message || '(no message)')
                            + ' @@ ' + String(x.stack).slice(0, 700);
                    }
                    return typeof x === 'object' && x !== null ? JSON.stringify(x).slice(0, 500) : String(x);
                } catch (e) { return '<unprintable>'; }
            };
            for (const level of ['log', 'info', 'warn', 'error']) {
                const original = console[level];
                console[level] = function (...args) {
                    if (log.length < 300) log.push(level + ': ' + args.map(show).join(' | ').slice(0, 1200));
                    if (original) original.apply(console, args);
                };
            }
            window.addEventListener('error', (e) => {
                if (log.length < 300) log.push('onerror: ' + e.message + ' @ ' + (e.filename || '?') + ':' + e.lineno
                    + (e.error ? ' | ' + show(e.error) : ''));
            }, true);
            window.addEventListener('unhandledrejection', (e) => {
                if (log.length < 300) log.push('unhandledrejection: ' + show(e.reason));
            });
        })();
        """

    // MARK: - Probe 6: Vimium's rejected content_scripts entry

    /// Two questions: does the `file:///` entry take the WHOLE
    /// `content_scripts` array down with it, and would dropping just that
    /// entry be enough? Vimium's first entry ships `content_scripts/vimium.css`,
    /// which sets `--vimium-background-color` on `:root` — a page-observable
    /// marker that says whether entry 1 injected, independent of any keyboard
    /// behaviour a test cannot synthesise.
    ///
    /// The modified copy is a throwaway in the temporary directory, written to
    /// answer the question and deleted; the shipped package is untouched.
    func test40VimiumContentScriptEntries() async throws {
        var finding = Finding(probe: "40-vimium-content-scripts", notes: [], conclusion: "")
        defer { write(finding) }
        finding.notes.append(preExistingNote)

        // Attribution leg first: the same marker read with nothing loaded, so
        // a value seen later cannot be the page's or Cherry's own.
        let baselineTab = try await openProbeTab()
        finding.notes.append(Note(name: "no extension loaded: marker",
                                  observed: await evaluate(Self.vimiumMarkerJS, in: baselineTab.webView!)))
        closeProbeTab(baselineTab)

        // Control for the messaging leg: what `tabs.sendMessage` does when
        // the tab provably has NO content script listening. Without this, a
        // reply of `null` from Vimium could mean either "no listener" or
        // "listener answered with nothing".
        finding.notes.append(Note(name: "control: sendMessage into a tab with no content script",
                                  observed: try await sendMessageControl()))

        let stockMarker = try await vimiumCSSMarker(loading: {
            try await self.loadCandidate("vimium-ff")
        }, finding: &finding, label: "stock package")

        // Same package, second content_scripts entry removed. Nothing else
        // changed — same files, same ids, same first entry.
        let source = packagesDirectory.appendingPathComponent("vimium-ff.unpacked", isDirectory: true)
        guard FileManager.default.fileExists(atPath: source.path) else {
            finding.conclusion = "stock marker: \(stockMarker); no unpacked copy to run the control against"
            return
        }
        let trimmed = FileManager.default.temporaryDirectory
            .appendingPathComponent("cherry-diag-vimium-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: source, to: trimmed)
        defer { try? FileManager.default.removeItem(at: trimmed) }

        let manifestURL = trimmed.appendingPathComponent("manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        guard var manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
              var contentScripts = manifest["content_scripts"] as? [[String: Any]] else {
            finding.conclusion = "stock marker: \(stockMarker); could not read content_scripts to build the control"
            return
        }
        let removed = contentScripts.filter { entry in
            (entry["matches"] as? [String])?.contains { $0.hasPrefix("file:") } ?? false
        }
        contentScripts.removeAll { entry in
            (entry["matches"] as? [String])?.contains { $0.hasPrefix("file:") } ?? false
        }
        manifest["content_scripts"] = contentScripts
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted]).write(to: manifestURL)
        finding.notes.append(Note(name: "entries removed for the control run",
                                  observed: String(describing: removed)))

        let trimmedMarker = try await vimiumCSSMarker(loading: {
            try await ExtensionManager.shared.loadExtension(from: trimmed)
        }, finding: &finding, label: "file:/// entry removed")

        finding.conclusion = "vimium.css marker — stock: \(stockMarker); without the file:/// entry: \(trimmedMarker)"
    }

    private func vimiumCSSMarker(
        loading load: () async throws -> ExtensionManager.LoadedExtension,
        finding: inout Finding,
        label: String
    ) async throws -> String {
        let loaded = try await load()
        defer { ExtensionManager.shared.remove(extensionID: loaded.id) }
        finding.notes.append(Note(name: "\(label): manifest parse errors",
                                  observed: describeErrors(loaded.webExtension.errors)))

        let tab = try await openProbeTab()
        defer { closeProbeTab(tab) }
        try await Task.sleep(nanoseconds: 3_000_000_000)

        let observed = await evaluate(Self.vimiumMarkerJS, in: tab.webView!)
        finding.notes.append(Note(name: "\(label): page observation", observed: observed))

        // The CSS says entry 1's stylesheet arrived; this says whether its 22
        // JS files did. Vimium's content script registers a `runtime.onMessage`
        // listener with a `getScrollPosition` handler, so a reply from the tab
        // is proof the script is alive in it — and "no receiving end" is proof
        // it is not. Content scripts run in an isolated world, so this is the
        // only way to see them from outside.
        if let popup = await popupWebView(for: loaded, timeout: 20) {
            finding.notes.append(Note(name: "\(label): content script answers a message", observed: await evaluate("""
                const api = globalThis.browser ?? globalThis.chrome;
                try {
                    const tabs = await api.tabs.query({active: true, currentWindow: true});
                    if (!tabs?.length) return 'no active tab visible to the extension';
                    const reply = await Promise.race([
                        api.tabs.sendMessage(tabs[0].id, {handler: 'getScrollPosition'}),
                        new Promise(r => setTimeout(() => r('NEVER SETTLED (8s)'), 8000)),
                    ]);
                    return 'tab ' + tabs[0].id + ' url=' + (tabs[0].url ?? '?') + ' resolved: ' + JSON.stringify(reply ?? null);
                } catch (e) { return 'rejected: ' + e; }
                """, in: popup)))
            // Vimium's own toolbar popup reports whether it considers itself
            // active on the current tab, which it only knows because the
            // content script registered its frame with the background.
            finding.notes.append(Note(name: "\(label): Vimium's own popup says", observed: await evaluate("""
                return JSON.stringify({
                    url: location.href,
                    elements: document.body ? document.body.querySelectorAll('*').length : 0,
                    text: document.body ? document.body.innerText.replace(/\\s+/g, ' ').slice(0, 200) : '',
                });
                """, in: popup)))
        } else {
            finding.notes.append(Note(name: "\(label): content script answers a message", observed: "no popup web view"))
        }

        finding.notes.append(Note(name: "\(label): runtime errors", observed: describeErrors(loaded.context.errors)))
        return observed
    }

    /// Asks Apple's match-pattern parser directly which of Vimium's two
    /// `file:` patterns it rejects, alongside the forms that would have been
    /// accepted — the difference between "Apple rejects this spelling" and
    /// "Apple rejects the `file` scheme" decides what an accommodation could
    /// even look like.
    func test42MatchPatternParserOnFileURLs() async throws {
        var finding = Finding(probe: "42-match-pattern-parser", notes: [], conclusion: "")
        defer { write(finding) }
        finding.notes.append(preExistingNote)

        let candidates = [
            "file:///",         // Vimium's first
            "file:///*/",       // Vimium's second
            "file:///*",
            "file://*/*",
            "file://localhost/*",
            "*://*/*",
            "<all_urls>",
            "https://example.com/*",
        ]
        var rejected: [String] = []
        for candidate in candidates {
            do {
                let pattern = try WKWebExtension.MatchPattern(string: candidate)
                finding.notes.append(Note(name: candidate,
                                          observed: "accepted — scheme=\(pattern.scheme ?? "nil") host=\(pattern.host ?? "nil") path=\(pattern.path ?? "nil")"))
            } catch {
                rejected.append(candidate)
                finding.notes.append(Note(name: candidate, observed: "rejected — \((error as NSError).localizedDescription)"))
            }
        }

        // The escape hatch Apple documents for extra schemes. Whether it will
        // take `file` at all is the whole question for a Cherry-side
        // accommodation.
        WKWebExtension.MatchPattern.registerCustomURLScheme("file")
        do {
            let pattern = try WKWebExtension.MatchPattern(string: "file:///*")
            finding.notes.append(Note(name: "after registerCustomURLScheme(\"file\"): file:///*",
                                      observed: "accepted — scheme=\(pattern.scheme ?? "nil") host=\(pattern.host ?? "nil") path=\(pattern.path ?? "nil")"))
        } catch {
            finding.notes.append(Note(name: "after registerCustomURLScheme(\"file\"): file:///*",
                                      observed: "still rejected — \((error as NSError).localizedDescription)"))
        }

        finding.conclusion = rejected.isEmpty ? "every pattern accepted" : "rejected: \(rejected.joined(separator: ", "))"
    }

    /// Is the `matches` rejection scoped to the offending entry, or does it
    /// take the whole `content_scripts` array with it? Vimium alone cannot
    /// answer that — its first entry's JS leaves nothing observable at rest.
    /// This fixture reproduces the same manifest shape with markers on both
    /// entries, so each one's fate is visible independently.
    func test41ContentScriptRejectionScope() async throws {
        var finding = Finding(probe: "41-content-script-rejection-scope", notes: [], conclusion: "")
        defer { write(finding) }
        finding.notes.append(preExistingNote)

        let fixture = try makeFixture("cs-scope", files: [
            "manifest.json": """
                {
                  "manifest_version": 3,
                  "name": "Cherry Content Script Scope Probe",
                  "version": "1.0",
                  "description": "Two content_scripts entries, the second with Vimium's file: patterns.",
                  "host_permissions": ["<all_urls>"],
                  "content_scripts": [
                    {"matches": ["<all_urls>"], "js": ["one.js"], "css": ["one.css"], "run_at": "document_start"},
                    {"matches": ["file:///", "file:///*/"], "js": ["two.js"], "run_at": "document_start"},
                    {"matches": ["<all_urls>"], "js": ["three.js"], "run_at": "document_end"}
                  ]
                }
                """,
            "one.js": "document.documentElement.setAttribute('data-entry-one', 'ran');",
            "one.css": ":root { --cherry-entry-one: ran; }",
            "two.js": "document.documentElement.setAttribute('data-entry-two', 'ran');",
            "three.js": "document.documentElement.setAttribute('data-entry-three', 'ran');",
        ])
        defer { try? FileManager.default.removeItem(at: fixture) }

        let loaded = try await ExtensionManager.shared.loadExtension(from: fixture)
        defer { ExtensionManager.shared.remove(extensionID: loaded.id) }
        finding.notes.append(Note(name: "manifest parse errors", observed: describeErrors(loaded.webExtension.errors)))

        let tab = try await openProbeTab()
        defer { closeProbeTab(tab) }
        try await Task.sleep(nanoseconds: 2_000_000_000)

        let observed = await evaluate("""
            const root = document.documentElement;
            return JSON.stringify({
                entryOneJS: root.getAttribute('data-entry-one') ?? 'absent',
                entryOneCSS: getComputedStyle(root).getPropertyValue('--cherry-entry-one').trim() || 'absent',
                entryTwoJS: root.getAttribute('data-entry-two') ?? 'absent',
                entryThreeJS: root.getAttribute('data-entry-three') ?? 'absent',
            });
            """, in: tab.webView!)
        finding.notes.append(Note(name: "which entries injected", observed: observed))

        // `WKWebExtensionMatchPattern` parses `file:///*` happily (probe 42),
        // so the rejection is not the pattern grammar. This asks whether the
        // content-script parser merely DISCARDS file patterns: an entry with
        // one file pattern and one https pattern should survive on https if
        // so, and the error should be about entries left with nothing.
        let mixed = try makeFixture("cs-mixed", files: [
            "manifest.json": """
                {
                  "manifest_version": 3,
                  "name": "Cherry Mixed Matches Probe",
                  "version": "1.0",
                  "description": "One entry with a file pattern next to an https one.",
                  "host_permissions": ["<all_urls>"],
                  "content_scripts": [
                    {"matches": ["file:///*", "https://example.com/*"], "js": ["mixed.js"], "run_at": "document_start"}
                  ]
                }
                """,
            "mixed.js": "document.documentElement.setAttribute('data-mixed-entry', 'ran');",
        ])
        defer { try? FileManager.default.removeItem(at: mixed) }

        let mixedLoaded = try await ExtensionManager.shared.loadExtension(from: mixed)
        defer { ExtensionManager.shared.remove(extensionID: mixedLoaded.id) }
        let mixedTab = try await openProbeTab()
        defer { closeProbeTab(mixedTab) }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        finding.notes.append(Note(name: "file: pattern beside an https: one — manifest errors",
                                  observed: describeErrors(mixedLoaded.webExtension.errors)))
        finding.notes.append(Note(name: "file: pattern beside an https: one — injected?", observed: await evaluate("""
            return document.documentElement.getAttribute('data-mixed-entry') ?? 'absent';
            """, in: mixedTab.webView!)))

        finding.conclusion = observed
    }

    /// A fixture with `tabs` permission and deliberately NO content scripts,
    /// asking the same question of the same page. Whatever this returns is
    /// what "nobody is listening" looks like in this runtime.
    private func sendMessageControl() async throws -> String {
        let fixture = try makeFixture("no-content-script", files: [
            "manifest.json": """
                {
                  "manifest_version": 3,
                  "name": "Cherry Messaging Control",
                  "version": "1.0",
                  "description": "No content scripts on purpose.",
                  "permissions": ["tabs"],
                  "host_permissions": ["<all_urls>"],
                  "background": {"scripts": ["bg.js"], "service_worker": "bg.js", "persistent": false},
                  "action": {"default_popup": "popup.html", "default_title": "Control"}
                }
                """,
            "bg.js": "// nothing",
            "popup.html": "<!DOCTYPE html><html><body id=\"control\">control</body></html>",
        ])
        defer { try? FileManager.default.removeItem(at: fixture) }

        let loaded = try await ExtensionManager.shared.loadExtension(from: fixture)
        defer { ExtensionManager.shared.remove(extensionID: loaded.id) }
        let tab = try await openProbeTab()
        defer { closeProbeTab(tab) }

        guard let popup = await popupWebView(for: loaded, timeout: 20) else { return "no popup web view" }
        return await evaluate("""
            const api = globalThis.browser ?? globalThis.chrome;
            try {
                const tabs = await api.tabs.query({active: true, currentWindow: true});
                if (!tabs?.length) return 'no active tab visible to the extension';
                const reply = await Promise.race([
                    api.tabs.sendMessage(tabs[0].id, {handler: 'getScrollPosition'}),
                    new Promise(r => setTimeout(() => r('NEVER SETTLED (8s)'), 8000)),
                ]);
                return 'resolved: ' + JSON.stringify(reply ?? null);
            } catch (e) { return 'rejected: ' + e; }
            """, in: popup)
    }

    /// `--vimium-background-color` is declared only by `content_scripts/vimium.css`
    /// — `white` on `:root`, `#1d1d1f` inside its `prefers-color-scheme: dark`
    /// block. Either value means that stylesheet reached the page; `absent`
    /// means it did not. example.com declares no custom properties at all.
    private static let vimiumMarkerJS = """
        const marker = getComputedStyle(document.documentElement).getPropertyValue('--vimium-background-color').trim();
        return JSON.stringify({
            vimiumCSSVariable: marker || 'absent',
            vimiumElements: document.querySelectorAll('[class*=vimium], [id*=vimium]').length,
        });
        """
}

// MARK: - Navigation delegate recorder

/// Records every `decidePolicyForNavigationAction` the delegate is asked
/// about, so probe 21 can say exactly which request kinds an embedder gets a
/// veto on.
private final class NavigationActionRecorder: NSObject, WKNavigationDelegate {
    private var calls: [String] = []
    private(set) var didFinish = false

    func snapshot() -> [String] { calls }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url?.absoluteString ?? "?"
        calls.append("\(navigationAction.targetFrame?.isMainFrame == true ? "main" : "sub")-frame \(url.prefix(90))")
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didFinish = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        didFinish = true
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        didFinish = true
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
