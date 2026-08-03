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

        _ = store.existingToken()

        XCTAssertEqual(mode(of: directory), 0o700, "reading did not repair the directory mode")
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

        _ = store.existingToken()
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

    func testNoTokenExistsBeforeOneIsGenerated() {
        XCTAssertNil(store.existingToken())
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
        XCTAssertEqual(store.existingToken(), rotated)
    }

    func testDeleteRemovesTheToken() throws {
        try store.rotate()
        try store.deleteToken()
        XCTAssertNil(store.existingToken())
    }

    func testDeleteIsSafeWhenNoTokenExists() {
        XCTAssertNoThrow(try store.deleteToken())
    }

    /// Trailing whitespace is what a user gets if they ever hand-edit the file;
    /// it must not become part of the secret.
    func testStoredTokenIsReadBackTrimmed() throws {
        let token = try store.rotate()
        try (token + "\n").write(to: store.tokenFileURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(store.existingToken(), token)
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
