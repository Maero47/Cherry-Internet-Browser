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
            submitted: charsTyped == nil ? nil : false,
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
    /// given to the log at all. `WebActionAuditEntry` has no field it could go
    /// in, and this asserts the outside consequence.
    func testATypingEntryHoldsNoFragmentOfWhatWasTyped() throws {
        let secret = "correcthorsebatterystaple"
        let log = WebActionAuditLog(directory: directory)
        XCTAssertTrue(log.record(entry(action: "type", charsTyped: secret.count, name: "Password")))

        let written = try contents(of: log)
        XCTAssertTrue(written.contains("\"chars_typed\":\(secret.count)"),
                      "the length is recorded, because it is the part that is useful")
        XCTAssertTrue(written.contains("\"name\":\"Password\""),
                      "the field's own name is recorded, because that is what identifies it")

        // Every substring of the secret four characters or longer. A single
        // "does not contain the whole string" assertion would pass a log that
        // wrote half of it.
        let characters = Array(secret)
        for length in 4...characters.count {
            for start in 0...(characters.count - length) {
                let fragment = String(characters[start..<(start + length)])
                XCTAssertFalse(
                    written.lowercased().contains(fragment.lowercased()),
                    "the audit log contains \"\(fragment)\" — a fragment of what was typed"
                )
            }
        }
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

    func testTheInMemoryTailIsBounded() {
        let log = WebActionAuditLog(directory: directory)
        for index in 0..<(WebActionAuditLog.tailCount + 40) {
            log.record(entry(name: "Button \(index)"))
        }
        XCTAssertEqual(log.tail.count, WebActionAuditLog.tailCount)
        XCTAssertEqual(log.tail.last?.name, "Button \(WebActionAuditLog.tailCount + 39)")
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
