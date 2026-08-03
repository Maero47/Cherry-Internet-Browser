//
//  MCPBearerValidatorTests.swift
//  Internet BrowserTests
//
//  Nothing — no tab list, no history, no page text — may leave the process
//  before this validator says yes. It runs first in the pipeline, so these
//  tests are the closest thing to a proof of that property that does not
//  require a socket.
//

import XCTest
import MCP
@testable import Cherry

final class MCPBearerValidatorTests: XCTestCase {

    private let token = "s3cret-token_value"

    private func request(authorization: String?) -> HTTPRequest {
        var headers = [
            "Content-Type": "application/json",
            "Accept": "application/json",
        ]
        if let authorization { headers["Authorization"] = authorization }
        return HTTPRequest(
            method: "POST",
            headers: headers,
            body: Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8),
            path: "/mcp"
        )
    }

    private let context = HTTPValidationContext(httpMethod: "POST")

    private func validate(_ authorization: String?) -> HTTPResponse? {
        MCPBearerValidator(token: token).validate(request(authorization: authorization), context: context)
    }

    // MARK: - Accept

    func testCorrectTokenPasses() {
        XCTAssertNil(validate("Bearer \(token)"))
    }

    /// RFC 7235 makes the auth scheme case-insensitive and clients vary.
    func testSchemeIsCaseInsensitive() {
        XCTAssertNil(validate("bearer \(token)"))
        XCTAssertNil(validate("BEARER \(token)"))
    }

    func testSurroundingWhitespaceIsTolerated() {
        XCTAssertNil(validate("  Bearer \(token)  "))
    }

    // MARK: - Reject

    func testWrongTokenIsRejected() {
        assertUnauthorized(validate("Bearer wrong-token"))
    }

    func testAbsentHeaderIsRejected() {
        assertUnauthorized(validate(nil))
    }

    func testEmptyHeaderIsRejected() {
        assertUnauthorized(validate(""))
    }

    func testMalformedHeadersAreRejected() {
        for header in [
            "Bearer",                      // no token
            "Bearer ",                     // empty token
            token,                         // no scheme
            "Basic \(token)",              // wrong scheme
            "Bearer \(token) extra",       // trailing junk
            "Token \(token)",
        ] {
            assertUnauthorized(validate(header), "accepted malformed header: \(header)")
        }
    }

    /// A prefix of the real token must not pass. This is the case a
    /// short-circuiting comparison would get wrong.
    func testTokenPrefixIsRejected() {
        assertUnauthorized(validate("Bearer \(String(token.dropLast()))"))
        assertUnauthorized(validate("Bearer \(token)x"))
    }

    /// Fail closed. A server with no token configured must serve nobody, not
    /// everybody.
    func testNoConfiguredTokenRejectsEverything() {
        let validator = MCPBearerValidator(expectedToken: { nil })
        assertUnauthorized(validator.validate(request(authorization: "Bearer \(token)"), context: context))

        let empty = MCPBearerValidator(expectedToken: { "" })
        assertUnauthorized(empty.validate(request(authorization: "Bearer "), context: context))
    }

    // MARK: - Rotation

    /// The token is read per request, so regenerating it in Settings locks out
    /// already-registered clients without restarting the listener.
    func testRotatingTheTokenTakesEffectImmediately() {
        nonisolated(unsafe) var current = "first"
        let validator = MCPBearerValidator(expectedToken: { current })

        XCTAssertNil(validator.validate(request(authorization: "Bearer first"), context: context))
        current = "second"
        assertUnauthorized(validator.validate(request(authorization: "Bearer first"), context: context))
        XCTAssertNil(validator.validate(request(authorization: "Bearer second"), context: context))
    }

    // MARK: - Shape of the refusal

    /// Every failure mode gets the identical response, so an attacker cannot
    /// tell "wrong token" from "malformed header" from "no header".
    func testAllFailuresAreIndistinguishable() {
        // Compared as parsed JSON, not as bytes: the SDK builds the error body
        // with `JSONSerialization` and no `.sortedKeys`, so key order varies
        // between otherwise identical responses.
        let refusals = [validate(nil), validate(""), validate("Bearer wrong"), validate("Basic x")]
            .map { response -> String in
                guard let response,
                      let data = response.bodyData,
                      let json = try? JSONSerialization.jsonObject(with: data),
                      let canonical = try? JSONSerialization.data(withJSONObject: json, options: .sortedKeys)
                else {
                    return "<passed>"
                }
                let headers = response.headers.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
                return "\(response.statusCode)|\(headers)|\(String(decoding: canonical, as: UTF8.self))"
            }
        XCTAssertEqual(Set(refusals).count, 1, "refusals differ: \(refusals)")
    }

    func testRefusalLeaksNoToolInformation() {
        let body = String(decoding: validate("Bearer wrong")?.bodyData ?? Data(), as: UTF8.self)
        for tool in MCPToolRegistry.tools {
            XCTAssertFalse(body.contains(tool.name), "401 body mentions \(tool.name)")
        }
        XCTAssertFalse(body.contains(token), "401 body echoes the expected token")
    }

    // MARK: - Constant-time comparison

    func testConstantTimeComparisonMatchesEquality() {
        XCTAssertTrue(MCPBearerValidator.constantTimeEquals("abc", "abc"))
        XCTAssertFalse(MCPBearerValidator.constantTimeEquals("abc", "abd"))
        XCTAssertFalse(MCPBearerValidator.constantTimeEquals("abc", "ab"))
        XCTAssertFalse(MCPBearerValidator.constantTimeEquals("abc", "abcd"))
        XCTAssertFalse(MCPBearerValidator.constantTimeEquals("abc", ""))
        XCTAssertTrue(MCPBearerValidator.constantTimeEquals("", ""))
    }

    func testBearerTokenParsing() {
        XCTAssertEqual(MCPBearerValidator.bearerToken(in: "Bearer abc"), "abc")
        XCTAssertNil(MCPBearerValidator.bearerToken(in: "Bearer"))
        XCTAssertNil(MCPBearerValidator.bearerToken(in: "abc"))
    }

    // MARK: - Helper

    private func assertUnauthorized(
        _ response: HTTPResponse?,
        _ message: String = "expected 401",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let response else {
            return XCTFail(message, file: file, line: line)
        }
        XCTAssertEqual(response.statusCode, 401, message, file: file, line: line)
    }
}
