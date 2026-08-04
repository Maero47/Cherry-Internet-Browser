//
//  MCPSettingsPresentationTests.swift
//  Internet BrowserTests
//
//  The Connections pane has eight states and only one of them is reachable by
//  clicking a switch on a healthy Mac. The other seven need a missing
//  Application Support folder, a port someone else holds, or a token file whose
//  mode cannot be repaired — none of which a view test can arrange.
//
//  So the mapping from "what the server is doing" to "what the pane says" is a
//  value, and this is where every one of those states is checked. The view
//  itself is not tested: it draws these values and nothing else.
//

import XCTest
@testable import Cherry

final class MCPSettingsPresentationTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Classifying the three cannot-run failures

    func testApplicationSupportFailureIsRecognised() {
        let reason = MCPTokenStore.Failure.applicationSupportUnavailable.localizedDescription
        XCTAssertEqual(MCPCannotRunReason.classify(reason), .noTokenLocation)
    }

    func testInsecurePermissionsFailureIsRecognised() {
        let reason = MCPTokenStore.Failure
            .insecurePermissions(
                URL(fileURLWithPath: "/Users/someone/Library/Application Support/com.cherry.browser/MCP"),
                detail: "chmod to 700 failed"
            )
            .localizedDescription
        XCTAssertEqual(MCPCannotRunReason.classify(reason), .insecureTokenPermissions)
    }

    /// `MCPTokenStore` raises `insecurePermissions` for three situations and
    /// only two are about permissions. The third — a path whose mode could not
    /// even be read, i.e. a folder that was never created — must NOT be
    /// reported as "another account could replace the token", because that is
    /// an accusation with no evidence and its remedy tells the user to chmod a
    /// path that may not exist.
    func testAMissingTokenFolderIsNotReportedAsATamperedOne() {
        let missing = MCPTokenStore.Failure
            .insecurePermissions(
                URL(fileURLWithPath: "/Volumes/ReadOnly/MCP"),
                detail: "its mode could not be read"
            )
            .localizedDescription
        XCTAssertEqual(MCPCannotRunReason.classify(missing), .tokenLocationUnusable)

        let state = presentation(status: .failed(reason: missing))
        XCTAssertFalse(
            state.detail.contains("another account"),
            "a folder that could not be created was described as a local compromise: \(state.detail)"
        )
        XCTAssertFalse(
            state.remedy?.contains("chmod") == true,
            "the remedy tells the user to chmod a path that may not exist: \(state.remedy ?? "")"
        )
    }

    /// Both genuinely-permission details carry the word chmod; that is the
    /// positive evidence the security verdict requires.
    func testOnlyAnActualChmodFailureEarnsTheSecurityMessage() {
        let securityDetails = ["chmod to 700 failed — Operation not permitted", "still 777 after chmod"]
        for detail in securityDetails {
            let reason = MCPTokenStore.Failure
                .insecurePermissions(URL(fileURLWithPath: "/tmp/mcp"), detail: detail)
                .localizedDescription
            XCTAssertEqual(MCPCannotRunReason.classify(reason), .insecureTokenPermissions, detail)
        }

        // An unfamiliar detail defaults to the milder reading. The server
        // refuses to run either way, so the only thing at stake is whether the
        // explanation is true, and a wrong accusation is the worse error.
        let unknown = MCPTokenStore.Failure
            .insecurePermissions(URL(fileURLWithPath: "/tmp/mcp"), detail: "something new")
            .localizedDescription
        XCTAssertEqual(MCPCannotRunReason.classify(unknown), .tokenLocationUnusable)
    }

    /// `NWError` has stringified EADDRINUSE both ways across releases, and it
    /// arrives as `.waiting` on some and `.failed` on others.
    func testAddressInUseIsRecognisedInEveryShapeItArrivesIn() {
        let shapes = [
            "POSIXErrorCode(rawValue: 48): Address already in use",
            "POSIXErrorCode(rawValue: 48)",
            "Address already in use",
            "EADDRINUSE",
        ]
        for shape in shapes {
            XCTAssertEqual(MCPCannotRunReason.classify(shape), .portUnavailable, shape)
        }
    }

    func testAnUnfamiliarFailureIsNotForcedIntoOneOfTheThree() {
        XCTAssertEqual(
            MCPCannotRunReason.classify("POSIXErrorCode(rawValue: 13): Permission denied"),
            .other
        )
        XCTAssertEqual(MCPCannotRunReason.classify("No MCP token could be generated."), .other)
    }

    /// The markers are derived from `MCPTokenStore.Failure` rather than retyped,
    /// so a copy edit there cannot silently demote a known failure to `.other`.
    /// If this fails, the derivation broke, not the wording.
    ///
    /// Asserts the property the classifier actually depends on — that neither
    /// error's text contains the other's marker — rather than re-stating a
    /// verdict the equality assertions above already pin down.
    func testTokenStoreMarkersAreMutuallyExclusive() {
        let appSupport = MCPTokenStore.Failure.applicationSupportUnavailable.localizedDescription
        let insecure = MCPTokenStore.Failure
            .insecurePermissions(URL(fileURLWithPath: "/tmp/x"), detail: "chmod failed")
            .localizedDescription

        XCTAssertFalse(appSupport.isEmpty)
        XCTAssertFalse(insecure.isEmpty)
        XCTAssertFalse(
            insecure.contains(appSupport),
            "the permissions text swallows the Application Support sentence, so one shadows the other"
        )
        // Neither is a prefix or suffix of the other, so substring matching on
        // either cannot be satisfied by the wrong error.
        XCTAssertFalse(appSupport.contains(insecure))
    }

    // MARK: - Each cannot-run state reads differently, and actionably

    func testEachCannotRunStateHasItsOwnMessageRemedyAndRawText() {
        let cases: [(String, MCPCannotRunReason)] = [
            (MCPTokenStore.Failure.applicationSupportUnavailable.localizedDescription, .noTokenLocation),
            ("POSIXErrorCode(rawValue: 48): Address already in use", .portUnavailable),
            (
                MCPTokenStore.Failure
                    .insecurePermissions(URL(fileURLWithPath: "/tmp/mcp"), detail: "still 777 after chmod")
                    .localizedDescription,
                .insecureTokenPermissions
            ),
            (
                MCPTokenStore.Failure
                    .insecurePermissions(URL(fileURLWithPath: "/tmp/mcp"), detail: "its mode could not be read")
                    .localizedDescription,
                .tokenLocationUnusable
            ),
            ("something nobody anticipated", .other),
        ]

        var titles = Set<String>()
        for (reason, expected) in cases {
            XCTAssertEqual(MCPCannotRunReason.classify(reason), expected)

            let state = presentation(status: .failed(reason: reason))
            XCTAssertEqual(state.tone, .failure, reason)
            XCTAssertFalse(state.title.isEmpty)
            XCTAssertFalse(state.detail.isEmpty)
            XCTAssertNotNil(state.remedy, "a cannot-run state with no remedy is a dead end: \(reason)")
            XCTAssertEqual(state.technical, reason, "the raw text carries the path and the POSIX code")
            titles.insert(state.title)
        }

        XCTAssertEqual(titles.count, cases.count, "two cannot-run states read identically")
    }

    /// The port failure must name the port, because the remedy is "quit
    /// whatever holds it" and the user cannot do that without the number.
    func testPortFailureNamesThePortAndPromisesNotToMove() {
        let state = presentation(
            status: .failed(reason: "POSIXErrorCode(rawValue: 48): Address already in use"),
            port: 9911
        )
        XCTAssertTrue(state.title.contains("9911"), state.title)
        XCTAssertTrue(state.detail.contains("9911"), state.detail)
        XCTAssertTrue(
            state.detail.lowercased().contains("will not quietly move"),
            "the pane must promise the port is not silently rebound: \(state.detail)"
        )
    }

    func testPermissionsFailureExplainsWhyItRefusesRatherThanJustFailing() {
        let reason = MCPTokenStore.Failure
            .insecurePermissions(URL(fileURLWithPath: "/tmp/mcp/token"), detail: "still 777 after chmod")
            .localizedDescription
        let state = presentation(status: .failed(reason: reason))
        XCTAssertTrue(state.detail.contains("0700"), state.detail)
        XCTAssertTrue(state.detail.contains("0600"), state.detail)
        XCTAssertEqual(state.technical, reason, "the path is only in the raw text")
        XCTAssertTrue(state.remedy?.contains("chmod") == true, state.remedy ?? "")
    }

    // MARK: - Off, starting, running, running-with-a-client

    /// The switch wins. A pane that says "running" for a feature the user has
    /// switched off is a lie even if the socket has not finished closing.
    func testOffBeatsWhateverTheListenerLastSaid() {
        for status in [MCPListenerStatus.ready(port: 8787), .starting, .failed(reason: "x"), .idle] {
            let state = presentation(enabled: false, status: status)
            XCTAssertEqual(state.tone, .off, "\(status)")
            XCTAssertEqual(state.title, "Off")
            XCTAssertNil(state.remedy)
            XCTAssertNil(state.technical)
        }
    }

    func testAFreshInstallSaysOffWithoutHavingStartedAnything() {
        let suiteName = "MCPSettingsPresentationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(SettingsManager.mcpServerEnabled(from: defaults))
        let state = presentation(
            enabled: SettingsManager.mcpServerEnabled(from: defaults),
            status: .idle,
            port: SettingsManager.mcpServerPort(from: defaults)
        )
        XCTAssertEqual(state.tone, .off)
    }

    func testIdleAndStartingBothReadAsStarting() {
        for status in [MCPListenerStatus.idle, .starting] {
            let state = presentation(status: status, port: 8787)
            XCTAssertEqual(state.tone, .starting, "\(status)")
            XCTAssertTrue(state.detail.contains("127.0.0.1:8787"), state.detail)
        }
    }

    func testRunningWithNothingConnectedSaysSoRatherThanImplyingAClient() {
        let state = presentation(status: .ready(port: 8787))
        XCTAssertEqual(state.tone, .ready)
        XCTAssertTrue(state.title.contains("127.0.0.1:8787"), state.title)
        XCTAssertTrue(state.detail.contains("No client has connected"), state.detail)
    }

    func testAnInFlightRequestReadsAsInUse() {
        let state = presentation(status: .ready(port: 8787), activeRequestCount: 1)
        XCTAssertEqual(state.tone, .inUse)
        XCTAssertEqual(state.title, "In use right now")
    }

    /// The server is stateless, so a request that has already finished is the
    /// only evidence a client exists. Inside the window it still counts.
    func testARecentlyFinishedRequestStillCountsAsConnected() {
        let justNow = now.addingTimeInterval(-(MCPServerPresentation.activityWindow - 1))
        let state = presentation(status: .ready(port: 8787), lastActivity: justNow)
        XCTAssertEqual(state.tone, .inUse)
    }

    func testOnceTheWindowClosesItGoesBackToWaiting() {
        let earlier = now.addingTimeInterval(-(MCPServerPresentation.activityWindow + 1))
        let state = presentation(status: .ready(port: 8787), lastActivity: earlier)
        XCTAssertEqual(state.tone, .ready)
        XCTAssertTrue(state.detail.contains("The last request was"), state.detail)
    }

    func testCancelledWhileEnabledIsReportedAsNotRunning() {
        let state = presentation(status: .cancelled)
        XCTAssertEqual(state.tone, .failure)
        XCTAssertNotNil(state.remedy)
    }

    /// Every state the pane can be in must be sayable. A blank line under the
    /// status glyph is the shape "we only drew the happy path" takes.
    func testNoStateRendersEmpty() {
        let statuses: [MCPListenerStatus] = [
            .idle, .starting, .ready(port: 8787), .cancelled,
            .failed(reason: MCPTokenStore.Failure.applicationSupportUnavailable.localizedDescription),
            .failed(reason: "POSIXErrorCode(rawValue: 48): Address already in use"),
            .failed(reason: MCPTokenStore.Failure
                .insecurePermissions(URL(fileURLWithPath: "/tmp/x"), detail: "still 777 after chmod")
                .localizedDescription),
            .failed(reason: MCPTokenStore.Failure
                .insecurePermissions(URL(fileURLWithPath: "/tmp/x"), detail: "its mode could not be read")
                .localizedDescription),
            .failed(reason: "unknown"),
        ]
        for enabled in [true, false] {
            for status in statuses {
                let state = presentation(enabled: enabled, status: status)
                XCTAssertFalse(state.title.isEmpty, "\(enabled) \(status)")
                XCTAssertFalse(state.detail.isEmpty, "\(enabled) \(status)")
            }
        }
    }

    // MARK: - Copy rules

    /// A rule for this whole pane, easiest to enforce here.
    func testNoUserVisibleStringContainsAnEmDash() {
        let statuses: [MCPListenerStatus] = [
            .idle, .starting, .ready(port: 8787), .cancelled,
            .failed(reason: "POSIXErrorCode(rawValue: 48): Address already in use"),
            .failed(reason: MCPTokenStore.Failure.applicationSupportUnavailable.localizedDescription),
            .failed(reason: MCPTokenStore.Failure
                .insecurePermissions(URL(fileURLWithPath: "/tmp/x"), detail: "still 777 after chmod")
                .localizedDescription),
            .failed(reason: MCPTokenStore.Failure
                .insecurePermissions(URL(fileURLWithPath: "/tmp/x"), detail: "its mode could not be read")
                .localizedDescription),
        ]
        for enabled in [true, false] {
            for status in statuses {
                let state = presentation(enabled: enabled, status: status)
                for line in [state.title, state.detail, state.remedy ?? ""] {
                    XCTAssertFalse(line.contains("—"), line)
                }
            }
        }

        for entry in [MCPPortEntry.empty, .notANumber, .tooLow(80), .tooHigh(70000)] {
            XCTAssertFalse(entry.message?.contains("—") == true, entry.message ?? "")
        }
    }

    // MARK: - Elapsed phrasing

    func testElapsedPhrasing() {
        func phrase(_ seconds: TimeInterval) -> String {
            MCPServerPresentation.elapsedPhrase(from: now.addingTimeInterval(-seconds), to: now)
        }
        XCTAssertEqual(phrase(0), "a moment ago")
        XCTAssertEqual(phrase(1), "a moment ago")
        XCTAssertEqual(phrase(4), "4 seconds ago")
        XCTAssertEqual(phrase(59), "59 seconds ago")
        XCTAssertEqual(phrase(60), "a minute ago")
        XCTAssertEqual(phrase(3599), "59 minutes ago")
        XCTAssertEqual(phrase(3600), "an hour ago")
        XCTAssertEqual(phrase(7200), "2 hours ago")
        XCTAssertEqual(phrase(86400 * 3), "more than a day ago")
    }

    /// A clock that has gone backwards must not produce "-3 seconds ago".
    func testAFutureTimestampDoesNotProduceNegativeText() {
        let phrase = MCPServerPresentation.elapsedPhrase(from: now.addingTimeInterval(30), to: now)
        XCTAssertEqual(phrase, "a moment ago")
    }

    // MARK: - Port field

    func testPortEntryAcceptsWhatTheSettingsManagerWouldStore() {
        for port in [1024, 8787, 9911, 65535] {
            XCTAssertEqual(MCPPortEntry.parse(String(port)), .valid(port))
            XCTAssertTrue(SettingsManager.isValidMCPServerPort(port))
        }
        XCTAssertEqual(MCPPortEntry.parse("  8787 "), .valid(8787))
    }

    /// `SettingsManager.mcpServerPort`'s setter silently reverts an
    /// out-of-range value. Silent is right for the stored property and wrong
    /// for a text field, so the field must have its own reason to show.
    func testPortEntryExplainsEveryValueTheSetterWouldSilentlyRevert() {
        let rejected: [(String, MCPPortEntry)] = [
            ("", .empty),
            ("   ", .empty),
            ("http", .notANumber),
            ("87 87", .notANumber),
            ("8787x", .notANumber),
            ("08787", .notANumber),
            ("0", .tooLow(0)),
            ("80", .tooLow(80)),
            ("1023", .tooLow(1023)),
            ("65536", .tooHigh(65536)),
            ("99999", .tooHigh(99999)),
        ]
        for (text, expected) in rejected {
            let entry = MCPPortEntry.parse(text)
            XCTAssertEqual(entry, expected, text)
            XCTAssertNil(entry.port, text)
            XCTAssertNotNil(entry.message, "\"\(text)\" is refused with no explanation")

            // The out-of-range verdicts have to agree with the setter, or the
            // field would explain a rejection that never happened (or, worse,
            // stay silent about one that did).
            switch entry {
            case .tooLow(let port), .tooHigh(let port):
                XCTAssertFalse(SettingsManager.isValidMCPServerPort(port), text)
            case .valid, .empty, .notANumber:
                break
            }
        }
    }

    /// Port 0 is the one that has to be caught: `NWEndpoint.Port(rawValue: 0)`
    /// is `.any`, so a listener would bind an OS-assigned port while the copied
    /// command went on naming one nothing is listening on.
    func testPortZeroIsRefusedWithAReason() {
        let entry = MCPPortEntry.parse("0")
        XCTAssertNil(entry.port)
        XCTAssertNotNil(entry.message)
    }

    // MARK: - The registration command

    @MainActor
    func testRegistrationCommandCarriesThePortAndTheHTTPTransportFlags() {
        let port = SettingsManager.shared.mcpServerPort
        let command = MCPServerManager.shared.registrationCommand(includingToken: false)

        XCTAssertTrue(command.hasPrefix("claude mcp add --transport http --scope user cherry "), command)
        XCTAssertTrue(command.contains("http://127.0.0.1:\(port)/mcp"), command)
        XCTAssertTrue(command.contains("--header \"Authorization: Bearer "), command)
    }

    /// The whole reason the `$(cat …)` form exists: the pane can be copied from
    /// without the secret ever being on screen.
    ///
    /// Asserts against a token that is guaranteed to exist. The first version
    /// wrapped its only real assertion in `if let token = …`, so on any machine
    /// where the token was absent or unreadable — exactly the state the
    /// fail-closed design produces — it passed without checking anything.
    @MainActor
    func testTheDefaultCommandFormDoesNotContainTheToken() throws {
        try withTokenPresent { store, token in
            let command = MCPServerManager.shared.registrationCommand(includingToken: false)
            XCTAssertTrue(command.contains("$(cat "), command)
            XCTAssertTrue(command.contains(store.tokenFileURL.path), command)
            XCTAssertFalse(command.contains(token), "the token leaked into the safe command form")
        }
    }

    /// The reveal has to actually reveal. Asserting only that `$(cat ` is absent
    /// was satisfied by the `"<token>"` placeholder the builder falls back to
    /// when it cannot read a token, so the test passed hardest in precisely the
    /// case it was meant to catch.
    @MainActor
    func testTheRevealedCommandFormSubstitutesTheRealToken() throws {
        try withTokenPresent { _, token in
            let command = MCPServerManager.shared.registrationCommand(includingToken: true)
            XCTAssertFalse(command.contains("$(cat "), command)
            XCTAssertTrue(command.contains(token), "the revealed form does not carry the real token")
            XCTAssertFalse(command.contains("<token>"), command)
        }
    }

    /// Runs `body` with a real token on disk, restoring whatever was there
    /// before. The command builder reads `MCPTokenStore.shared`, which is not
    /// injectable, so the only way to assert on a real token is to guarantee
    /// one — and then put the machine back.
    @MainActor
    private func withTokenPresent(
        _ body: (MCPTokenStore, String) throws -> Void
    ) throws {
        let store = try XCTUnwrap(
            MCPTokenStore.shared,
            "no Application Support means no token file to read the command from"
        )
        let preexisting = try? store.existingToken()
        defer {
            if preexisting == nil { try? store.deleteToken() }
        }

        let token = try store.currentToken()
        XCTAssertFalse(token.isEmpty)
        try body(store, token)
    }

    // MARK: - The activity hold shared by the pane and the indicator

    /// The bug this covers: the indicator gated only on `lastActivity != nil`,
    /// so every navigation-bar remount — a second window, entering or leaving
    /// split view, coming out of video fullscreen — lit "a client is reading
    /// Cherry right now" for ten seconds over a timestamp of any age, while the
    /// pane beside it correctly said the last request was hours ago.
    func testAStaleTimestampEarnsNoHold() {
        for age in [MCPServerPresentation.activityWindow, 60, 3600, 86_400] {
            XCTAssertNil(
                MCPServerPresentation.remainingActivityHold(
                    since: now.addingTimeInterval(-age),
                    now: now
                ),
                "a request \(age)s old still held the indicator open"
            )
        }
    }

    func testNoActivityAtAllEarnsNoHold() {
        XCTAssertNil(MCPServerPresentation.remainingActivityHold(since: nil, now: now))
    }

    /// A remount mid-window must not restart the clock: the hold ends at the
    /// right absolute moment, so the remaining interval shrinks with age.
    func testTheHoldIsWhatIsLeftOfTheWindowNotTheWholeWindow() {
        let remaining = try? XCTUnwrap(
            MCPServerPresentation.remainingActivityHold(since: now.addingTimeInterval(-4), now: now)
        )
        XCTAssertEqual(remaining ?? 0, MCPServerPresentation.activityWindow - 4, accuracy: 0.001)

        let fresh = MCPServerPresentation.remainingActivityHold(since: now, now: now)
        XCTAssertEqual(fresh ?? 0, MCPServerPresentation.activityWindow, accuracy: 0.001)
    }

    /// A clock that stepped backwards must not buy a longer hold than the window.
    func testAFutureTimestampIsClampedToTheWindow() {
        let remaining = MCPServerPresentation.remainingActivityHold(
            since: now.addingTimeInterval(3600),
            now: now
        )
        XCTAssertEqual(remaining ?? 0, MCPServerPresentation.activityWindow, accuracy: 0.001)
    }

    /// The indicator and the pane must never disagree about whether a client is
    /// connected, so they read the same answer from the same helper.
    func testTheHoldAndThePaneAgreeAtEveryAge() {
        for age in stride(from: 0.0, through: 20.0, by: 0.5) {
            let lastActivity = now.addingTimeInterval(-age)
            let held = MCPServerPresentation.remainingActivityHold(since: lastActivity, now: now) != nil
            let state = presentation(status: .ready(port: 8787), lastActivity: lastActivity)
            XCTAssertEqual(held, state.tone == .inUse, "disagreed at age \(age)")
        }
    }

    // MARK: - VoiceOver

    /// The status block combined its children and then replaced the label with
    /// title + detail, dropping `remedy` and `technical` in every cannot-run
    /// state — the only actionable content, and the only place the path the
    /// user has to repair appears.
    @MainActor
    func testTheSpokenStatusKeepsTheRemedyAndThePath() {
        let reason = MCPTokenStore.Failure
            .insecurePermissions(
                URL(fileURLWithPath: "/Users/someone/Library/Application Support/x/MCP/token"),
                detail: "still 777 after chmod"
            )
            .localizedDescription
        let state = presentation(status: .failed(reason: reason))
        let spoken = MCPSettingsView.spokenStatus(state)

        XCTAssertTrue(spoken.contains(state.title), spoken)
        XCTAssertTrue(spoken.contains(state.detail), spoken)
        XCTAssertTrue(spoken.contains(try! XCTUnwrap(state.remedy)), spoken)
        XCTAssertTrue(spoken.contains("/MCP/token"), "the path a user must chmod is not spoken")
    }

    @MainActor
    func testEveryCannotRunStateSpeaksItsRemedy() {
        let reasons = [
            MCPTokenStore.Failure.applicationSupportUnavailable.localizedDescription,
            "POSIXErrorCode(rawValue: 48): Address already in use",
            MCPTokenStore.Failure
                .insecurePermissions(URL(fileURLWithPath: "/tmp/x"), detail: "still 777 after chmod")
                .localizedDescription,
            MCPTokenStore.Failure
                .insecurePermissions(URL(fileURLWithPath: "/tmp/x"), detail: "its mode could not be read")
                .localizedDescription,
            "unknown",
        ]
        for reason in reasons {
            let state = presentation(status: .failed(reason: reason))
            let spoken = MCPSettingsView.spokenStatus(state)
            XCTAssertTrue(spoken.contains(try! XCTUnwrap(state.remedy)), reason)
            XCTAssertTrue(spoken.contains(reason), "the raw text is not spoken for: \(reason)")
        }
    }

    // MARK: - Helper

    private func presentation(
        enabled: Bool = true,
        status: MCPListenerStatus,
        port: Int = 8787,
        activeRequestCount: Int = 0,
        lastActivity: Date? = nil
    ) -> MCPServerPresentation {
        MCPServerPresentation.make(
            enabled: enabled,
            status: status,
            port: port,
            activeRequestCount: activeRequestCount,
            lastActivity: lastActivity,
            now: now
        )
    }
}
