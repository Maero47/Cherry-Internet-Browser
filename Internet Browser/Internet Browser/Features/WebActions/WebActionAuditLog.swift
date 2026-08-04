//
//  WebActionAuditLog.swift
//  Cherry Browser
//
//  Append-only record of every action the browser was asked to take, and of
//  every one it refused.
//
//  ## What this is for
//
//  The irreversible-action heuristic misses things — icon-only controls, every
//  non-English page, "Continue" on step 3 of a checkout. When it misses, nothing
//  stops the action. So the compensating controls are the ones that work
//  afterwards, and "did it do something I did not intend" has to be answerable
//  from this file and nothing else.
//
//  That is why each entry carries the element's FULL identity — role, name, tag,
//  `type`, whether it had a real `href`, whether it sat in a form — alongside the
//  session's stated `purpose`. A session opened for "find the January invoice"
//  that ends with a click on "Confirm transfer" is a one-line mismatch here, not
//  a forensic exercise. That is the property prompt injection is bounded by:
//  nothing in this design distinguishes a model that was persuaded by a page from
//  a model that was correct, so the answer is that both are visible afterwards.
//
//  ## Typed text is never recorded, and there is nowhere to put it
//
//  `WebActionAuditEntry` has no field for the text a `type_text` call carried.
//  Not a redacted one, not an optional one — none. `chars_typed` and the field's
//  accessible name are what it holds, because `type_text` is exactly where a
//  password lands if anything upstream is wrong, and a log that "usually" omits
//  secrets is a log that leaks one on the day the redaction has a bug.
//  `WebActionAuditLogTests` asserts the property from the outside too: an entry
//  built from a typing action contains no substring of the text.
//
//  ## Where it lives
//
//  `~/Library/Application Support/<bundle id>/WebActions/actions.jsonl`, mode
//  `0600` in a `0700` directory, following `MCPTokenStore`'s discipline and
//  `ExtensionManager.extensionsDirectory`'s layout. Bounded by size with one
//  rotation, so a runaway client cannot fill the user's disk and cannot push the
//  interesting entries out of existence in one go either.
//
//  Be honest about what `0600` buys, exactly as `MCPTokenStore` is: it stops
//  OTHER users on a shared Mac. It does not stop anything running as this user.
//

import Foundation

// MARK: - One entry

/// One line of the log. Flat, `Encodable`, and deliberately without a field that
/// could hold what the user typed.
nonisolated struct WebActionAuditEntry: Encodable, Sendable {

    /// `click`, `type`, `session_granted`, `session_declined`, `session_ended`.
    let action: String

    let at: Date

    /// Nil for a request that never became a session.
    let sessionID: String?
    let requester: String

    /// The session's stated purpose, verbatim as the user was shown it. The
    /// whole point of the record: an action is judged against this.
    let purpose: String

    let tabID: String
    let windowID: String

    /// The document token the caller acted against. An id is only meaningful
    /// paired with this, so a log without it could not tell two page loads apart.
    let document: String?

    let urlBefore: String
    let urlAfter: String?

    // The element's full identity. Everything here is what the page said it was
    // at the moment of the action, sanitised for display exactly as the model saw
    // it.
    let element: Int?
    let role: String?
    let name: String?
    let tag: String?
    let type: String?
    let href: String?
    let formAction: String?
    let formMethod: String?

    /// How many characters a `type_text` carried. NOT what they were.
    let charsTyped: Int?

    /// Whether Enter was pressed after typing.
    let submitted: Bool?

    /// `acted` or `refused`.
    let decision: String

    /// The refusal's reason, or the outcome (`navigated` / `changed` /
    /// `no_effect`) when it acted.
    let result: String

    /// Set when the user ended the session while the action was already inside
    /// `evaluateJavaScript`. The click had happened; revocation guarantees no
    /// FURTHER action, not the undoing of that one, and this is where that shows.
    let revokedMidAction: Bool?

    /// Free text Cherry wrote, never the page and never the requester.
    let detail: String?

    private enum CodingKeys: String, CodingKey {
        case action, at, purpose, document, element, role, name, tag, type, href
        case decision, result, detail
        case sessionID = "session_id"
        case requester
        case tabID = "tab_id"
        case windowID = "window_id"
        case urlBefore = "url_before"
        case urlAfter = "url_after"
        case formAction = "form_action"
        case formMethod = "form_method"
        case charsTyped = "chars_typed"
        case submitted
        case revokedMidAction = "revoked_mid_action"
    }
}

// MARK: - The log

@MainActor
final class WebActionAuditLog {

    /// `nil` when Application Support could not be resolved, which is the same
    /// fail-closed answer `MCPTokenStore.shared` gives. A bridge that cannot
    /// record still acts — refusing to click because a log file is unavailable
    /// would be the wrong trade — and it says so in the returned note.
    static let shared: WebActionAuditLog = WebActionAuditLog(
        directory: (try? defaultDirectory())
    )

    static let fileMode = 0o600
    static let directoryMode = 0o700

    /// Rotate at 512 KB. One entry is ~600 bytes, so that is roughly 900 actions
    /// per file and 1,800 before anything is lost — far more than one session
    /// produces, and small enough that the file stays readable in a terminal.
    static let maximumBytes = 512_000

    /// How many entries the in-memory tail keeps, for a viewer that has not been
    /// built yet (plan step 8). Bounded so a long-running browser does not grow.
    static let tailCount = 200

    let directory: URL?

    /// The most recent entries, newest last. Never written to disk from here —
    /// this is a mirror, not a buffer.
    private(set) var tail: [WebActionAuditEntry] = []

    /// True once a write has failed. Reported to the caller once, not on every
    /// action, so a broken disk does not turn every tool result into a warning.
    private(set) var lastWriteFailed = false

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    init(directory: URL?) {
        self.directory = directory
    }

    /// `~/Library/Application Support/<bundle id>/WebActions/`
    static func defaultDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Cherry", isDirectory: true)
            .appendingPathComponent("WebActions", isDirectory: true)
    }

    var fileURL: URL? { directory?.appendingPathComponent("actions.jsonl", isDirectory: false) }
    var rotatedURL: URL? { directory?.appendingPathComponent("actions.1.jsonl", isDirectory: false) }

    // MARK: Writing

    /// Append one entry. Never throws: a log that can take a browser down is
    /// worse than a log with a gap in it.
    @discardableResult
    func record(_ entry: WebActionAuditEntry) -> Bool {
        tail.append(entry)
        if tail.count > Self.tailCount { tail.removeFirst(tail.count - Self.tailCount) }

        guard let fileURL, let directory else {
            lastWriteFailed = true
            return false
        }
        guard let data = try? encoder.encode(entry) else {
            lastWriteFailed = true
            return false
        }
        var line = data
        line.append(0x0A)

        do {
            try prepareDirectory(directory)
            try rotateIfNeeded(fileURL)
            try append(line, to: fileURL)
            lastWriteFailed = false
            return true
        } catch {
            lastWriteFailed = true
            return false
        }
    }

    private func prepareDirectory(_ directory: URL) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: directory.path) {
            try manager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Self.directoryMode)]
            )
        } else {
            // Best effort, exactly as `MCPTokenStore` repairs its own: a
            // directory restored from a backup can carry a foreign mode.
            try? manager.setAttributes(
                [.posixPermissions: NSNumber(value: Self.directoryMode)],
                ofItemAtPath: directory.path
            )
        }
    }

    /// Move the current file aside once it is full, replacing whatever was there.
    ///
    /// One generation, not many. Two files bound the disk cost at ~1 MB while
    /// keeping the previous window of history, and a log that grows forever is a
    /// log nobody reads and everybody carries.
    private func rotateIfNeeded(_ fileURL: URL) throws {
        let manager = FileManager.default
        guard let size = (try? manager.attributesOfItem(atPath: fileURL.path))?[.size] as? NSNumber,
              size.intValue >= Self.maximumBytes,
              let rotatedURL
        else {
            return
        }
        if manager.fileExists(atPath: rotatedURL.path) {
            try? manager.removeItem(at: rotatedURL)
        }
        try manager.moveItem(at: fileURL, to: rotatedURL)
        try? manager.setAttributes(
            [.posixPermissions: NSNumber(value: Self.fileMode)],
            ofItemAtPath: rotatedURL.path
        )
    }

    private func append(_ line: Data, to fileURL: URL) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: fileURL.path) {
            // Created with the mode already set rather than chmod'd afterwards:
            // a file that is briefly 0644 is a file that was briefly readable.
            guard manager.createFile(
                atPath: fileURL.path,
                contents: line,
                attributes: [.posixPermissions: NSNumber(value: Self.fileMode)]
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return
        }
        // An existing file may have been created by an older build, or restored
        // with a foreign mode. Tighten BEFORE writing anything new into it.
        try? manager.setAttributes(
            [.posixPermissions: NSNumber(value: Self.fileMode)],
            ofItemAtPath: fileURL.path
        )
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }
}
