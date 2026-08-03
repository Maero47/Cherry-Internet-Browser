//
//  MCPTokenStore.swift
//  Cherry Browser
//
//  The bearer token that gates Cherry's MCP server, on disk.
//
//  The token is 32 bytes from the system CSPRNG, base64url-encoded so it can be
//  pasted into a `claude mcp add --header` argument without quoting, and stored
//  in a `0600` file the user can `cat`.
//
//  Be honest about what `0600` buys. It stops OTHER users on a shared Mac. It
//  does NOT stop anything running as this user — such a process could read
//  Cherry's Core Data store directly anyway. The token's real job is narrower
//  and still worth doing: it stops any UNAUTHENTICATED localhost client from
//  reaching the tools, most importantly a web page in any browser doing
//  `fetch('http://127.0.0.1:8787/mcp')`. That is the classic local-server
//  footgun, and this closes it.
//
//  The directory convention follows `ExtensionManager.extensionsDirectory`:
//  Application Support ▸ bundle identifier ▸ subfolder.
//

import Foundation
import Security

/// Generate, read, and rotate the MCP bearer token.
///
/// `nonisolated` and value-typed on purpose: the validator that consumes the
/// token runs on the SDK's executor, off the main actor, and the store itself
/// keeps no in-memory state — the file is the single source of truth, so a
/// token rotated in Settings takes effect on the very next request.
nonisolated struct MCPTokenStore: Sendable {

    enum Failure: LocalizedError {
        case randomBytesUnavailable(OSStatus)
        case couldNotWrite(URL)
        case applicationSupportUnavailable

        var errorDescription: String? {
            switch self {
            case .randomBytesUnavailable(let status):
                "Could not generate a secure random token (SecRandomCopyBytes returned \(status))."
            case .couldNotWrite(let url):
                "Could not write the MCP token file at \(url.path)."
            case .applicationSupportUnavailable:
                "Could not locate the Application Support directory, so there is nowhere safe to keep the MCP token."
            }
        }
    }

    /// The number of random bytes behind each token. 32 bytes is 256 bits of
    /// entropy — far beyond brute force over a loopback socket.
    static let tokenByteCount = 32

    /// The mode the token file and its directory must carry.
    static let fileMode = 0o600
    static let directoryMode = 0o700

    /// `~/Library/Application Support/<bundle id>/MCP/`
    ///
    /// Throws rather than falling back. There is no safe second location for a
    /// bearer token: the obvious fallback, `temporaryDirectory`, is somewhere
    /// the OS may prune out from under us, which would silently invalidate
    /// every registered client and leave the user with a server that refuses
    /// the token they copied.
    static func defaultDirectory() throws -> URL {
        let fileManager = FileManager.default
        guard let base = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            throw Failure.applicationSupportUnavailable
        }
        let appDirectoryName = Bundle.main.bundleIdentifier ?? "Cherry"
        return base
            .appendingPathComponent(appDirectoryName, isDirectory: true)
            .appendingPathComponent("MCP", isDirectory: true)
    }

    /// `nil` when Application Support could not be resolved. Callers treat that
    /// as "the server cannot run", which is the correct fail-closed answer.
    static let shared: MCPTokenStore? = (try? defaultDirectory()).map(MCPTokenStore.init(directory:))

    let directory: URL

    var tokenFileURL: URL { directory.appendingPathComponent("token", isDirectory: false) }

    init(directory: URL) {
        self.directory = directory
    }

    // MARK: - Reading

    /// The token on disk, or `nil` if none has been generated yet.
    ///
    /// Repairs the modes BEFORE reading, not after: tightening a `0644` file
    /// once its contents have already been handed out is theatre. Both the file
    /// and the directory are repaired, because a `0600` file inside a
    /// world-writable directory can simply be replaced — and since this runs on
    /// every request, a replaced file would be believed immediately.
    func existingToken() -> String? {
        tightenPermissionsIfNeeded()
        let url = tokenFileURL
        guard let data = try? Data(contentsOf: url) else { return nil }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }
        return token
    }

    /// The token on disk, generating one on first use.
    @discardableResult
    func currentToken() throws -> String {
        if let existing = existingToken() { return existing }
        return try rotate()
    }

    /// The mode the token file actually carries right now, for assertions and
    /// for the Settings pane to surface if it is ever wrong.
    func tokenFilePermissions() -> Int? {
        Self.permissions(ofItemAt: tokenFileURL)
    }

    /// The mode the containing directory carries. Just as load-bearing as the
    /// file's: write access to the directory is write access to the token.
    func directoryPermissions() -> Int? {
        Self.permissions(ofItemAt: directory)
    }

    // MARK: - Writing

    /// Mint a fresh token, replacing any existing one.
    ///
    /// Every previously-registered client stops working at this point and must
    /// be re-registered with the new token — that is the whole point of the
    /// button in Settings that calls this.
    @discardableResult
    func rotate() throws -> String {
        let token = try Self.generateToken()
        try write(token)
        return token
    }

    /// Remove the token entirely. The server cannot start without one, so this
    /// is a hard off switch.
    func deleteToken() throws {
        let url = tokenFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func write(_ token: String) throws {
        let fileManager = FileManager.default
        // `createDirectory(withIntermediateDirectories: true, attributes:)`
        // succeeds and SILENTLY IGNORES the attributes when the directory is
        // already there — so passing 0700 here only ever protected the
        // create-new case. The explicit repair below is what actually holds the
        // guarantee for a directory that predates this build.
        try? fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Self.directoryMode)]
        )
        tightenDirectoryPermissionsIfNeeded()

        let url = tokenFileURL
        // Remove first: `createFile` on an existing path keeps the old inode's
        // mode on some filesystems, and the mode is the security property here.
        try? fileManager.removeItem(at: url)

        let created = fileManager.createFile(
            atPath: url.path,
            contents: Data(token.utf8),
            attributes: [.posixPermissions: NSNumber(value: Self.fileMode)]
        )
        guard created else { throw Failure.couldNotWrite(url) }

        // Never assume the create call honoured the attributes — check and fix.
        tightenPermissionsIfNeeded()
    }

    /// Bring both the directory and the token file back to their required modes.
    ///
    /// Directory first: tightening the file while the directory it sits in is
    /// still writable by anyone protects nothing, because the file can be
    /// replaced wholesale.
    private func tightenPermissionsIfNeeded() {
        tightenDirectoryPermissionsIfNeeded()
        Self.setPermissionsIfNeeded(Self.fileMode, ofItemAt: tokenFileURL)
    }

    private func tightenDirectoryPermissionsIfNeeded() {
        Self.setPermissionsIfNeeded(Self.directoryMode, ofItemAt: directory)
    }

    private static func permissions(ofItemAt url: URL) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue
    }

    private static func setPermissionsIfNeeded(_ mode: Int, ofItemAt url: URL) {
        guard let current = permissions(ofItemAt: url), current != mode else { return }
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: mode)],
            ofItemAtPath: url.path
        )
    }

    // MARK: - Generation

    /// 32 CSPRNG bytes, base64url without padding.
    ///
    /// base64url rather than plain base64 so the token survives being pasted
    /// into a shell command, a URL, or a JSON config without escaping: `+`, `/`
    /// and `=` all have meaning in at least one of those places.
    static func generateToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: tokenByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw Failure.randomBytesUnavailable(status) }
        return Data(bytes).base64URLEncodedString()
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
