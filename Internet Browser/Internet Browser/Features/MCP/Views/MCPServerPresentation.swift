//
//  MCPServerPresentation.swift
//  Cherry Browser
//
//  What the Connections pane says, derived from what the server is actually
//  doing.
//
//  Pure on purpose: no views, no singletons, no clock of its own. The pane has
//  eight states (off, starting, running-idle, running-with-a-client, and four
//  ways of not running) and only one of them is reachable by clicking a switch
//  on a healthy Mac. Keeping the mapping here means the other seven are unit
//  tests rather than a filesystem you have to sabotage by hand.
//

import Foundation

// MARK: - Why it cannot run

/// The distinguishable reasons the MCP server refuses to serve.
///
/// The manager publishes `MCPListenerStatus.failed(reason:)` carrying free text
/// from two unrelated sources: `MCPTokenStore.Failure.localizedDescription` and
/// `NWError`'s description. Neither is a type this pane can switch over, so the
/// classification happens here, once.
///
/// The token-store markers are *derived from the error values themselves*
/// rather than retyped, so a copy edit over in `MCPTokenStore` cannot silently
/// demote a known failure to `.other` and leave the user reading a POSIX dump.
nonisolated enum MCPCannotRunReason: Equatable {

    /// Application Support could not be resolved, so there is nowhere to keep
    /// the token and no acceptable fallback location for it.
    case noTokenLocation

    /// Something else already holds the port. Cherry does not rebind elsewhere:
    /// the port is written into the command the user copied.
    case portUnavailable

    /// The token's directory or file could not be forced to `0700`/`0600`, so
    /// any local account could replace the token. The server fails closed.
    case insecureTokenPermissions

    /// Anything the three above do not cover. The raw text is shown verbatim.
    case other

    static func classify(_ reason: String) -> MCPCannotRunReason {
        if reason.contains(Self.noTokenLocationMarker) { return .noTokenLocation }
        if reason.contains(Self.insecurePermissionsMarker) { return .insecureTokenPermissions }
        if Self.addressInUseMarkers.contains(where: { reason.contains($0) }) { return .portUnavailable }
        return .other
    }

    /// The whole sentence, which has no interpolation in it.
    private static let noTokenLocationMarker =
        MCPTokenStore.Failure.applicationSupportUnavailable.localizedDescription

    /// The invariant middle of "`<path>` cannot be secured, so the MCP token
    /// will not be used: `<detail>`", recovered by minting the error with
    /// known sentinels and deleting them again.
    private static let insecurePermissionsMarker: String = {
        let sentinelPath = "/cherry-marker-path"
        let sentinelDetail = "cherry-marker-detail"
        return MCPTokenStore.Failure
            .insecurePermissions(URL(fileURLWithPath: sentinelPath), detail: sentinelDetail)
            .localizedDescription
            .replacingOccurrences(of: sentinelPath, with: "")
            .replacingOccurrences(of: sentinelDetail, with: "")
            .trimmingCharacters(in: .whitespaces)
    }()

    /// `NWError` reaches us as `"\(error)"`. EADDRINUSE has been seen in both
    /// shapes across releases, and it arrives as `.waiting` on some and
    /// `.failed` on others, so match the code as well as the message.
    private static let addressInUseMarkers = [
        "Address already in use",
        "rawValue: 48",
        "EADDRINUSE",
    ]
}

// MARK: - Port entry

/// The result of typing something into the port field.
///
/// `SettingsManager.mcpServerPort`'s setter silently reverts an out-of-range
/// value, which is the right thing for the stored property and a terrible thing
/// for a text field: the number springs back with no explanation. This says why.
nonisolated enum MCPPortEntry: Equatable {
    case valid(Int)
    case empty
    case notANumber
    case tooLow(Int)
    case tooHigh(Int)

    static let lowest = 1024
    static let highest = 65535

    static func parse(_ text: String) -> MCPPortEntry {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .empty }
        guard let port = Int(trimmed), String(port) == trimmed else { return .notANumber }
        if port < lowest { return .tooLow(port) }
        if port > highest { return .tooHigh(port) }
        return .valid(port)
    }

    var port: Int? {
        if case .valid(let port) = self { return port }
        return nil
    }

    /// `nil` when there is nothing to complain about.
    var message: String? {
        switch self {
        case .valid:
            nil
        case .empty:
            "Enter a port number between \(Self.lowest) and \(Self.highest)."
        case .notANumber:
            "That is not a port number. Enter a whole number between \(Self.lowest) and \(Self.highest)."
        case .tooLow(let port):
            "Port \(port) is reserved for programs running as root, so Cherry cannot bind it. "
                + "Enter a number between \(Self.lowest) and \(Self.highest)."
        case .tooHigh(let port):
            "Port \(port) is above the highest TCP port. Enter a number between \(Self.lowest) and \(Self.highest)."
        }
    }
}

// MARK: - Presentation

/// One rendered status block: what the server is doing, in the user's terms.
nonisolated struct MCPServerPresentation: Equatable {

    /// Drives the colour of the status glyph, and nothing else. Status *text*
    /// stays at label contrast in every tone except `.failure`, which carries a
    /// measured red (see `MCPStatusPalette`).
    enum Tone: Equatable {
        case off
        case starting
        case ready
        case inUse
        case failure
    }

    let tone: Tone

    /// One line, scannable. Never ends in a full stop.
    let title: String

    /// What that means, in whole sentences.
    let detail: String

    /// The step that would fix it, or `nil` when there is nothing to fix.
    let remedy: String?

    /// The raw text from the listener or the token store. Carries the path in
    /// the permissions case, which is the only way the user can act on it, and
    /// the POSIX code in the port case. Shown monospaced, never paraphrased.
    let technical: String?

    /// How recently a request has to have finished before the pane and the
    /// toolbar indicator will call a client connected.
    ///
    /// The server is stateless by design: a request is served and forgotten, in
    /// milliseconds, with no socket held open to point at. So "connected" has
    /// to mean "used just now" or it would never be visible at all. Ten seconds
    /// is long enough to notice a tool call and short enough that the indicator
    /// is never lying about the present.
    static let activityWindow: TimeInterval = 10

    // MARK: The mapping

    static func make(
        enabled: Bool,
        status: MCPListenerStatus,
        port: Int,
        activeRequestCount: Int,
        lastActivity: Date?,
        now: Date
    ) -> MCPServerPresentation {
        // The switch wins over whatever the listener last said. A pane that
        // reports "running" for a feature the user has switched off is a lie
        // even if the socket has not finished closing.
        guard enabled else {
            return MCPServerPresentation(
                tone: .off,
                title: "Off",
                detail: "Nothing outside Cherry can reach your tabs, your page text, your history, or your bookmarks.",
                remedy: nil,
                technical: nil
            )
        }

        switch status {
        case .idle, .starting:
            return MCPServerPresentation(
                tone: .starting,
                title: "Starting",
                detail: "Binding 127.0.0.1:\(port).",
                remedy: nil,
                technical: nil
            )

        case .ready(let boundPort):
            return running(
                port: Int(boundPort),
                activeRequestCount: activeRequestCount,
                lastActivity: lastActivity,
                now: now
            )

        case .failed(let reason):
            return cannotRun(reason: reason, port: port)

        case .cancelled:
            return MCPServerPresentation(
                tone: .failure,
                title: "Not running",
                detail: "The server was closed and has not come back, so no client can reach Cherry.",
                remedy: "Switch this off and on again.",
                technical: nil
            )
        }
    }

    private static func running(
        port: Int,
        activeRequestCount: Int,
        lastActivity: Date?,
        now: Date
    ) -> MCPServerPresentation {
        if activeRequestCount > 0 {
            return MCPServerPresentation(
                tone: .inUse,
                title: "In use right now",
                detail: "A client is reading Cherry through 127.0.0.1:\(port) as you look at this.",
                remedy: nil,
                technical: nil
            )
        }

        if let lastActivity, now.timeIntervalSince(lastActivity) < activityWindow {
            return MCPServerPresentation(
                tone: .inUse,
                title: "In use right now",
                detail: "A client read Cherry \(elapsedPhrase(from: lastActivity, to: now)), through 127.0.0.1:\(port).",
                remedy: nil,
                technical: nil
            )
        }

        let sinceLast = lastActivity.map {
            "The last request was \(elapsedPhrase(from: $0, to: now))."
        } ?? "No client has connected since Cherry started."

        return MCPServerPresentation(
            tone: .ready,
            title: "Running on 127.0.0.1:\(port)",
            detail: "Waiting for a client. \(sinceLast)",
            remedy: nil,
            technical: nil
        )
    }

    private static func cannotRun(reason: String, port: Int) -> MCPServerPresentation {
        switch MCPCannotRunReason.classify(reason) {
        case .noTokenLocation:
            return MCPServerPresentation(
                tone: .failure,
                title: "Cannot run: nowhere to keep the token",
                detail: "Cherry could not open its Application Support folder, so it has nowhere safe to store "
                    + "the token clients authenticate with. It will not fall back to a temporary folder, because "
                    + "one the system may clear would leave every client you had registered failing to connect.",
                remedy: "Check that your Library folder still holds Application Support and that Cherry can write "
                    + "to it, then switch this off and on again.",
                technical: reason
            )

        case .portUnavailable:
            return MCPServerPresentation(
                tone: .failure,
                title: "Cannot run: port \(port) is already taken",
                detail: "Something else on this Mac is listening on 127.0.0.1:\(port). Cherry will not quietly move "
                    + "to a free port, because the port is written into the command you copied and into every "
                    + "client you registered with it.",
                remedy: "Quit whatever is holding port \(port), or set a different port above and register your "
                    + "clients again with the new command.",
                technical: reason
            )

        case .insecureTokenPermissions:
            return MCPServerPresentation(
                tone: .failure,
                title: "Cannot run: the token file cannot be secured",
                detail: "Cherry could not force the token's folder to 0700 and the token file to 0600, so another "
                    + "account on this Mac could replace the token with one of its own and reach your tabs and "
                    + "history. Rather than serve a token it cannot vouch for, Cherry refuses to start.",
                remedy: "In Terminal, run chmod 700 on the folder and chmod 600 on the token file named below. If "
                    + "chmod fails, they are owned by another account: check with ls -le.",
                technical: reason
            )

        case .other:
            return MCPServerPresentation(
                tone: .failure,
                title: "Cannot run",
                detail: "The MCP server could not start, so no client can reach Cherry.",
                remedy: "Switch this off and on again. If it keeps failing, the text below is what the system "
                    + "reported.",
                technical: reason
            )
        }
    }

    // MARK: Elapsed time

    /// "4 seconds ago", "2 minutes ago". Written out rather than handed to a
    /// `RelativeDateTimeFormatter` so the phrasing is fixed, testable, and does
    /// not drift with locale data underneath the tests.
    static func elapsedPhrase(from earlier: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(earlier).rounded()))
        switch seconds {
        case 0...1:
            return "a moment ago"
        case 2..<60:
            return "\(seconds) seconds ago"
        case 60..<3600:
            let minutes = seconds / 60
            return minutes == 1 ? "a minute ago" : "\(minutes) minutes ago"
        case 3600..<86400:
            let hours = seconds / 3600
            return hours == 1 ? "an hour ago" : "\(hours) hours ago"
        default:
            return "more than a day ago"
        }
    }
}
