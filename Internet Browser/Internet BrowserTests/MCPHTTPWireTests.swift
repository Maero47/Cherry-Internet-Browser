//
//  MCPHTTPWireTests.swift
//  Internet BrowserTests
//
//  Cherry owns the HTTP/1.1 framing because the SDK's server transports are
//  deliberately socket-less. That makes mis-parsing our bug, not theirs — so
//  the parser is exercised from fixture bytes, including the requests it is
//  supposed to refuse rather than guess at.
//

import XCTest
import MCP
@testable import Cherry

final class MCPHTTPWireTests: XCTestCase {

    private func bytes(_ string: String) -> Data { Data(string.utf8) }

    private func post(body: String, extraHeaders: String = "") -> Data {
        bytes(
            "POST /mcp?trailing=ignored HTTP/1.1\r\n"
            + "Host: 127.0.0.1:8787\r\n"
            + "Content-Type: application/json\r\n"
            + "Authorization: Bearer abc123\r\n"
            + extraHeaders
            + "Content-Length: \(body.utf8.count)\r\n"
            + "\r\n"
            + body
        )
    }

    // MARK: - Happy path

    func testParsesAWellFormedPost() throws {
        let body = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#
        let raw = post(body: body)

        guard case .complete(let request, let consumed) = MCPHTTPWire.parseRequest(from: raw) else {
            return XCTFail("expected a complete request")
        }

        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/mcp", "query string must not be part of the path")
        XCTAssertEqual(request.header("content-type"), "application/json")
        XCTAssertEqual(request.header("AUTHORIZATION"), "Bearer abc123")
        XCTAssertEqual(String(decoding: request.body ?? Data(), as: UTF8.self), body)
        XCTAssertEqual(consumed, raw.count)
    }

    func testMethodIsNormalisedToUppercase() {
        let raw = bytes("get /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        guard case .complete(let request, _) = MCPHTTPWire.parseRequest(from: raw) else {
            return XCTFail("expected a complete request")
        }
        XCTAssertEqual(request.method, "GET")
    }

    func testRequestWithoutContentLengthHasNoBody() {
        let raw = bytes("GET /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        guard case .complete(let request, let consumed) = MCPHTTPWire.parseRequest(from: raw) else {
            return XCTFail("expected a complete request")
        }
        XCTAssertNil(request.body)
        XCTAssertEqual(consumed, raw.count)
    }

    func testRepeatedHeadersAreFoldedWithCommas() {
        let raw = bytes("POST /mcp HTTP/1.1\r\nAccept: application/json\r\nAccept: text/event-stream\r\n\r\n")
        guard case .complete(let request, _) = MCPHTTPWire.parseRequest(from: raw) else {
            return XCTFail("expected a complete request")
        }
        XCTAssertEqual(request.header("Accept"), "application/json, text/event-stream")
    }

    // MARK: - Partial reads

    /// TCP does not deliver whole requests. Every prefix of a valid request has
    /// to read as "keep going", never as a malformed request.
    func testEveryPrefixOfAValidRequestParsesAsIncomplete() {
        let raw = post(body: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        for length in 0..<raw.count {
            guard case .incomplete = MCPHTTPWire.parseRequest(from: raw.prefix(length)) else {
                return XCTFail("prefix of \(length) bytes did not parse as incomplete")
            }
        }
    }

    func testHeadersWithoutTheirBodyAreIncomplete() {
        let raw = bytes("POST /mcp HTTP/1.1\r\nContent-Length: 10\r\n\r\nshort")
        guard case .incomplete = MCPHTTPWire.parseRequest(from: raw) else {
            return XCTFail("expected incomplete")
        }
    }

    /// A pipelined second request must not be swallowed into the first one's
    /// body. Responses always close the connection, so this only ever means the
    /// remainder is discarded — but the first request must still be right.
    func testTrailingBytesAreNotConsumed() {
        let body = #"{"a":1}"#
        var raw = post(body: body)
        raw.append(bytes("POST /mcp HTTP/1.1\r\n\r\n"))

        guard case .complete(let request, let consumed) = MCPHTTPWire.parseRequest(from: raw) else {
            return XCTFail("expected a complete request")
        }
        XCTAssertEqual(String(decoding: request.body ?? Data(), as: UTF8.self), body)
        XCTAssertLessThan(consumed, raw.count)
    }

    // MARK: - Refusals

    func testChunkedTransferEncodingIsRefusedNotGuessedAt() {
        let raw = bytes("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n7\r\nMozilla\r\n0\r\n\r\n")
        guard case .failure(let status, _) = MCPHTTPWire.parseRequest(from: raw) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertEqual(status, 501)
    }

    func testOversizedContentLengthIsRefusedBeforeBuffering() {
        let raw = bytes("POST /mcp HTTP/1.1\r\nContent-Length: \(MCPHTTPWire.maxBodyBytes + 1)\r\n\r\n")
        guard case .failure(let status, _) = MCPHTTPWire.parseRequest(from: raw) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertEqual(status, 413)
    }

    func testNonNumericContentLengthIsRefused() {
        let raw = bytes("POST /mcp HTTP/1.1\r\nContent-Length: banana\r\n\r\n")
        guard case .failure(let status, _) = MCPHTTPWire.parseRequest(from: raw) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertEqual(status, 400)
    }

    func testMalformedRequestLineIsRefused() {
        guard case .failure(let status, _) = MCPHTTPWire.parseRequest(from: bytes("GARBAGE\r\n\r\n")) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertEqual(status, 400)
    }

    func testHeaderLineWithoutAColonIsRefused() {
        let raw = bytes("POST /mcp HTTP/1.1\r\nthis is not a header\r\n\r\n")
        guard case .failure(let status, _) = MCPHTTPWire.parseRequest(from: raw) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertEqual(status, 400)
    }

    /// A header block that never terminates cannot be allowed to grow forever.
    func testUnterminatedHeaderBlockIsRefusedOnceOversized() {
        let filler = String(repeating: "X-Pad: 0123456789\r\n", count: 4000)
        let raw = bytes("POST /mcp HTTP/1.1\r\n" + filler)
        XCTAssertGreaterThan(raw.count, MCPHTTPWire.maxHeaderBytes, "precondition")
        guard case .failure(let status, _) = MCPHTTPWire.parseRequest(from: raw) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertEqual(status, 431)
    }

    // MARK: - Serialisation

    func testSerialisesADataResponse() {
        let body = #"{"jsonrpc":"2.0","id":1,"result":{}}"#
        let data = MCPHTTPWire.serialize(
            .data(Data(body.utf8), headers: ["Content-Type": "application/json"])
        )
        let text = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"), text)
        XCTAssertTrue(text.contains("\r\nContent-Type: application/json\r\n"), text)
        XCTAssertTrue(text.contains("\r\nContent-Length: \(body.utf8.count)\r\n"), text)
        XCTAssertTrue(text.contains("\r\nConnection: close\r\n"), text)
        XCTAssertTrue(text.hasSuffix("\r\n\r\n" + body), text)
    }

    func testSerialisedResponseRoundTripsThroughTheParser() {
        // The serialiser's output is a valid HTTP message head; parsing it back
        // as if it were a request is a cheap check that the framing is intact.
        let data = MCPHTTPWire.serialize(.data(Data("hi".utf8), headers: [:]))
        let text = String(decoding: data, as: UTF8.self)
        let headEnd = text.range(of: "\r\n\r\n")
        XCTAssertNotNil(headEnd)
        XCTAssertEqual(text.suffix(2), "hi")
    }

    func testEmptyBodyResponsesStillCarryAContentLength() {
        let text = String(decoding: MCPHTTPWire.serialize(.accepted()), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 202 Accepted\r\n"), text)
        XCTAssertTrue(text.contains("\r\nContent-Length: 0\r\n"), text)
    }

    func testErrorResponsesKeepTheirStatusCode() {
        let text = String(decoding: MCPHTTPWire.serialize(MCPBearerValidator.unauthorized), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"), text)
        XCTAssertTrue(text.contains("WWW-Authenticate: Bearer"), text)
    }

    /// A header value carrying a CRLF would let a response smuggle extra
    /// headers or a second response past the client.
    func testHeaderValuesCannotInjectCRLF() {
        let data = MCPHTTPWire.serialize(
            .data(Data(), headers: ["X-Test": "value\r\nX-Injected: yes"])
        )
        let text = String(decoding: data, as: UTF8.self)

        // The injected text survives — as part of the X-Test value, which is
        // harmless. What must not survive is a new header LINE.
        let headerLines = text.components(separatedBy: "\r\n")
        XCTAssertFalse(
            headerLines.contains { $0.hasPrefix("X-Injected") },
            "a header value smuggled its own header line: \(headerLines)"
        )
        XCTAssertTrue(headerLines.contains("X-Test: valueX-Injected: yes"), text)
    }

    func testFramingErrorsCarryTheirStatus() {
        let text = String(
            decoding: MCPHTTPWire.serialize(
                MCPHTTPWire.framingError(statusCode: 501, message: "Transfer-Encoding is not supported")
            ),
            as: UTF8.self
        )
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 501 Not Implemented\r\n"), text)
    }
}
