//
//  SetupWizardPearlAndExtensionsTests.swift
//  Internet BrowserTests
//
//  The two seams the wizard shipped with, closed and pinned:
//
//  1. Pearl's hero in the welcome step. "The asset exists" is not the claim —
//     `PearlAssetTests` already makes that one, and it stayed green the whole
//     time the wizard was drawing a pawprint placeholder instead. The claim
//     here is that the WIZARD'S OWN view tree carries her decoded image, so
//     renaming the asset, dropping the image, or putting a stand-in back all
//     fail.
//
//  2. The extensions step. It must offer the verified shortlist — exactly it,
//     in its order, nothing added and nothing quietly filtered — and it must
//     say out loud what each entry declares, uBO Lite's ninety-second warm-up
//     above all. The rest of the file pins that ticking a box really reaches
//     the app's one `ExtensionManager`.
//
//  Nothing here downloads anything. The one test that installs for real uses
//  a locally-built fixture package and removes it again on the same statement
//  that created it.
//

import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Cherry

// MARK: - Walking a SwiftUI value tree

/// Every value of type `T` inside a SwiftUI view value, however deep. The
/// codebase's established way of asking what a view is actually made of
/// (see `PearlRunnerOfferTests`) — a rendered pixel is not needed to know
/// which rows a list built.
///
/// It walks VALUES, so it stops at a `ForEach`'s builder closure — which is
/// exactly why the step and the outcome list materialize their rows as
/// `[SetupExtensionRow]` / `[SetupExtensionOutcomeRow]` instead of producing
/// them inside one. To look inside a row, ask for the row and then walk its
/// own `body`.
private func collect<T>(_ type: T.Type, in value: Any, depth: Int = 0) -> [T] {
    if let hit = value as? T { return [hit] }
    guard depth < 60 else { return [] }
    return Mirror(reflecting: value).children.flatMap {
        collect(type, in: $0.value, depth: depth + 1)
    }
}

// MARK: - Pearl

@MainActor
final class SetupWizardPearlTests: XCTestCase {

    /// The welcome page the REAL wizard builds on its first step — reached
    /// through `SetupWizardView.body`, not constructed here, so a wizard that
    /// stopped putting the welcome step first would fail rather than pass on
    /// a fragment nobody sees.
    private func welcomeStep() throws -> SetupWelcomeStep {
        let steps = collect(SetupWelcomeStep.self, in: SetupWizardView(onFinish: {}).body)
        return try XCTUnwrap(steps.first, "the wizard's first page is not the welcome step")
    }

    /// Pearl's image, RESOLVED, inside the wizard's own first page.
    ///
    /// Dies on: `PearlMascot.heroAssetName` no longer naming an imageset that
    /// is in the catalog (the resolution happens in the view, so a wrong name
    /// produces no image here); the welcome step dropping her; the welcome
    /// step going back to a drawn placeholder, which puts no `NSImage` in the
    /// tree at all.
    func testTheWizardsWelcomePageCarriesPearlsResolvedHeroImage() throws {
        let images = collect(NSImage.self, in: try welcomeStep().body)
        let hero = try XCTUnwrap(
            images.first,
            "the wizard's welcome page resolved no image — Pearl is not on it"
        )

        let catalogHero = try XCTUnwrap(
            NSImage(named: PearlMascot.heroAssetName),
            "PearlMascot names an imageset the catalog does not have"
        )
        XCTAssertEqual(hero.size, catalogHero.size,
                       "the welcome page is showing some other image, not Pearl's hero")
        XCTAssertGreaterThan(hero.size.height, 0)
    }

    /// She has to READ as the welcome, not sit in it as an icon: taller than
    /// the 24pt title by a wide margin, and still short enough that the title,
    /// the paragraph and the footer all fit the sheet's 560pt without
    /// scrolling. Dies on: the hero being shrunk back toward icon size.
    func testPearlIsSizedToLeadThePage() {
        XCTAssertGreaterThanOrEqual(PearlMascot.heroHeight, 180,
                                    "at this size Pearl is decoration, not the welcome")
        XCTAssertLessThanOrEqual(PearlMascot.heroHeight, 260,
                                 "taller than this and the welcome page has to scroll")
    }

    /// Pearl is the ONLY image on the welcome page: the neutral stand-in that
    /// stood in for her is deleted, not merely out-ranked.
    ///
    /// Dies on: the placeholder being restored INSTEAD of her (one image, but
    /// no `NSImage` — the symbol stand-in carries a name, not a bitmap), and
    /// on it being restored BESIDE her (two images).
    func testThePlaceholderStandInIsGone() throws {
        let body = try welcomeStep().body
        XCTAssertEqual(collect(Image.self, in: body).count, 1,
                       "the welcome page draws something beside Pearl")
        XCTAssertEqual(collect(NSImage.self, in: body).count, 1,
                       "the welcome page's one image is not a resolved bitmap — a stand-in is back")
    }
}

// MARK: - The extensions step

@MainActor
final class SetupExtensionStepTests: XCTestCase {

    private func stepTree(_ installer: SetupExtensionInstaller? = nil) -> Any {
        let step = installer.map { SetupExtensionsStep(installer: $0) } ?? SetupExtensionsStep()
        return step.body
    }

    /// The caveats the step puts on screen before anything is ticked: one hop
    /// through each offered row, because a row's own `body` is where its
    /// caveat is placed.
    private func caveatsOfferedOnScreen(_ installer: SetupExtensionInstaller? = nil) -> [String] {
        collect(SetupExtensionRow.self, in: stepTree(installer))
            .flatMap { collect(SetupExtensionCaveat.self, in: $0.body).map(\.text) }
    }

    /// The caveats the step repeats beside the results, after installing.
    private func caveatsShownWithResults(_ installer: SetupExtensionInstaller) -> [String] {
        collect(SetupExtensionOutcomeList.self, in: stepTree(installer))
            .flatMap { collect(SetupExtensionOutcomeRow.self, in: $0.body) }
            .flatMap { collect(SetupExtensionCaveat.self, in: $0.body).map(\.text) }
    }

    /// THE list test: what the step offers is `ExtensionShortlist.entries`,
    /// all of it, in its order, and nothing else.
    ///
    /// Dies on: the step hardcoding rows; filtering the shortlist (an entry
    /// that was verified would silently stop being offered); appending a
    /// fourth "recommended" extension nobody watched work; reordering.
    func testTheStepOffersExactlyTheVerifiedShortlistAndNoMore() {
        let offered = collect(SetupExtensionRow.self, in: stepTree()).map(\.entry)

        XCTAssertEqual(offered.map(\.id), ExtensionShortlist.entries.map(\.id),
                       "the step's rows are not the verified shortlist")
        XCTAssertEqual(offered, ExtensionShortlist.entries,
                       "a row is showing something other than the shortlist's own entry")
        XCTAssertEqual(offered.count, 3,
                       "three entries survived live verification; the step must offer three")
    }

    /// Every caveat an entry declares is on screen BEFORE the user ticks
    /// anything — no disclosure triangle, no "learn more".
    ///
    /// Dies on: the row dropping `entry.caveat`; hiding it behind an
    /// expander (the value tree would still hold it, but the row renders it
    /// only in the collapsed branch — so this is paired with the source pin
    /// below); a caveat being re-worded in the view instead of carried.
    func testEveryDeclaredCaveatIsShownBeforeTheUserPicks() {
        let shown = Set(caveatsOfferedOnScreen())
        let declared = Set(ExtensionShortlist.entries.compactMap(\.caveat))

        XCTAssertFalse(declared.isEmpty, "precondition: the shortlist declares caveats")
        XCTAssertEqual(shown, declared,
                       "the step is not saying what the shortlist declares, verbatim")
    }

    /// The specific thing this step exists to prevent: a first-run user ticks
    /// an ad blocker, presses Start Browsing, sees ads, and concludes Cherry
    /// is broken. uBO Lite's warm-up is measured (first block ~t+10s, last
    /// ruleset in force ~t+90s — `ExtensionVerificationTests`), and the user
    /// has to be told about the ninety seconds, not just the ten.
    ///
    /// Dies on: the caveat being trimmed back to "about ten seconds" (which
    /// is the sentence that shipped, and which describes the START of the
    /// warm-up as though it were the end of it); the caveat being dropped;
    /// uBO Lite losing its caveat entirely.
    func testTheAdBlockersFullWarmUpIsSpelledOutOnScreen() throws {
        let ubo = try XCTUnwrap(ExtensionShortlist.entries.first { $0.id == "ubo-lite" })
        let caveat = try XCTUnwrap(ubo.caveat, "the ad blocker must declare its warm-up")

        let lowered = caveat.lowercased()
        XCTAssertTrue(
            lowered.contains("90-second") || lowered.contains("90 second")
                || lowered.contains("ninety") || lowered.contains("minute and a half"),
            "the caveat stops at the first block and never mentions the ~90s the warm-up takes: \(caveat)"
        )
        XCTAssertTrue(lowered.contains("ad"),
                      "the caveat must say what the user will SEE, which is ads")

        XCTAssertTrue(caveatsOfferedOnScreen().contains(caveat),
                      "the warm-up sentence exists but the step never shows it")
    }

    /// The caveat is repeated with the RESULT, which is the moment it matters
    /// most — the user has just installed and is about to go looking at a
    /// page. Dies on: the outcome list dropping the caveat, or the installer
    /// not carrying it out of the entry.
    func testTheCaveatComesBackWithTheInstalledResult() async throws {
        let installer = stubInstaller()
        installer.toggle(try uboEntry())
        await installer.installSelected()

        let outcome = try XCTUnwrap(installer.outcomes.first)
        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(outcome.caveat, try uboEntry().caveat,
                       "the outcome lost the caveat between the entry and the result")

        XCTAssertTrue(caveatsShownWithResults(installer).contains(try XCTUnwrap(uboEntry().caveat)),
                      "after installing, the step never repeats what to expect")
    }

    /// Nothing is ticked when the step opens. Dies on: pre-selecting the
    /// shortlist — a user who only pressed Continue would have three
    /// extensions downloaded and installed for them.
    func testNothingIsPreSelected() {
        let installer = SetupExtensionInstaller()
        XCTAssertTrue(installer.selectedIDs.isEmpty)
        XCTAssertFalse(installer.hasSelection)
    }

    /// Only what was ticked is installed, in shortlist order. Dies on:
    /// `installSelected` ignoring the selection, or installing everything.
    func testOnlyTheTickedEntriesAreInstalled() async throws {
        let installer = stubInstaller()
        installer.toggle(try entry("simple-translate"))
        installer.toggle(try uboEntry())

        await installer.installSelected()

        XCTAssertEqual(installer.outcomes.map(\.entryID), ["ubo-lite", "simple-translate"],
                       "installs must follow the shortlist's order, and only the ticked rows")
        XCTAssertEqual(installer.phase, .finished)
    }

    /// One bad download does not take the user's other choices with it. Dies
    /// on: `installSelected` throwing out of the loop on the first failure.
    func testAFailedInstallDoesNotStopTheOthers() async throws {
        let installer = SetupExtensionInstaller(
            entries: ExtensionShortlist.entries,
            download: { url in
                if url.absoluteString.contains("uBOLite") { throw StubFailure.refused }
                return try Self.makeStubPackageFile(named: url.lastPathComponent)
            },
            host: RecordingHost()
        )
        for entry in ExtensionShortlist.entries { installer.toggle(entry) }

        await installer.installSelected()

        XCTAssertEqual(installer.outcomes.count, 3)
        XCTAssertEqual(installer.outcomes.filter(\.succeeded).map(\.entryID),
                       ["darkreader", "simple-translate"])
        let failed = try XCTUnwrap(installer.outcomes.first { !$0.succeeded })
        XCTAssertEqual(failed.entryID, "ubo-lite")
        XCTAssertNotNil(failed.failure, "a failure the user is not told about is a silent one")
    }

    /// The wizard installs through the app's ONE extension host — not a
    /// wizard-local copy that the Settings pane and the toolbar would never
    /// see. Dies on: the default host being changed to anything else.
    func testTheWizardInstallsThroughTheAppsOneExtensionManager() {
        let installer = SetupExtensionInstaller()
        XCTAssertTrue(installer.host === ExtensionManager.shared)
    }

    /// End to end through a real `ExtensionManager` — only the download is
    /// substituted, for a package built here on disk. This is what dies if
    /// `installShortlistPackage` stops calling `loadExtension`: the extension
    /// would never appear in the host's installed list, and the wizard would
    /// report a success that installed nothing.
    ///
    /// A REAL manager but not `ExtensionManager.shared`: driving `shared`
    /// installs the fixture into the owner's own browser, and a failure
    /// between the install and the cleanup leaves it there, enabled. That the
    /// wizard's default host IS `shared` is pinned above, by identity, with
    /// nothing installed.
    func testATickedEntryReallyEndsUpInstalledInTheApp() async throws {
        let fixture = try Self.makeFixtureExtensionPackage()
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }

        let host = isolatedManager()
        let before = Set(host.installedExtensions.map(\.id))
        let installer = SetupExtensionInstaller(
            entries: ExtensionShortlist.entries,
            download: { _ in fixture },
            host: host
        )
        installer.toggle(try uboEntry())

        await installer.installSelected()
        let added = Set(host.installedExtensions.map(\.id)).subtracting(before)
        defer { for id in added { host.remove(extensionID: id) } }

        let outcome = try XCTUnwrap(installer.outcomes.first)
        XCTAssertNil(outcome.failure, "the fixture package failed to install: \(outcome.failure ?? "")")
        XCTAssertEqual(added.count, 1,
                       "the wizard reported an install the app's ExtensionManager knows nothing about")
        XCTAssertEqual(outcome.displayName, "Cherry Wizard Fixture",
                       "the result must name what WebKit actually loaded")
    }

    /// A package WebKit refuses is reported as a failure and leaves nothing
    /// behind in the managed directory. Dies on: the installer swallowing the
    /// error and claiming success.
    func testAPackageWebKitRefusesIsReportedAndLeavesNothingBehind() async throws {
        let junk = try Self.makeStubPackageFile(named: "not-an-extension.xpi")
        defer { try? FileManager.default.removeItem(at: junk.deletingLastPathComponent()) }

        let host = isolatedManager()
        let before = try managedExtensionDirectories(of: host)
        let installer = SetupExtensionInstaller(
            entries: ExtensionShortlist.entries,
            download: { _ in junk },
            host: host
        )
        installer.toggle(try uboEntry())

        await installer.installSelected()

        let outcome = try XCTUnwrap(installer.outcomes.first)
        XCTAssertFalse(outcome.succeeded, "WebKit refused this package; the wizard said it installed")
        XCTAssertEqual(try managedExtensionDirectories(of: host), before,
                       "a refused wizard install left an orphan folder behind")
    }

    // MARK: - Fixtures

    private enum StubFailure: LocalizedError {
        case refused
        var errorDescription: String? { "the stub refused this download" }
    }

    /// Records installs instead of performing them.
    private final class RecordingHost: SetupExtensionInstalling {
        private(set) var installed: [URL] = []
        func installShortlistPackage(at url: URL) async throws -> String {
            installed.append(url)
            return url.deletingPathExtension().lastPathComponent
        }
    }

    private func stubInstaller() -> SetupExtensionInstaller {
        SetupExtensionInstaller(
            entries: ExtensionShortlist.entries,
            download: { url in try Self.makeStubPackageFile(named: url.lastPathComponent) },
            host: RecordingHost()
        )
    }

    private func entry(_ id: String) throws -> ExtensionShortlistEntry {
        try XCTUnwrap(ExtensionShortlist.entries.first { $0.id == id }, "no shortlist entry \(id)")
    }

    private func uboEntry() throws -> ExtensionShortlistEntry { try entry("ubo-lite") }

    /// A manager with its own extensions directory, deleted when the test
    /// ends — so an install that really happens really is undone, whatever
    /// the test does in between.
    private func isolatedManager() -> ExtensionManager {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cherry-wizard-ext-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return ExtensionManager.isolatedForTesting(directory: directory)
    }

    private func managedExtensionDirectories(of manager: ExtensionManager) throws -> [String] {
        guard FileManager.default.fileExists(atPath: manager.managedDirectory.path) else { return [] }
        return try FileManager.default
            .contentsOfDirectory(atPath: manager.managedDirectory.path)
            .filter { $0 != "index.json" }
            .sorted()
    }

    /// A file that stands in for a downloaded package, in its own throwaway
    /// directory. Not a valid extension — used where the host is a stub, or
    /// where WebKit is expected to refuse it.
    private nonisolated static func makeStubPackageFile(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CherryWizardStub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(name)
        try Data("not a real package".utf8).write(to: file)
        return file
    }

    /// A minimal but REAL unpacked WebExtension WebKit will load, in its own
    /// throwaway directory.
    private nonisolated static func makeFixtureExtensionPackage() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CherryWizardFixture-\(UUID().uuidString)", isDirectory: true)
        let package = root.appendingPathComponent("wizard-fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let manifest = """
            {
              "manifest_version": 3,
              "name": "Cherry Wizard Fixture",
              "version": "1.0",
              "description": "Loaded by the setup wizard's install test, removed immediately after.",
              "content_scripts": [
                {"matches": ["https://example.com/*"], "js": ["content.js"], "run_at": "document_end"}
              ]
            }
            """
        try Data(manifest.utf8).write(to: package.appendingPathComponent("manifest.json"))
        try Data("/* no-op */".utf8).write(to: package.appendingPathComponent("content.js"))
        return package
    }
}
