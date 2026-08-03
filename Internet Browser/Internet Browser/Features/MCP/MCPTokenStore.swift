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
        case insecurePermissions(URL, detail: String)

        var errorDescription: String? {
            switch self {
            case .randomBytesUnavailable(let status):
                "Could not generate a secure random token (SecRandomCopyBytes returned \(status))."
            case .couldNotWrite(let url):
                "Could not write the MCP token file at \(url.path)."
            case .applicationSupportUnavailable:
                "Could not locate the Application Support directory, so there is nowhere safe to keep the MCP token."
            case .insecurePermissions(let url, let detail):
                "\(url.path) cannot be secured, so the MCP token will not be used: \(detail)"
            }
        }
    }

    /// The two filesystem operations the security guarantee rests on, behind a
    /// seam so a failing `chmod` can be tested without `chown` and a second uid.
    struct FileModes: Sendable {
        var permissions: @Sendable (URL) -> Int?
        var setPermissions: @Sendable (Int, URL) throws -> Void

        static let live = FileModes(
            permissions: { url in
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                return (attributes?[.posixPermissions] as? NSNumber)?.intValue
            },
            setPermissions: { mode, url in
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: mode)],
                    ofItemAtPath: url.path
                )
            }
        )
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
    static let shared: MCPTokenStore? = (try? defaultDirectory()).map { MCPTokenStore(directory: $0) }

    let directory: URL
    let fileModes: FileModes

    var tokenFileURL: URL { directory.appendingPathComponent("token", isDirectory: false) }

    init(directory: URL, fileModes: FileModes = .live) {
        self.directory = directory
        self.fileModes = fileModes
    }

    // MARK: - Reading

    /// The token on disk, or `nil` if none has been generated yet.
    ///
    /// Throws `Failure.insecurePermissions` when the directory or the file
    /// cannot be brought to `0700`/`0600`. **That is not pedantry — it is the
    /// whole guarantee.** Repair is best-effort at the syscall level: a
    /// directory that exists but is owned by another uid (restored from a
    /// backup that preserved a foreign owner, or pre-created by something else)
    /// fails `chmod` with EPERM and stays `0777`, and any local writer can then
    /// unlink the token file and drop in one of their own. Swallowing that
    /// failure and serving the token anyway turns a guaranteed bypass into a
    /// silent one, which is strictly worse. So: no secure modes, no token.
    ///
    /// Repair also happens BEFORE the read, not after — tightening a `0644`
    /// file once its contents have been handed out is theatre.
    func existingToken() throws -> String? {
        // No file yet is not a failure; it is a fresh install.
        guard FileManager.default.fileExists(atPath: tokenFileURL.path) else { return nil }

        try enforceSecurePermissions()

        guard let data = try? Data(contentsOf: tokenFileURL) else { return nil }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }
        return token
    }

    /// The token to authenticate an incoming request against, or `nil` if there
    /// is not one that can be served safely.
    ///
    /// This is what the request path calls. `nil` makes `MCPBearerValidator`
    /// refuse every request, so a token that has become unsecurable while the
    /// server is running locks the server rather than handing out a secret from
    /// a directory someone else controls.
    func tokenForAuthentication() -> String? {
        (try? existingToken()) ?? nil
    }

    /// The token on disk, generating one on first use.
    @discardableResult
    func currentToken() throws -> String {
        if let existing = try existingToken() { return existing }
        return try rotate()
    }

    /// The mode the token file actually carries right now, for assertions and
    /// for the Settings pane to surface if it is ever wrong.
    func tokenFilePermissions() -> Int? {
        fileModes.permissions(tokenFileURL)
    }

    /// The mode the containing directory carries. Just as load-bearing as the
    /// file's: write access to the directory is write access to the token.
    func directoryPermissions() -> Int? {
        fileModes.permissions(directory)
    }

    /// Bring the directory and then the file to their required modes, or throw.
    ///
    /// Directory first: tightening the file while the directory it sits in is
    /// still writable by anyone protects nothing, because the file can be
    /// replaced wholesale.
    func enforceSecurePermissions() throws {
        try enforce(mode: Self.directoryMode, at: directory)
        try enforce(mode: Self.fileMode, at: tokenFileURL)
    }

    private func enforce(mode: Int, at url: URL) throws {
        guard let current = fileModes.permissions(url) else {
            throw Failure.insecurePermissions(url, detail: "its mode could not be read")
        }
        guard current != mode else { return }

        do {
            try fileModes.setPermissions(mode, url)
        } catch {
            throw Failure.insecurePermissions(
                url,
                detail: "chmod to \(String(mode, radix: 8)) failed — \(error.localizedDescription)"
            )
        }

        // Never take the syscall's word for it: verify the mode actually changed.
        guard let repaired = fileModes.permissions(url), repaired == mode else {
            throw Failure.insecurePermissions(
                url,
                detail: "still \(String(fileModes.permissions(url) ?? 0, radix: 8)) after chmod"
            )
        }
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
        // Throws rather than continuing: writing a fresh secret into a directory
        // that cannot be secured is the bypass, not a step towards fixing it.
        try enforce(mode: Self.directoryMode, at: directory)

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

        // Never assume the create call honoured the attributes — check, fix,
        // and refuse to report success if it still cannot be secured.
        try enforceSecurePermissions()
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
