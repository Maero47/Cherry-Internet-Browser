//
//  MCPTokenStoreTests.swift
//  Internet BrowserTests
//
//  The token file's mode is a security property, and "we passed
//  `.posixPermissions` to `createFile`" is not evidence that it was applied.
//  These tests read the mode back off the filesystem.
//

import XCTest
@testable import Cherry

final class MCPTokenStoreTests: XCTestCase {

    private var directory: URL!
    private var store: MCPTokenStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPTokenStoreTests-\(UUID().uuidString)", isDirectory: true)
        store = MCPTokenStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        store = nil
        directory = nil
        try super.tearDownWithError()
    }

    // MARK: - Permissions

    func testGeneratedTokenFileIsOwnerReadWriteOnly() throws {
        try store.rotate()
        XCTAssertEqual(store.tokenFilePermissions(), 0o600)
    }

    func testContainingDirectoryIsNotGroupOrWorldAccessible() throws {
        try store.rotate()
        let mode = try XCTUnwrap(self.mode(of: directory))
        XCTAssertEqual(mode & 0o077, 0, "directory mode \(String(mode, radix: 8)) is reachable by others")
    }

    /// `createDirectory(withIntermediateDirectories: true, attributes:)` succeeds
    /// and SILENTLY IGNORES the attributes when the directory already exists, so
    /// the `0700` guarantee only ever held on the create-new path. A pre-existing
    /// wide directory — an earlier build, a restore from backup, a stray `mkdir` —
    /// lets any local writer swap the token file for one they chose. The
    /// validator re-reads the file on every request, so that is a full auth
    /// bypass, not a disclosure.
    func testWritingIntoAPreExistingWideOpenDirectoryTightensIt() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o777)]
        )
        XCTAssertEqual(mode(of: directory), 0o777, "precondition")

        try store.rotate()

        XCTAssertEqual(
            mode(of: directory), 0o700,
            "a 0600 token file inside a world-writable directory can simply be replaced"
        )
    }

    /// The same repair the file gets on every read, for the directory.
    func testReadingFromAWidenedDirectoryTightensIt() throws {
        try store.rotate()
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o777)],
            ofItemAtPath: directory.path
        )
        XCTAssertEqual(mode(of: directory), 0o777, "precondition")

        _ = try store.existingToken()

        XCTAssertEqual(mode(of: directory), 0o700, "reading did not repair the directory mode")
    }

    // MARK: - Repair that cannot succeed must refuse, not shrug

    /// A `FileModes` whose `chmod` always fails, standing in for the case a
    /// `chown`-based test cannot portably create: an MCP directory that exists
    /// but is owned by another uid — restored from a backup that preserved a
    /// foreign owner, or pre-created by something else. `chmod` returns EPERM,
    /// the directory stays `0777`, and any local writer can unlink the token
    /// file and drop in one of their own.
    private var refusingChmod: MCPTokenStore.FileModes {
        var modes = MCPTokenStore.FileModes.live
        modes.setPermissions = { _, url in
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(EPERM),
                userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"]
            )
        }
        return modes
    }

    /// A `chmod` that reports success and changes nothing — the other way a
    /// best-effort repair lies.
    private var lyingChmod: MCPTokenStore.FileModes {
        var modes = MCPTokenStore.FileModes.live
        modes.setPermissions = { _, _ in }
        return modes
    }

    func testATokenThatCannotBeSecuredIsRefusedRatherThanServed() throws {
        try store.rotate()
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)],
            ofItemAtPath: store.tokenFileURL.path
        )

        let stuck = MCPTokenStore(directory: directory, fileModes: refusingChmod)
        XCTAssertThrowsError(try stuck.existingToken()) { error in
            guard case MCPTokenStore.Failure.insecurePermissions = error else {
                return XCTFail("expected insecurePermissions, got \(error)")
            }
        }
    }

    /// A widened DIRECTORY that cannot be repaired is the round-1 bypass in its
    /// silent form: the file is still `0600`, so a check that only looked at the
    /// file would pass it — and the file can be replaced wholesale anyway.
    func testAnUnsecurableDirectoryIsRefusedEvenWhenTheFileIsFine() throws {
        try store.rotate()
        XCTAssertEqual(store.tokenFilePermissions(), 0o600, "precondition: the file is fine")
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o777)],
            ofItemAtPath: directory.path
        )

        let stuck = MCPTokenStore(directory: directory, fileModes: refusingChmod)
        XCTAssertThrowsError(try stuck.existingToken())
    }

    /// The repair is verified, not trusted: a `chmod` that returns success and
    /// does nothing must still refuse.
    func testAChmodThatSilentlyDoesNothingIsRefused() throws {
        try store.rotate()
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o666)],
            ofItemAtPath: store.tokenFileURL.path
        )

        let lying = MCPTokenStore(directory: directory, fileModes: lyingChmod)
        XCTAssertThrowsError(try lying.existingToken())
    }

    /// The serving path. `MCPBearerValidator` treats a nil expected token as
    /// "refuse everything", so this is what makes an unsecurable token lock the
    /// server rather than leak.
    func testTokenForAuthenticationIsNilWhenTheModesCannotBeFixed() throws {
        let token = try store.rotate()
        XCTAssertEqual(store.tokenForAuthentication(), token, "precondition")

        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o777)],
            ofItemAtPath: directory.path
        )
        let stuck = MCPTokenStore(directory: directory, fileModes: refusingChmod)
        XCTAssertNil(stuck.tokenForAuthentication())
    }

    /// Writing a fresh secret into a directory that cannot be secured is the
    /// bypass, not a step towards fixing it.
    func testRotateRefusesWhenTheDirectoryCannotBeSecured() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o777)]
        )
        let stuck = MCPTokenStore(directory: directory, fileModes: refusingChmod)
        XCTAssertThrowsError(try stuck.rotate())
    }

    /// A fresh install has no file at all, which is not a security failure.
    func testAMissingTokenIsNotTreatedAsAFailure() throws {
        XCTAssertNil(try store.existingToken())
        XCTAssertNil(store.tokenForAuthentication())
    }

    private func mode(of url: URL) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue
    }

    /// A `0600` file inside a directory anyone can write is not protected — the
    /// file can simply be replaced.
    func testRotatingOverAWidenedFileTightensItAgain() throws {
        try store.rotate()
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)],
            ofItemAtPath: store.tokenFileURL.path
        )
        XCTAssertEqual(store.tokenFilePermissions(), 0o644, "precondition")

        _ = try store.existingToken()
        XCTAssertEqual(store.tokenFilePermissions(), 0o600, "reading did not repair the mode")
    }

    // MARK: - Generation

    func testTokenIsBase64URLWithNoPaddingOrURLUnsafeCharacters() throws {
        let token = try store.rotate()
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        XCTAssertTrue(
            token.unicodeScalars.allSatisfy { allowed.contains($0) },
            "token contains characters that need escaping: \(token)"
        )
    }

    /// 32 bytes base64-encoded is 43 characters once the single `=` of padding
    /// is stripped. A shorter token means the entropy shrank.
    func testTokenCarriesThirtyTwoBytesOfEntropy() throws {
        XCTAssertEqual(MCPTokenStore.tokenByteCount, 32)
        XCTAssertEqual(try store.rotate().count, 43)
    }

    func testTokensAreNotRepeated() throws {
        var seen = Set<String>()
        for _ in 0..<20 {
            seen.insert(try MCPTokenStore.generateToken())
        }
        XCTAssertEqual(seen.count, 20)
    }

    // MARK: - Lifecycle

    func testNoTokenExistsBeforeOneIsGenerated() throws {
        XCTAssertNil(try store.existingToken())
        XCTAssertNil(store.tokenFilePermissions())
    }

    func testCurrentTokenGeneratesOnceAndThenReuses() throws {
        let first = try store.currentToken()
        let second = try store.currentToken()
        XCTAssertEqual(first, second)
    }

    /// Rotating is what the "Regenerate token" button does, and its whole point
    /// is that every already-registered client stops working.
    func testRotateReplacesTheStoredToken() throws {
        let original = try store.currentToken()
        let rotated = try store.rotate()
        XCTAssertNotEqual(original, rotated)
        XCTAssertEqual(try store.existingToken(), rotated)
    }

    func testDeleteRemovesTheToken() throws {
        try store.rotate()
        try store.deleteToken()
        XCTAssertNil(try store.existingToken())
    }

    func testDeleteIsSafeWhenNoTokenExists() {
        XCTAssertNoThrow(try store.deleteToken())
    }

    /// Trailing whitespace is what a user gets if they ever hand-edit the file;
    /// it must not become part of the secret.
    func testStoredTokenIsReadBackTrimmed() throws {
        let token = try store.rotate()
        try (token + "\n").write(to: store.tokenFileURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(try store.existingToken(), token)
    }

    func testDefaultLocationLivesUnderApplicationSupport() throws {
        let path = try MCPTokenStore.defaultDirectory().path
        XCTAssertTrue(path.contains("Application Support"), path)
        XCTAssertTrue(path.hasSuffix("/MCP"), path)
    }

    /// There is no safe second location for a bearer token. The old fallback to
    /// `temporaryDirectory` put it somewhere the OS may prune, which would
    /// silently invalidate every registered client and leave the user holding a
    /// token the server no longer recognises. `shared` is optional now, and its
    /// nil case means the server refuses to run at all.
    func testThereIsNoFallbackLocationForTheToken() throws {
        let path = try MCPTokenStore.defaultDirectory().path
        XCTAssertFalse(path.hasPrefix(FileManager.default.temporaryDirectory.path), path)
        XCTAssertNotNil(MCPTokenStore.shared, "Application Support is resolvable here, so shared should exist")
    }
}
