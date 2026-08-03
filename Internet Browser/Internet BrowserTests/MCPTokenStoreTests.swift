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
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(mode & 0o077, 0, "directory mode \(String(mode, radix: 8)) is reachable by others")
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

    func testDefaultLocationLivesUnderApplicationSupport() {
        let path = MCPTokenStore.defaultDirectory.path
        XCTAssertTrue(path.contains("Application Support"), path)
        XCTAssertTrue(path.hasSuffix("/MCP"), path)
    }
}
