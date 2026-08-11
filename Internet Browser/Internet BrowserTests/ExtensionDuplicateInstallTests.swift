//
//  ExtensionDuplicateInstallTests.swift
//  Internet BrowserTests
//
//  Installing the same extension twice must not produce two of it.
//
//  This is not a hypothetical. The owner's real `index.json` held THREE uBO
//  Lite records — ids 0C2B61C2, A7FB389D and 7F49D5FA, all with the manifest
//  id `uBOLiteRedux@raymondhill.net`, two of them the identical version
//  2026.804.1652 — which is why the toolbar showed three identical ad-blocker
//  buttons. Every install was keyed on a fresh `UUID()`, so nothing ever
//  connected a second install of an extension to the first.
//
//  As with the options-page tests, every manager here is an isolated one:
//  these run inside `Cherry.app`, so `ExtensionManager.shared` would install
//  into the user's real extensions directory.
//

import XCTest
import WebKit
@testable import Cherry

@MainActor
final class ExtensionDuplicateInstallTests: XCTestCase {

    private func isolatedManager() -> ExtensionManager {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cherry-dupe-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return ExtensionManager.isolatedForTesting(directory: directory)
    }

    private func manifest(geckoID: String?, name: String = "Cherry Dupe Probe", version: String = "1.0") -> String {
        let identityBlock = geckoID.map { #""browser_specific_settings": { "gecko": { "id": "\#($0)" } },"# } ?? ""
        return """
        {
          "manifest_version": 3,
          "name": "\(name)",
          "version": "\(version)",
          \(identityBlock)
          "options_ui": { "page": "options/index.html", "open_in_tab": true }
        }
        """
    }

    // MARK: - The behaviour

    /// Installing the same extension twice leaves ONE of it.
    ///
    /// Dies on: `loadExtension` keying the install on `UUID().uuidString`
    /// unconditionally (the shipped code) — `installedExtensions` then holds
    /// two entries and the toolbar shows two buttons.
    func testInstallingTheSameExtensionTwiceLeavesOneOfIt() async throws {
        let manager = isolatedManager()
        let package = try ProbeExtensionPackage.write(manifest: manifest(geckoID: "dupe@cherry.test"), in: self)

        let first = try await manager.loadExtension(from: package)
        let second = try await manager.loadExtension(from: package)

        XCTAssertEqual(manager.installedExtensions.count, 1,
                       "the same extension installed twice is one extension")
        XCTAssertEqual(manager.loadedExtensions.count, 1,
                       "and it contributes one toolbar button, not two")
        XCTAssertEqual(first.id, second.id,
                       "the re-install must reuse the existing record id, which keys that extension's WebKit storage")
    }

    /// A re-install of a NEWER build replaces the old one and keeps its id —
    /// which is exactly the shape the owner's directory was in (2026.711.25
    /// beside 2026.804.1652, both installed, both enabled).
    ///
    /// Dies on: matching installs on the package filename or on the version
    /// instead of the manifest identity. The three real uBO Lite copies
    /// arrived as three different filenames.
    func testReinstallingANewerBuildReplacesTheOlderOne() async throws {
        let manager = isolatedManager()
        let old = try ProbeExtensionPackage.write(
            manifest: manifest(geckoID: "dupe@cherry.test", version: "2026.711.25"), in: self)
        let new = try ProbeExtensionPackage.write(
            manifest: manifest(geckoID: "dupe@cherry.test", version: "2026.804.1652"), in: self)

        let first = try await manager.loadExtension(from: old)
        let second = try await manager.loadExtension(from: new)

        XCTAssertEqual(manager.installedExtensions.count, 1)
        XCTAssertEqual(first.id, second.id, "the user's settings for this extension live under that id")
        XCTAssertEqual(manager.installedExtensions.first?.version, "2026.804.1652",
                       "the newer build is the one that is installed")
    }

    /// The index on disk agrees, so the duplicate does not come back on the
    /// next launch.
    ///
    /// Dies on: deduplicating in memory but appending to the persisted records.
    func testThePersistedIndexHoldsOneRecordAfterAReinstall() async throws {
        let manager = isolatedManager()
        let package = try ProbeExtensionPackage.write(manifest: manifest(geckoID: "dupe@cherry.test"), in: self)

        try await manager.loadExtension(from: package)
        try await manager.loadExtension(from: package)

        let indexData = try Data(contentsOf: manager.managedDirectory.appendingPathComponent("index.json"))
        let records = try JSONDecoder().decode([PersistedExtensionRecord].self, from: indexData)
        XCTAssertEqual(records.count, 1, "index.json is what the next launch reloads from")
        XCTAssertEqual(records.first?.identity, "gecko:dupe@cherry.test")

        // And no orphaned managed copy left beside it.
        let managedDirectories = try FileManager.default
            .contentsOfDirectory(atPath: manager.managedDirectory.path)
            .filter { $0 != "index.json" }
        XCTAssertEqual(managedDirectories.count, 1, "a replaced install must not leave its old copy behind")
    }

    /// Different extensions are still different extensions.
    ///
    /// Dies on: matching everything to everything (e.g. an identity that falls
    /// back to a constant), which would make installing a second extension
    /// silently replace the first.
    func testTwoDifferentExtensionsBothInstall() async throws {
        let manager = isolatedManager()
        let one = try ProbeExtensionPackage.write(
            manifest: manifest(geckoID: "one@cherry.test", name: "One"), in: self)
        let two = try ProbeExtensionPackage.write(
            manifest: manifest(geckoID: "two@cherry.test", name: "Two"), in: self)

        try await manager.loadExtension(from: one)
        try await manager.loadExtension(from: two)

        XCTAssertEqual(manager.installedExtensions.count, 2)
        XCTAssertEqual(Set(manager.installedExtensions.compactMap(\.record.identity)),
                       ["gecko:one@cherry.test", "gecko:two@cherry.test"])
    }

    /// A package that declares no stable identity installs as new rather than
    /// replacing something unrelated. Wrongly REPLACING an extension the user
    /// installed on purpose is worse than the duplicate this feature prevents.
    ///
    /// Dies on: treating a `nil` identity as matching any other `nil`.
    func testPackagesWithNoDeclaredIdentityDoNotReplaceEachOther() async throws {
        let manager = isolatedManager()
        // No gecko id, and a name that is a localisation placeholder — the
        // exact shape of Simple Translate's manifest, minus the gecko id.
        let anonymous = manifest(geckoID: nil, name: "__MSG_extName__")
        let one = try ProbeExtensionPackage.write(manifest: anonymous, in: self)
        let two = try ProbeExtensionPackage.write(manifest: anonymous, in: self)

        try await manager.loadExtension(from: one)
        try await manager.loadExtension(from: two)

        XCTAssertEqual(manager.installedExtensions.count, 2,
                       "with nothing to match on, an install must not replace an unrelated extension")
        XCTAssertTrue(manager.installedExtensions.allSatisfy { $0.record.identity == nil })
    }

    /// A record written before duplicate detection existed carries no
    /// identity. Launch-time reload fills it in from the manifest, so the
    /// duplicates already sitting in the user's index become replaceable
    /// rather than permanently un-matchable.
    ///
    /// Dies on: dropping the backfill in `reloadPersistedExtensions()`.
    func testAnOldRecordWithNoIdentityIsBackfilledOnReload() async throws {
        let manager = isolatedManager()
        let package = try ProbeExtensionPackage.write(manifest: manifest(geckoID: "dupe@cherry.test"), in: self)
        let installed = try await manager.loadExtension(from: package)

        // Rewrite the index the way an older Cherry wrote it: no identity.
        let indexURL = manager.managedDirectory.appendingPathComponent("index.json")
        let records = try JSONDecoder().decode([PersistedExtensionRecord].self, from: Data(contentsOf: indexURL))
        var legacy = try XCTUnwrap(records.first)
        legacy.identity = nil
        try JSONEncoder().encode([legacy]).write(to: indexURL)

        // A fresh manager over the same directory: a relaunch.
        let relaunched = ExtensionManager.isolatedForTesting(directory: manager.managedDirectory)
        await relaunched.reloadPersistedExtensions()

        XCTAssertEqual(relaunched.installedExtensions.first?.record.identity, "gecko:dupe@cherry.test",
                       "the identity must be recovered from the manifest")
        XCTAssertEqual(relaunched.installedExtensions.first?.id, installed.id)

        let reread = try JSONDecoder().decode([PersistedExtensionRecord].self, from: Data(contentsOf: indexURL))
        XCTAssertEqual(reread.first?.identity, "gecko:dupe@cherry.test",
                       "and it must be written back, not just held in memory")

        // Which is the point: installing it again now replaces rather than adds.
        try await relaunched.loadExtension(from: package)
        XCTAssertEqual(relaunched.installedExtensions.count, 1)
    }

    /// A package WebKit refuses still leaves nothing behind — including on the
    /// path where an existing install was about to be replaced.
    ///
    /// Dies on: copying into the managed directory before parsing without
    /// cleaning up, which orphans a copy nothing can enable or remove.
    func testARefusedPackageLeavesTheDirectoryUntouched() async throws {
        let manager = isolatedManager()
        let rubbish = FileManager.default.temporaryDirectory
            .appendingPathComponent("cherry-rubbish-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rubbish, withIntermediateDirectories: true)
        let file = rubbish.appendingPathComponent("not-an-extension.xpi")
        try Data("not a real package".utf8).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: rubbish) }

        do {
            try await manager.loadExtension(from: file)
            XCTFail("WebKit must refuse a package that is not an extension")
        } catch {
            // expected
        }

        XCTAssertTrue(manager.installedExtensions.isEmpty)
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: manager.managedDirectory.path)) ?? []
        XCTAssertTrue(contents.filter { $0 != "index.json" }.isEmpty,
                      "a refused package must leave no managed copy behind")
    }

    // MARK: - The identity itself

    /// Dies on: reading only `browser_specific_settings` (older packages use
    /// `applications`), or dropping the gecko id entirely.
    func testTheManifestIdIsTheIdentity() {
        XCTAssertEqual(
            ExtensionIdentity.of(manifest: [
                "name": "uBO Lite",
                "browser_specific_settings": ["gecko": ["id": "uBOLiteRedux@raymondhill.net"]],
            ]),
            "gecko:uBOLiteRedux@raymondhill.net"
        )
        XCTAssertEqual(
            ExtensionIdentity.of(manifest: [
                "name": "uBO Lite",
                "applications": ["gecko": ["id": "uBOLiteRedux@raymondhill.net"]],
            ]),
            "gecko:uBOLiteRedux@raymondhill.net"
        )
    }

    /// The three real uBO Lite packages differed in filename and (for one of
    /// them) version, and shared only the manifest id. This is the case the
    /// owner actually hit.
    ///
    /// Dies on: including the version or the filename in the identity.
    func testTheThreeRealUBOLitePackagesAreOneExtension() {
        let identities = [
            ("uBlock-Origin-Lite.xpi", "2026.711.25"),
            ("uBOLite.firefox.xpi", "2026.804.1652"),
            ("uBOLite_2026.804.1652.firefox.signed.xpi", "2026.804.1652"),
        ].map { _, version in
            ExtensionIdentity.of(manifest: [
                "name": "uBO Lite",
                "version": version,
                "browser_specific_settings": ["gecko": ["id": "uBOLiteRedux@raymondhill.net"]],
            ])
        }
        XCTAssertEqual(Set(identities.compactMap { $0 }).count, 1,
                       "all three of the owner's uBO Lite copies are the same extension")
    }

    /// Dies on: using the manifest `name` without excluding localisation
    /// placeholders — `__MSG_extName__` is what Simple Translate carries, and
    /// matching on it would fuse every localised extension into one.
    func testALocalisationPlaceholderIsNotAnIdentity() {
        XCTAssertNil(ExtensionIdentity.of(manifest: ["name": "__MSG_extName__"]))
        XCTAssertTrue(ExtensionIdentity.isLocalisationPlaceholder("__MSG_extName__"))
        XCTAssertFalse(ExtensionIdentity.isLocalisationPlaceholder("Dark Reader"))
    }

    /// Dies on: dropping the Chrome packed-key branch.
    func testAChromePackedKeyIsAnIdentity() {
        XCTAssertEqual(
            ExtensionIdentity.of(manifest: ["name": "Some Extension", "key": "MIIBIjANBg"]),
            "key:MIIBIjANBg"
        )
    }

    /// A real name is the last resort, matched case-insensitively.
    ///
    /// Dies on: dropping the name fallback, which would let any package
    /// without a declared id duplicate freely.
    func testARealNameIsTheLastResort() {
        XCTAssertEqual(ExtensionIdentity.of(manifest: ["name": "Dark Reader"]), "name:dark reader")
        XCTAssertEqual(ExtensionIdentity.of(manifest: ["name": "DARK READER"]), "name:dark reader")
    }

    /// Dies on: treating an empty or whitespace name as an identity, which
    /// would fuse every unnamed package together.
    func testAnEmptyManifestHasNoIdentity() {
        XCTAssertNil(ExtensionIdentity.of(manifest: [:]))
        XCTAssertNil(ExtensionIdentity.of(manifest: ["name": "   "]))
        XCTAssertNil(ExtensionIdentity.of(manifest: ["name": ""]))
    }

    /// The declared id wins over the name, so renaming an extension between
    /// versions does not produce a second copy of it.
    ///
    /// Dies on: checking the name before the gecko id.
    func testTheDeclaredIdBeatsTheName() {
        let before = ExtensionIdentity.of(manifest: [
            "name": "Old Name",
            "browser_specific_settings": ["gecko": ["id": "stable@cherry.test"]],
        ])
        let after = ExtensionIdentity.of(manifest: [
            "name": "New Name",
            "browser_specific_settings": ["gecko": ["id": "stable@cherry.test"]],
        ])
        XCTAssertEqual(before, after)
    }
}
