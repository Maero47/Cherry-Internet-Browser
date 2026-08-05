//
//  WebActionAuditLogTests.swift
//  Internet BrowserTests
//
//  `testATypingEntryHoldsNoFragmentOfWhatWasTyped` is the one to read first. It
//  is the property `type_text` exists inside: a log that "usually" omits secrets
//  is a log that leaks one on the day the redaction has a bug, so the entry type
//  has no field for the text at all and this asserts the consequence from the
//  outside — no substring of the typed string, of any length worth having,
//  appears anywhere in the file.
//

import XCTest
@testable import Cherry

@MainActor
final class WebActionAuditLogTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cherry-audit-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    private func entry(
        action: String = "click",
        charsTyped: Int? = nil,
        name: String = "Send",
        purpose: String = "Find the January invoice and download it"
    ) -> WebActionAuditEntry {
        WebActionAuditEntry(
            action: action,
            at: Date(timeIntervalSince1970: 1_700_000_000),
            sessionID: UUID().uuidString,
            requester: "mcp",
            purpose: purpose,
            tabID: UUID().uuidString,
            windowID: UUID().uuidString,
            document: "0123456789abcdef0123456789abcdef",
            urlBefore: "https://mail.example.com/inbox",
            urlAfter: "https://mail.example.com/inbox",
            element: 12,
            role: "button",
            name: name,
            tag: "BUTTON",
            type: "submit",
            href: nil,
            formAction: "/send",
            formMethod: "post",
            charsTyped: charsTyped,
            // Every optional set to something, so the key-set assertion below
            // covers the whole shape: Swift's synthesised encoder omits a nil
            // optional entirely, and a field that is always nil in the fixture is
            // a field the assertion cannot see.
            submitted: charsTyped == nil ? nil : false,
            submitControl: "Search",
            decision: "acted",
            result: "changed",
            revokedMidAction: nil,
            detail: nil
        )
    }

    private func contents(of log: WebActionAuditLog) throws -> String {
        let url = try XCTUnwrap(log.fileURL)
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - The property the whole file exists for

    /// The typed text is not redacted, not truncated, not hashed — it is never
    /// given to the log at all, because there is no field it could go in.
    ///
    /// **This test asserts the KEY SET, not the absence of a string it never
    /// wrote.** Its predecessor did the latter, and that made it a test that
    /// could not fail: `secret` was never handed to production code, so asserting
    /// it was absent asserted nothing, and adding a `text` field to the entry
    /// would have left it green. The exact key list below fails the moment a
    /// field appears that could carry content, whether or not anyone remembers
    /// to write a test for it.
    ///
    /// The substring property is asserted where the text actually reaches
    /// production code: `WebActionActingTests` types real strings through the
    /// real bridge, including into a `contenteditable` twice, which is the
    /// sequence that used to leak through the accessible name.
    func testAnEntryHasNoFieldThatCouldCarryContent() throws {
        let log = WebActionAuditLog(directory: directory)
        XCTAssertTrue(log.record(entry(action: "type", charsTyped: 25, name: "Password")))

        let line = try contents(of: log).trimmingCharacters(in: .newlines)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        XCTAssertEqual(
            Set(object.keys),
            [
                "action", "at", "session_id", "requester", "purpose", "tab_id", "window_id",
                "document", "url_before", "url_after", "element", "role", "name", "tag", "type",
                "form_action", "form_method", "chars_typed", "submitted", "decision", "result",
                "submit_control",
            ],
            "the audit entry grew or lost a field — if a new one can carry page or caller text, "
                + "that is the leak this file exists to prevent"
        )
        XCTAssertTrue(line.contains("\"chars_typed\":25"),
                      "the length is recorded, because it is the part that is useful")
        XCTAssertTrue(line.contains("\"name\":\"Password\""),
                      "the field's own name is recorded, because that is what identifies it")
    }

    // MARK: - Where it lives, and who can read it

    func testTheFileAndItsDirectoryAreNotReadableByOtherUsers() throws {
        let log = WebActionAuditLog(directory: directory)
        XCTAssertTrue(log.record(entry()))

        let manager = FileManager.default
        let fileMode = try XCTUnwrap(
            (manager.attributesOfItem(atPath: XCTUnwrap(log.fileURL).path)[.posixPermissions] as? NSNumber)?.intValue
        )
        let directoryMode = try XCTUnwrap(
            (manager.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue
        )
        XCTAssertEqual(fileMode, WebActionAuditLog.fileMode)
        XCTAssertEqual(directoryMode, WebActionAuditLog.directoryMode)
    }

    /// An existing file from an older build, or one restored with a foreign mode,
    /// is tightened BEFORE anything new is written into it. Tightening afterwards
    /// is theatre.
    func testALooseFileIsTightenedBeforeTheNextEntryGoesIn() throws {
        let log = WebActionAuditLog(directory: directory)
        XCTAssertTrue(log.record(entry()))
        let url = try XCTUnwrap(log.fileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: url.path
        )

        XCTAssertTrue(log.record(entry(name: "Archive")))

        let mode = try XCTUnwrap(
            (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
        )
        XCTAssertEqual(mode, WebActionAuditLog.fileMode)
    }

    // MARK: - Append-only, and it survives a restart

    func testEntriesAccumulateAndSurviveANewLogOverTheSameDirectory() throws {
        let first = WebActionAuditLog(directory: directory)
        for index in 0..<5 {
            XCTAssertTrue(first.record(entry(name: "Button \(index)")))
        }

        // A brand new instance over the same directory is what a restart looks
        // like from here: nothing is held in memory that the file does not have.
        let second = WebActionAuditLog(directory: directory)
        XCTAssertTrue(second.tail.isEmpty)
        XCTAssertTrue(second.record(entry(name: "Button 5")))

        let lines = try contents(of: second)
            .split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 6)
        XCTAssertTrue(lines[0].contains("Button 0"), "the oldest entry is still the first line")
        XCTAssertTrue(lines[5].contains("Button 5"))
        for line in lines {
            XCTAssertNotNil(
                try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                "every line is one JSON object: \(line)"
            )
        }
    }

    // MARK: - Rotation

    func testTheLogRotatesOnceItIsFullAndKeepsOneGeneration() throws {
        let log = WebActionAuditLog(directory: directory)
        let url = try XCTUnwrap(log.fileURL)
        let rotated = try XCTUnwrap(log.rotatedURL)

        // A long purpose so the cap is reached in a countable number of writes
        // rather than thousands.
        let bulky = String(repeating: "invoice ", count: 60)
        var writes = 0
        while writes < 5_000 {
            log.record(entry(purpose: bulky))
            writes += 1
            if FileManager.default.fileExists(atPath: rotated.path) { break }
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: rotated.path),
                      "the log never rotated in \(writes) writes")
        let liveSize = try XCTUnwrap(
            (FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
        )
        XCTAssertLessThan(liveSize, WebActionAuditLog.maximumBytes,
                          "the live file starts again after a rotation")

        let rotatedMode = try XCTUnwrap(
            (FileManager.default.attributesOfItem(atPath: rotated.path)[.posixPermissions] as? NSNumber)?.intValue
        )
        XCTAssertEqual(rotatedMode, WebActionAuditLog.fileMode,
                       "the rotated file is no more readable than the live one")
    }

    /// Filling the sessionless-refusal log must not cost the action log a byte.
    func testTheTwoLogsRotateIndependently() throws {
        let log = WebActionAuditLog(directory: directory)
        XCTAssertTrue(log.record(entry(name: "A real action")))
        let actions = try contents(of: log)

        let bulky = String(repeating: "refused ", count: 60)
        var writes = 0
        let rotated = try XCTUnwrap(log.sessionlessRotatedURL)
        while writes < 5_000 {
            log.recordSessionless(entry(purpose: bulky))
            writes += 1
            if FileManager.default.fileExists(atPath: rotated.path) { break }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotated.path),
                      "the refusal log never rotated in \(writes) writes")
        XCTAssertEqual(try contents(of: log), actions,
                       "rotating the refusal log touched the action log")
    }

    func testALongDocumentIsCutBeforeItReachesTheFile() throws {
        let log = WebActionAuditLog(directory: directory)
        let entry = WebActionAuditEntry(
            action: "click", at: Date(), sessionID: nil, requester: "mcp", purpose: "x",
            tabID: "t", windowID: "w",
            document: String(repeating: "A", count: 100_000),
            urlBefore: "", urlAfter: nil,
            element: 1, role: nil, name: nil, tag: nil, type: nil, href: nil,
            formAction: nil, formMethod: nil, charsTyped: nil, submitted: nil,
            decision: "refused", result: "no_session", revokedMidAction: nil, detail: nil
        )
        XCTAssertEqual(entry.document?.count, WebActionAuditEntry.documentChars + 1,
                       "capped, with one character for the visible marker")
        XCTAssertTrue(log.record(entry))
        XCTAssertLessThan(try contents(of: log).count, 2_000)
    }

    func testTheInMemoryTailIsBounded() {
        let log = WebActionAuditLog(directory: directory)
        for index in 0..<(WebActionAuditLog.tailCount + 40) {
            log.record(entry(name: "Button \(index)"))
        }
        XCTAssertEqual(log.tail.count, WebActionAuditLog.tailCount)
        XCTAssertEqual(log.tail.last?.name, "Button \(WebActionAuditLog.tailCount + 39)")
    }

    /// The disk separation was real and the mirror's was not: `write` appended to
    /// one shared tail before branching on the destination, so a sessionless
    /// caller could still evict every real action from the surface a viewer reads.
    func testASessionlessFloodCannotEvictRealActionsFromTheTail() {
        let log = WebActionAuditLog(directory: directory)
        log.record(entry(name: "A real action"))

        for index in 0..<(WebActionAuditLog.tailCount + 40) {
            log.recordSessionless(entry(name: "Refusal \(index)"))
        }

        XCTAssertEqual(log.tail.map(\.name), ["A real action"],
                       "a caller with no session pushed the real actions out of the mirror")
        XCTAssertEqual(log.sessionlessTail.count, WebActionAuditLog.tailCount,
                       "and its own tail is bounded too")
    }

    // MARK: - A log that cannot be written must not take the browser down

    func testAnUnwritableLogFailsQuietlyAndSaysSo() {
        let log = WebActionAuditLog(directory: nil)
        XCTAssertFalse(log.record(entry()))
        XCTAssertTrue(log.lastWriteFailed)
        XCTAssertEqual(log.tail.count, 1, "the in-memory tail still holds it")
    }

    // MARK: - What one entry actually contains

    /// "Did it do something I did not intend" has to be answerable from this and
    /// nothing else, so the element's full identity and the session's stated
    /// purpose are in the same line.
    func testOneEntryCarriesTheElementsIdentityAgainstTheSessionsPurpose() throws {
        let log = WebActionAuditLog(directory: directory)
        XCTAssertTrue(log.record(entry(name: "Confirm transfer")))
        let line = try contents(of: log)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(line.trimmingCharacters(in: .newlines).utf8))
                as? [String: Any]
        )
        for key in [
            "action", "at", "session_id", "requester", "purpose", "tab_id", "window_id",
            "document", "url_before", "element", "role", "name", "tag", "type",
            "form_action", "form_method", "decision", "result",
        ] {
            XCTAssertNotNil(object[key], "an audit entry must carry \(key)")
        }
        XCTAssertEqual(object["purpose"] as? String, "Find the January invoice and download it")
        XCTAssertEqual(object["name"] as? String, "Confirm transfer")
    }
}
