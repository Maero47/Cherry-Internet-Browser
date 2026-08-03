//
//  MCPBearerValidator.swift
//  Cherry Browser
//
//  The first thing every MCP request meets.
//
//  This runs BEFORE origin checks, before Accept/Content-Type checks, and
//  before the transport parses anything into a tool call — so an unauthorised
//  caller learns exactly one thing about Cherry: `401`. No tool names, no tab
//  titles, no history, not even which protocol versions we speak.
//
//  The SDK ships its own `BearerTokenValidator`, but it is built for OAuth 2.1
//  resource servers: it answers `400` for a malformed `Authorization` header
//  and advertises RFC 9728 metadata URLs Cherry does not have. Cherry's token
//  is a static local secret, so this is the simpler and stricter shape —
//  missing, malformed, and wrong all get the same `401`.
//

import Foundation
import MCP

/// Requires `Authorization: Bearer <token>` on every request.
nonisolated struct MCPBearerValidator: HTTPRequestValidator {

    /// Supplies the currently-valid token. A closure rather than a stored
    /// string so rotating the token in Settings takes effect on the next
    /// request without rebuilding the validator or restarting the listener.
    private let expectedToken: @Sendable () -> String?

    init(expectedToken: @escaping @Sendable () -> String?) {
        self.expectedToken = expectedToken
    }

    init(token: String) {
        self.init(expectedToken: { token })
    }

    func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse? {
        // No token configured means the server has nothing to authenticate
        // against. Fail closed: reject everything rather than serve openly.
        guard let expected = expectedToken(), !expected.isEmpty else { return Self.unauthorized }

        guard let header = request.header(HTTPHeaderName.authorization),
              let presented = Self.bearerToken(in: header)
        else {
            return Self.unauthorized
        }

        guard Self.constantTimeEquals(expected, presented) else { return Self.unauthorized }
        return nil
    }

    // MARK: - Parsing

    /// The token out of `Bearer <token>`, or `nil` for anything else.
    ///
    /// Deliberately strict: the scheme is compared case-insensitively (RFC 7235
    /// says schemes are case-insensitive and real clients vary), but anything
    /// beyond a single scheme + single token — extra words, no token, another
    /// scheme — is malformed and gets the same `401` as no header at all.
    static func bearerToken(in header: String) -> String? {
        let parts = header
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 2,
              parts[0].caseInsensitiveCompare("Bearer") == .orderedSame
        else {
            return nil
        }
        let token = String(parts[1])
        return token.isEmpty ? nil : token
    }

    // MARK: - Comparison

    /// Compare in time proportional to the EXPECTED token's length only, never
    /// to how many leading bytes happened to match.
    ///
    /// Remote timing over a loopback socket is not a serious threat, and this
    /// is not the reason the token is safe. It costs three lines, so there is
    /// no reason to hand an attacker the oracle.
    static func constantTimeEquals(_ expected: String, _ presented: String) -> Bool {
        let expectedBytes = Array(expected.utf8)
        let presentedBytes = Array(presented.utf8)

        var difference: UInt8 = expectedBytes.count == presentedBytes.count ? 0 : 1
        for index in expectedBytes.indices {
            let presentedByte = index < presentedBytes.count ? presentedBytes[index] : 0
            difference |= expectedBytes[index] ^ presentedByte
        }
        return difference == 0
    }

    // MARK: - Response

    /// One response for every failure mode, so the reason is not observable.
    static let unauthorized = HTTPResponse.error(
        statusCode: 401,
        .invalidRequest("Unauthorized"),
        extraHeaders: [HTTPHeaderName.wwwAuthenticate: "Bearer"]
    )
}
