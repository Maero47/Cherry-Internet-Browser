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
//  ## Typed text is never recorded — and the shape alone was not enough
//
//  `WebActionAuditEntry` has no field for the text a `type_text` call carried.
//  Not a redacted one, not an optional one — none. `chars_typed` and the field's
//  accessible name are what it holds, because `type_text` is exactly where a
//  password lands if anything upstream is wrong, and a log that "usually" omits
//  secrets is a log that leaks one on the day the redaction has a bug.
//
//  That was true of the SHAPE and false of the contents, which is worth keeping
//  written down. The accessible-name ladder's fourth rung is `el.innerText`; on
//  a `contenteditable` that IS the element's own contents, so typing into a
//  composer and then acting on the same element again wrote the previous message
//  into `name`. `WebActionBridge.nameIsOwnContents` is the fix, and
//  `testTypingIntoAComposerTwiceDoesNotWriteTheFirstMessageToTheLog` is what
//  would catch its removal.
//
//  **What that does not cover**, because an earlier version of this paragraph
//  claimed it did: a page that mirrors a field's contents into some OTHER
//  control's `aria-label`. That name comes from the `aria-label` rung on a
//  non-editable element, `nameIsOwnContents` is false for it, and it is written.
//  A page can reproduce the leak that way on a plain `<input>`. Withholding every
//  `aria-label`-derived name would empty the log of the identities it exists to
//  record, so the check stays where it is and this paragraph states the edge
//  rather than papering over it.
//
//  The unit test here asserts the shape a second way: the exact set of keys one
//  entry encodes. Adding a field that could carry text fails it, which the
//  substring assertion on its own could not do.
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
    ///
    /// **Capped on the way in.** It arrives from the caller on the refusal paths
    /// — a sessionless call carries whatever `document` string it likes — and an
    /// uncapped one is a megabyte of caller-chosen bytes per log line, which is a
    /// rotation lever rather than a token. The real one is 32 hex characters.
    let document: String?

    /// The longest `document` an entry will hold. `WebActionScripts` mints 128
    /// bits as 32 hex characters; the headroom is for a future format, not for a
    /// caller.
    static let documentChars = 64

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

    /// Whether a form's submit button was ACTUALLY pressed — not whether the
    /// call asked for one. Nil for anything that is not a `submit: true` typing,
    /// and nil for one that never got as far as acting.
    let submitted: Bool?

    /// The name of the control that submission pressed, when it pressed one.
    ///
    /// A real submit is the one action that commits through a control the entry
    /// otherwise never names: the field, the form's `action` and its `method`
    /// were all recorded, and the button was not. Sanitised like every other
    /// page-authored string here.
    let submitControl: String?

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

    /// Written out rather than left to the memberwise initialiser so `document`
    /// is capped at the one place every entry goes through. A cap applied at some
    /// call sites and not others is not a cap.
    init(
        action: String,
        at: Date,
        sessionID: String?,
        requester: String,
        purpose: String,
        tabID: String,
        windowID: String,
        document: String?,
        urlBefore: String,
        urlAfter: String?,
        element: Int?,
        role: String?,
        name: String?,
        tag: String?,
        type: String?,
        href: String?,
        formAction: String?,
        formMethod: String?,
        charsTyped: Int?,
        submitted: Bool?,
        submitControl: String? = nil,
        decision: String,
        result: String,
        revokedMidAction: Bool?,
        detail: String?
    ) {
        self.action = action
        self.at = at
        self.sessionID = sessionID
        self.requester = requester
        self.purpose = WebActionText.sanitisePurpose(purpose)
        self.tabID = tabID
        self.windowID = windowID
        self.document = document.map { $0.mcpTruncated(to: Self.documentChars) }
        self.urlBefore = urlBefore.mcpTruncated(to: MCPResultCaps.urlChars)
        self.urlAfter = urlAfter?.mcpTruncated(to: MCPResultCaps.urlChars)
        self.element = element
        self.role = role
        self.name = name
        self.tag = tag
        self.type = type
        self.href = href
        self.formAction = formAction
        self.formMethod = formMethod
        self.charsTyped = charsTyped
        self.submitted = submitted
        self.submitControl = submitControl
        self.decision = decision
        self.result = result
        self.revokedMidAction = revokedMidAction
        self.detail = detail
    }

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
        case submitControl = "submit_control"
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

    /// The most recent ACTIONS, newest last. Never written to disk from here —
    /// this is a mirror, not a buffer.
    ///
    /// Separate from `sessionlessTail` for the same reason the two files are
    /// separate, and it was a real gap that it was not: `write` appended to one
    /// shared 200-entry array before it branched on the destination, so a caller
    /// with no session could still evict every real action from the surface a
    /// viewer reads. The disk separation was doing its job while the mirror
    /// quietly undid it.
    private(set) var tail: [WebActionAuditEntry] = []

    /// The most recent refusals from callers holding no session.
    private(set) var sessionlessTail: [WebActionAuditEntry] = []

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

    /// Where refusals that never had a session go.
    ///
    /// A separate file, with its own rotation, and that separation is a security
    /// property rather than tidiness. Gate refusals are the only entries an
    /// UNAUTHORISED caller can cause to be written, and the log rotates at a size
    /// cap — so sharing one file let a token holder with no session loop calls
    /// until rotation dropped the record of the sessions that actually happened.
    /// The actor the log exists to record was the actor who could erase it.
    /// Filling this file now costs the other one nothing.
    var sessionlessURL: URL? {
        directory?.appendingPathComponent("refused.jsonl", isDirectory: false)
    }

    var sessionlessRotatedURL: URL? {
        directory?.appendingPathComponent("refused.1.jsonl", isDirectory: false)
    }

    // MARK: Writing

    /// Append one entry to the action log.
    ///
    /// Never throws: a log that can take a browser down is worse than a log with
    /// a gap in it.
    @discardableResult
    func record(_ entry: WebActionAuditEntry) -> Bool {
        tail.append(entry)
        if tail.count > Self.tailCount { tail.removeFirst(tail.count - Self.tailCount) }
        return write(entry, to: fileURL, rotatingTo: rotatedURL)
    }

    /// Append one entry to the sessionless-refusal log. See `sessionlessURL`.
    @discardableResult
    func recordSessionless(_ entry: WebActionAuditEntry) -> Bool {
        sessionlessTail.append(entry)
        if sessionlessTail.count > Self.tailCount {
            sessionlessTail.removeFirst(sessionlessTail.count - Self.tailCount)
        }
        return write(entry, to: sessionlessURL, rotatingTo: sessionlessRotatedURL)
    }

    private func write(_ entry: WebActionAuditEntry, to fileURL: URL?, rotatingTo rotated: URL?) -> Bool {
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
            try rotateIfNeeded(fileURL, to: rotated)
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
    private func rotateIfNeeded(_ fileURL: URL, to rotatedURL: URL?) throws {
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
