//
//  HTTPAuthPrompt.swift
//  Cherry Browser
//
//  The request behind the HTTP authentication sheet.
//
//  Before this existed, a site that answered `401 WWW-Authenticate: Basic` was
//  simply unreachable in Cherry: WebKit asked for a credential, nothing was
//  listening, the default handling declined, and the navigation failed with no
//  way anywhere in the app to type a user name.
//
//  ## Why a continuation and not a callback
//
//  `WKNavigationDelegate`'s challenge method is `async`, and the answer has to
//  come from a sheet the user may take a minute over. The continuation is
//  resumed exactly once by `resolve(_:)`, which is idempotent — a sheet can be
//  answered, escaped, and torn down in any order, and a leaked continuation is
//  a hung web process.
//

import Foundation

@MainActor
final class HTTPAuthPrompt: Identifiable, Equatable {

    enum Answer {
        case credential(user: String, password: String, remember: Bool)
        case cancel
    }

    let id = UUID()
    /// The host asking. Named on the sheet, because "some site wants your
    /// password" is not a question anyone can answer.
    let host: String
    /// The server's own realm string, when it sent one. Server-supplied text:
    /// it is shown quoted and length-capped, never used as an instruction.
    let realm: String?
    /// True on a retry, so the sheet can say the previous attempt was rejected
    /// rather than silently reappearing.
    let previouslyFailed: Bool
    /// Private tabs never offer to remember, and never read the vault.
    let isPrivate: Bool
    /// The page URL, for looking up saved credentials and for filing a new one.
    let url: URL

    private var continuation: CheckedContinuation<Answer, Never>?
    private var settled = false

    init(
        host: String,
        realm: String?,
        previouslyFailed: Bool,
        isPrivate: Bool,
        url: URL,
        continuation: CheckedContinuation<Answer, Never>
    ) {
        self.host = host
        self.realm = Self.sanitisedRealm(realm)
        self.previouslyFailed = previouslyFailed
        self.isPrivate = isPrivate
        self.url = url
        self.continuation = continuation
    }

    /// Resumes the waiting navigation. Safe to call more than once; only the
    /// first answer counts, and every later one is dropped.
    func resolve(_ answer: Answer) {
        guard !settled else { return }
        settled = true
        continuation?.resume(returning: answer)
        continuation = nil
    }

    nonisolated static func == (lhs: HTTPAuthPrompt, rhs: HTTPAuthPrompt) -> Bool {
        lhs === rhs
    }

    /// The realm comes off the wire, so it is trimmed to one line and capped
    /// before it is ever drawn. A server that sent a paragraph, or newlines
    /// meant to push Cherry's own words off the sheet, gets a short quoted
    /// string instead.
    private static func sanitisedRealm(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let oneLine = raw
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oneLine.isEmpty else { return nil }
        return oneLine.count > 80 ? String(oneLine.prefix(80)) + "…" : oneLine
    }
}
