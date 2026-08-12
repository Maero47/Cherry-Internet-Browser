//
//  ExtensionRuntimeTests.swift
//  Internet BrowserTests
//
//  Two things the extension runtime got wrong, pinned at the entry points a
//  mutation would actually go through:
//
//  1. Extension pages (popup, options, background) are built by WebKit from
//     the extension controller's own `webViewConfiguration`, which is NOT the
//     configuration tabs get. It carried no user agent at all, so an
//     extension that sniffs the UA to work out which browser it's in matched
//     nothing — Bitwarden's popup threw inside Angular's DI and never left
//     its loading shell. The fix is one source for the string; these tests
//     fail if a second copy of it reappears anywhere in the app sources,
//     because that is exactly how tabs get raised to a new Safari version and
//     extension pages get left behind.
//
//  2. `WKWebExtension.errors` is a list of manifest entries WebKit DROPPED
//     while loading the rest of the extension — not a load failure. Vimium is
//     the standing case: one `content_scripts` entry matches only `file:///`,
//     the content-script parser discards it, and the extension runs. The
//     tests below hold the two sides apart: a package with a dropped entry
//     loads AND says what was dropped; a package WebKit refuses still fails.
//
//  These load real packages through a real `ExtensionManager` — but never
//  through `ExtensionManager.shared`, which installs into the USER'S
//  Application Support extension index. Removing each load in a `defer` was
//  not enough: a test that fails between the load and the defer, or a host
//  that dies, leaves the fixture installed and enabled in the owner's
//  browser, which is how two copies of uBO Lite once ended up in it. Each
//  load below goes through `ExtensionManager.isolatedForTesting(directory:)`
//  over a temporary directory that is deleted with the test, the same way
//  `ExtensionOptionsPageTests` and `ExtensionDuplicateInstallTests` do it.
//  The one thing still read from `shared` is its controller's configuration,
//  which is read and not written.
//

import WebKit
import XCTest
@testable import Cherry

@MainActor
final class ExtensionRuntimeTests: XCTestCase {

    /// A manager with its own extensions directory, deleted when the test
    /// ends. Everything that LOADS a package uses one of these; the user's
    /// own extension index is never installed into.
    private func isolatedManager() -> ExtensionManager {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cherry-runtime-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return ExtensionManager.isolatedForTesting(directory: directory)
    }

    // MARK: - The user agent extension pages get

    /// The controller's web view configuration — the one WebKit builds every
    /// popup, options page and background page from — must carry Cherry's
    /// product token. Reads the REAL shared controller, so deleting the
    /// configuration wiring in `ExtensionManager` (back to a plain
    /// `WKWebExtensionController()`) fails here.
    func testExtensionPagesCarryCherrysUserAgent() {
        let extensionUserAgent = ExtensionManager.shared.controller
            .configuration.webViewConfiguration.applicationNameForUserAgent

        XCTAssertEqual(
            extensionUserAgent, BrowserUserAgent.applicationName,
            "extension popups/options/background pages present no product token — the Bitwarden case"
        )
    }

    /// …and it must be the SAME token a real tab presents. Goes through
    /// `TabManager`'s own background-tab entry point rather than building a
    /// configuration by hand, so changing the user agent on the tab side
    /// alone — the mutation that silently strands extension pages — fails
    /// here rather than passing quietly.
    func testATabAndAnExtensionPageAgreeOnTheUserAgent() throws {
        let viewModel = BrowserViewModel(withDefaultTab: false)
        let tab = viewModel.tabManager.openBackgroundResearchTab(
            url: URL(string: "about:blank")!, title: "user agent probe"
        )
        defer { viewModel.tabManager.closeTab(tab) }

        let tabUserAgent = try XCTUnwrap(tab.webView?.configuration.applicationNameForUserAgent)
        let extensionUserAgent = ExtensionManager.shared.controller
            .configuration.webViewConfiguration.applicationNameForUserAgent

        XCTAssertEqual(tabUserAgent, extensionUserAgent,
                       "a tab and an extension page must present the same browser")
    }

    /// The "one source" claim itself. A value comparison can't make it:
    /// two identical literals compare equal today and diverge on the next
    /// edit. So this reads the app's own source tree and requires that the
    /// only assignment to `applicationNameForUserAgent` in it is the one
    /// inside `BrowserUserAgent`.
    func testTheUserAgentIsAssignedInExactlyOnePlace() throws {
        let assignment = try NSRegularExpression(pattern: #"applicationNameForUserAgent\s*=[^=]"#)
        var assigningFiles: [String] = []

        try forEachAppSourceFile { path, contents in
            let range = NSRange(contents.startIndex..., in: contents)
            if assignment.firstMatch(in: contents, range: range) != nil {
                assigningFiles.append(path)
            }
        }

        XCTAssertEqual(
            assigningFiles.sorted(), ["Features/Browser/Models/BrowserUserAgent.swift"],
            "the user agent must have one source; a second copy is how extension pages get left behind"
        )
    }

    /// Configuration equality is not the claim — what an extension page
    /// SENDS is. This loads a fixture extension whose popup reports
    /// `navigator.userAgent` and requires the product token to be in it, so
    /// the page-level effect the whole change exists for is measured rather
    /// than inferred from a property. It also covers the blast radius: this
    /// user agent is what every extension's popup, options page and
    /// background page now sees.
    func testAnExtensionPopupReallySendsTheUserAgent() async throws {
        let package = try makeFixturePackage(named: "user-agent", manifest: Self.popupManifest)
        let manager = isolatedManager()
        let loaded = try await manager.loadExtension(from: package)
        defer { manager.remove(extensionID: loaded.id) }

        let popup = try XCTUnwrap(loaded.context.action(for: nil)?.popupWebView,
                                  "fixture popup web view unavailable — harness problem, not a UA one")
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, popup.isLoading || popup.url == nil {
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        let reported = try await popup.callAsyncJavaScript(
            "return navigator.userAgent;", arguments: [:], in: nil, contentWorld: .page
        ) as? String

        let userAgent = try XCTUnwrap(reported)
        XCTAssertTrue(userAgent.contains(BrowserUserAgent.applicationName),
                      "an extension popup still presents a user agent with no product token: \(userAgent)")
    }

    // MARK: - A dropped manifest entry is a warning, not a failure

    /// The Vimium shape, as a fixture: three `content_scripts` entries, the
    /// middle one matching only `file:` URLs. WebKit's content-script parser
    /// discards `file:` patterns, leaving that entry with no matches, and
    /// reports it — while loading the extension and running the other two
    /// entries.
    ///
    /// Goes through `ExtensionManager.loadExtension(from:)` and reads the
    /// installed entry back, so making that path throw on a non-empty
    /// `errors` array, or dropping `packageStatus` back to a plain
    /// loaded/not-loaded flag, fails here.
    func testAPackageWithADroppedEntryLoadsAndSaysWhatWasDropped() async throws {
        let package = try makeFixturePackage(named: "dropped-entry", manifest: Self.droppedEntryManifest)
        let manager = isolatedManager()
        let installedBefore = manager.installedExtensions.count

        let loaded = try await manager.loadExtension(from: package)
        defer { manager.remove(extensionID: loaded.id) }

        // It is RUNNING: a context exists and the controller holds it.
        XCTAssertTrue(manager.loadedExtensions.contains { $0.id == loaded.id },
                      "an extension with a dropped manifest entry must still be loaded")
        XCTAssertEqual(manager.installedExtensions.count, installedBefore + 1)

        let installed = try XCTUnwrap(
            manager.installedExtensions.first { $0.id == loaded.id }
        )
        guard case .partiallyDropped(let dropped) = installed.packageStatus else {
            return XCTFail("expected dropped entries to be a warning, got \(installed.packageStatus)")
        }

        // Honest means specific: every line must carry WebKit's own account
        // of what it dropped, not a house-written "something went wrong".
        // Asserted against WebKit's text rather than any wording of ours.
        let webKitErrors = loaded.webExtension.errors.map { ($0 as NSError).localizedDescription }
        XCTAssertFalse(webKitErrors.isEmpty, "fixture no longer reproduces a dropped manifest entry")
        XCTAssertEqual(dropped.count, webKitErrors.count)
        for (line, webKitError) in zip(dropped, webKitErrors) {
            XCTAssertTrue(line.contains(webKitError), "warning line dropped WebKit's own detail: \(line)")
        }

        // And it is a warning against a loaded extension, never a failure.
        XCTAssertTrue(installed.packageStatus.isWarningAgainstALoadedExtension)
        XCTAssertNil(installed.loadFailure)
    }

    /// The other side: a package WebKit refuses outright still fails, at the
    /// same entry point, and leaves nothing behind claiming to be installed.
    func testAGenuinelyBrokenPackageStillFailsToLoad() async throws {
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("cherry-broken-extension-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: package) }
        // A directory with no `manifest.json` at all — nothing for WebKit to
        // drop an entry from, and nothing to run.
        try "not a manifest".write(to: package.appendingPathComponent("readme.txt"),
                                   atomically: true, encoding: .utf8)

        let manager = isolatedManager()
        let installedBefore = manager.installedExtensions.map(\.id)
        let managedBefore = try managedExtensionDirectories(of: manager)

        var thrown: (any Error)?
        do {
            let loaded = try await manager.loadExtension(from: package)
            manager.remove(extensionID: loaded.id)
        } catch {
            thrown = error
        }

        let failure = try XCTUnwrap(thrown, "a package with no manifest must not report as loaded")
        XCTAssertEqual(manager.installedExtensions.map(\.id), installedBefore,
                       "a failed load must not leave an installed extension behind")
        // …nor a copy of the package on disk: the managed copy is taken
        // before WebKit is asked to parse it, and an orphan there is
        // unreachable from the settings pane forever.
        XCTAssertEqual(try managedExtensionDirectories(of: manager), managedBefore,
                       "a failed load left its package copy in the extensions directory")

        // The same reason, seen from the launch-time reload path (which has
        // no caller to throw to), must classify as a failure — never as a
        // warning against something that is running.
        let status = ExtensionPackageStatus.of(
            hasPackage: false, droppedEntries: [], loadFailure: ExtensionManager.describe(failure)
        )
        XCTAssertFalse(status.isWarningAgainstALoadedExtension)
        guard case .failed(let reason) = status else {
            return XCTFail("expected a failure, got \(status)")
        }
        XCTAssertFalse(reason.isEmpty, "a failure must say why")
    }

    /// The four states, as a value — including the one no fixture can
    /// arrange (a persisted package that fails during launch-time reload)
    /// and the one that must stay silent (still loading).
    func testThePackageStatusesAreHeldApart() {
        XCTAssertEqual(
            ExtensionPackageStatus.of(hasPackage: true, droppedEntries: [], loadFailure: nil), .intact
        )
        XCTAssertEqual(
            ExtensionPackageStatus.of(hasPackage: true, droppedEntries: ["entry A"], loadFailure: nil),
            .partiallyDropped(["entry A"])
        )
        XCTAssertEqual(
            ExtensionPackageStatus.of(hasPackage: false, droppedEntries: [], loadFailure: "no manifest"),
            .failed("no manifest")
        )
        XCTAssertEqual(
            ExtensionPackageStatus.of(hasPackage: false, droppedEntries: [], loadFailure: nil), .pending
        )

        // A package that failed is never described as partly working, even
        // if the parser had complaints on the way down.
        XCTAssertEqual(
            ExtensionPackageStatus.of(hasPackage: false, droppedEntries: ["entry A"], loadFailure: "gone"),
            .failed("gone")
        )

        // Only a dropped entry is a warning against a running extension, and
        // only the two speaking states say anything at all.
        XCTAssertTrue(ExtensionPackageStatus.partiallyDropped(["x"]).isWarningAgainstALoadedExtension)
        XCTAssertFalse(ExtensionPackageStatus.failed("x").isWarningAgainstALoadedExtension)
        XCTAssertNil(ExtensionPackageStatus.intact.summary)
        XCTAssertNil(ExtensionPackageStatus.pending.summary)
        XCTAssertEqual(ExtensionPackageStatus.partiallyDropped(["x", "y"]).details, ["x", "y"])
        XCTAssertEqual(ExtensionPackageStatus.failed("why").details, ["why"])
    }

    /// The settings pane is where a warning has to live — a status nobody
    /// draws is not a report. The row is a SwiftUI view with no seam a test
    /// can render, so this pins the wiring at the source level: deleting the
    /// status block from the row fails here.
    func testTheSettingsPaneDrawsThePackageStatus() throws {
        let pane = try appSource("Features/Extensions/Views/ExtensionsSettingsView.swift")
        XCTAssertTrue(pane.contains("installed.packageStatus"),
                      "the extensions settings pane must read what WebKit said about each package")
        XCTAssertTrue(pane.contains(".summary") && pane.contains(".details"),
                      "the pane must show the specifics, not just that something happened")

        // Reading the status is not showing it: the row's body has to place
        // the lines. Pinned as a bare `packageStatusLines` statement inside
        // the row, which is what disappears if the block is dropped while
        // the (now unused) property stays behind.
        let placedInTheRow = try NSRegularExpression(pattern: #"(?m)^\s*packageStatusLines\s*$"#)
        XCTAssertEqual(
            placedInTheRow.numberOfMatches(in: pane, range: NSRange(pane.startIndex..., in: pane)), 1,
            "the extension row must actually place the status lines in its body"
        )
    }

    /// Every per-extension folder in the app's managed extensions directory,
    /// sorted. This is the USER'S real directory (the tests run in the hosted
    /// app), which is exactly why what these tests leave in it matters.
    private func managedExtensionDirectories(of manager: ExtensionManager) throws -> [String] {
        guard FileManager.default.fileExists(atPath: manager.managedDirectory.path) else { return [] }
        let contents = try FileManager.default.contentsOfDirectory(
            atPath: manager.managedDirectory.path
        )
        return contents.filter { $0 != "index.json" }.sorted()
    }

    // MARK: - Fixtures

    /// Three `content_scripts` entries; the middle one carries only `file:`
    /// patterns, which is the exact shape of the entry WebKit drops from
    /// Vimium's manifest.
    private static let droppedEntryManifest = """
        {
          "manifest_version": 3,
          "name": "Cherry Dropped Entry Fixture",
          "version": "1.0",
          "description": "One content_scripts entry WebKit cannot use, beside two it can.",
          "host_permissions": ["<all_urls>"],
          "content_scripts": [
            {"matches": ["<all_urls>"], "js": ["one.js"], "run_at": "document_end"},
            {"matches": ["file:///", "file:///*/"], "js": ["two.js"], "run_at": "document_end"},
            {"matches": ["<all_urls>"], "js": ["three.js"], "run_at": "document_end"}
          ]
        }
        """

    /// A toolbar action with a popup, and nothing else — the popup page is
    /// where the user agent is read from.
    private static let popupManifest = """
        {
          "manifest_version": 3,
          "name": "Cherry User Agent Fixture",
          "version": "1.0",
          "description": "Reports the user agent its popup page presents.",
          "action": {"default_popup": "popup.html", "default_title": "User agent"}
        }
        """

    /// Writes an unpacked extension directory into the temporary directory
    /// and returns it. Registers its own removal with the running test.
    private func makeFixturePackage(named name: String, manifest: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cherry-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        try manifest.write(to: directory.appendingPathComponent("manifest.json"),
                           atomically: true, encoding: .utf8)
        for script in ["one.js", "two.js", "three.js"] {
            try "document.documentElement.setAttribute('data-cherry-\(script)', '1');"
                .write(to: directory.appendingPathComponent(script), atomically: true, encoding: .utf8)
        }
        try "<!DOCTYPE html><html><body id=\"cherry-popup\">popup</body></html>"
            .write(to: directory.appendingPathComponent("popup.html"), atomically: true, encoding: .utf8)
        return directory
    }

    // MARK: - Reading the app's own sources

    /// Both source-level tests above go through `AppSourceTree`, which reads
    /// the tree under a deadline. Reading it directly is what used to hang
    /// this whole target: the checkout lives under `~/Documents`, macOS gates
    /// that read behind a permission dialog nobody can answer during
    /// `xcodebuild test`, and `open(2)` never returns. See `AppSourceTree`.
    private func appSource(_ relativePath: String) throws -> String {
        try AppSourceTree.read(relativePath)
    }

    /// Visits every Swift file under the app source root, handing the callback
    /// the path relative to that root and the file's contents.
    private func forEachAppSourceFile(_ body: (String, String) throws -> Void) throws {
        let files = try AppSourceTree.swiftFiles()
        for file in files { try body(file.path, file.contents) }
        XCTAssertGreaterThan(files.count, 100, "app source tree not found — the scan below proves nothing")
    }
}
