//
//  MCPHTTPListener.swift
//  Cherry Browser
//
//  The socket the MCP SDK deliberately does not ship.
//
//  `StatelessHTTPServerTransport` is framework-agnostic: its whole server-side
//  surface is `handleRequest(MCP.HTTPRequest) async -> MCP.HTTPResponse`. It
//  does JSON-RPC framing, dispatch, protocol negotiation and validation; it
//  does not do TCP, and it does not do HTTP/1.1. That part is this file.
//
//  ## Isolation
//
//  This target compiles with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so an
//  unannotated type here would be main-actor-isolated — and every byte that
//  arrives on this socket would land on the main thread. `nonisolated` is
//  therefore load-bearing, not decoration: it makes "the network code must
//  never touch a browser type" enforced by declaration instead of by
//  convention. Everything below sees only `Data`, `NWConnection`, and the
//  SDK's `HTTPRequest`/`HTTPResponse` value types. The single collaborator is
//  a `@Sendable` closure.
//
//  ## What this parser does not do
//
//  It is ~200 lines against a loopback socket serving one known client, not a
//  general-purpose web server. It does not implement chunked transfer-encoding,
//  request pipelining, `Expect: 100-continue`, or keep-alive. Each of those is
//  refused explicitly (`501`) or made moot (`Connection: close` on every
//  response) rather than half-implemented — mis-parsing a request is a much
//  worse failure than declining it.
//

import Foundation
import Network
import MCP

// MARK: - Status

/// What the listener is doing, in terms the Settings pane and the wake handler
/// can both act on.
nonisolated enum MCPListenerStatus: Sendable, Equatable {
    case idle
    case starting
    case ready(port: UInt16)
    case failed(reason: String)
    case cancelled

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// Whether the listener needs rebuilding — the question the wake handler asks.
    var needsRestart: Bool {
        switch self {
        case .failed, .cancelled: true
        case .idle, .starting, .ready: false
        }
    }
}

// MARK: - Listener

/// An `NWListener` bound to loopback that speaks just enough HTTP/1.1 to hand
/// requests to the MCP transport.
nonisolated final class MCPHTTPListener: @unchecked Sendable {

    /// The only way this type talks to the rest of Cherry.
    typealias RequestHandler = @Sendable (HTTPRequest) async -> HTTPResponse

    /// How long a connection may sit without completing a request line + headers
    /// + body before it is dropped. Bounds slow-loris style hangs; it never
    /// applies once a request has been handed to the handler, so a slow tool
    /// call is not cut off.
    private static let requestReadTimeout: TimeInterval = 30

    private let handler: RequestHandler
    private let statusChanged: (@Sendable (MCPListenerStatus) -> Void)?

    /// Every `NWListener` and `NWConnection` callback is delivered here, so all
    /// per-connection state below is confined to this serial queue and needs no
    /// further locking.
    private let queue = DispatchQueue(label: "com.cherry.mcp.http-listener")

    private let stateLock = NSLock()
    private var listener: NWListener?
    private var status: MCPListenerStatus = .idle

    init(
        handler: @escaping RequestHandler,
        statusChanged: (@Sendable (MCPListenerStatus) -> Void)? = nil
    ) {
        self.handler = handler
        self.statusChanged = statusChanged
    }

    /// The listener's current state. Safe to read from any isolation.
    var currentStatus: MCPListenerStatus {
        stateLock.lock()
        defer { stateLock.unlock() }
        return status
    }

    // MARK: Lifecycle

    /// Bind `127.0.0.1:port` and start accepting.
    ///
    /// The bind is loopback-only and that is the primary security control on
    /// this feature: nothing on the LAN can reach the socket at all, so the
    /// bearer token is a second line rather than the only one. If the port is
    /// taken the listener reports `.failed` — it never silently picks another,
    /// because the registration command the user copied has that port in it.
    func start(port: UInt16) {
        stop()

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            update(.failed(reason: "Port \(port) is not a valid TCP port."))
            return
        }

        let parameters = NWParameters.tcp
        // THE loopback bind. Not a filter applied later — the socket is never
        // bound to any other address.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        parameters.includePeerToPeer = false

        let newListener: NWListener
        do {
            newListener = try NWListener(using: parameters)
        } catch {
            update(.failed(reason: "\(error)"))
            return
        }

        newListener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .setup:
                break
            case .ready:
                update(.ready(port: newListener.port?.rawValue ?? port))
            case .waiting(let error):
                // A loopback listener has no network path to wait for, so
                // "waiting" here means it cannot take the port (EADDRINUSE
                // arrives this way on some releases and as `.failed` on others).
                // Either way the honest answer is that it is not serving.
                update(.failed(reason: "\(error)"))
            case .failed(let error):
                update(.failed(reason: "\(error)"))
            case .cancelled:
                update(.cancelled)
            @unknown default:
                break
            }
        }

        newListener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        stateLock.lock()
        listener = newListener
        stateLock.unlock()

        update(.starting)
        newListener.start(queue: queue)
    }

    /// Tear the socket down. Idempotent.
    func stop() {
        stateLock.lock()
        let existing = listener
        listener = nil
        stateLock.unlock()

        guard let existing else { return }
        existing.stateUpdateHandler = nil
        existing.newConnectionHandler = nil
        existing.cancel()
        update(.idle)
    }

    private func update(_ newStatus: MCPListenerStatus) {
        stateLock.lock()
        status = newStatus
        stateLock.unlock()
        statusChanged?(newStatus)
    }

    // MARK: Connections

    /// Per-connection scratch state.
    ///
    /// `@unchecked Sendable` because confinement, not locking, is what makes it
    /// safe: every mutation happens in a block scheduled on `queue`, which is
    /// serial and is also the queue `NWConnection` delivers its callbacks on.
    /// The one exception is the `Task` that awaits the handler — it hops back
    /// via `queue.async` before touching this again.
    private final class Connection: @unchecked Sendable {
        let nw: NWConnection
        var buffer = Data()
        /// Set once a request has been handed off, so the read timeout stops
        /// applying to a response we are still producing.
        var handedOff = false

        init(_ nw: NWConnection) { self.nw = nw }
    }

    private func accept(_ nwConnection: NWConnection) {
        let connection = Connection(nwConnection)

        nwConnection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receive(connection)
            case .failed, .cancelled:
                nwConnection.stateUpdateHandler = nil
            default:
                break
            }
        }

        queue.asyncAfter(deadline: .now() + Self.requestReadTimeout) {
            guard !connection.handedOff else { return }
            nwConnection.cancel()
        }

        nwConnection.start(queue: queue)
    }

    private func receive(_ connection: Connection) {
        connection.nw.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                connection.buffer.append(data)
            }

            if error != nil {
                connection.nw.cancel()
                return
            }

            switch MCPHTTPWire.parseRequest(from: connection.buffer) {
            case .failure(let statusCode, let message):
                respond(MCPHTTPWire.framingError(statusCode: statusCode, message: message), on: connection)

            case .complete(let request, _):
                connection.handedOff = true
                let handler = handler
                Task {
                    let response = await handler(request)
                    self.queue.async { self.respond(response, on: connection) }
                }

            case .incomplete:
                if isComplete {
                    // Client hung up mid-request.
                    connection.nw.cancel()
                    return
                }
                if connection.buffer.count > MCPHTTPWire.maxRequestBytes {
                    respond(
                        MCPHTTPWire.framingError(statusCode: 413, message: "Payload Too Large"),
                        on: connection
                    )
                    return
                }
                receive(connection)
            }
        }
    }

    private func respond(_ response: HTTPResponse, on connection: Connection) {
        connection.handedOff = true
        let data = MCPHTTPWire.serialize(response)
        connection.nw.send(content: data, completion: .contentProcessed { _ in
            connection.nw.cancel()
        })
    }
}

// MARK: - Wire format

/// HTTP/1.1 request parsing and response serialisation, as pure functions over
/// bytes. No sockets, no isolation, no app types — so the whole framing layer
/// is unit-testable from fixtures.
nonisolated enum MCPHTTPWire {

    /// The largest request line + header block accepted.
    static let maxHeaderBytes = 64 * 1024

    /// The largest body accepted. A `Content-Length` above this is refused
    /// outright rather than buffered, so a malformed or hostile length cannot
    /// pin memory or hold a connection open forever.
    static let maxBodyBytes = 1024 * 1024

    static var maxRequestBytes: Int { maxHeaderBytes + maxBodyBytes }

    enum ParseResult: Sendable {
        /// Not all the bytes have arrived yet; read more.
        case incomplete
        case complete(request: HTTPRequest, bytesConsumed: Int)
        case failure(statusCode: Int, message: String)
    }

    // MARK: Request

    static func parseRequest(from buffer: Data) -> ParseResult {
        let bytes = [UInt8](buffer)

        guard let headerEnd = indexOfHeaderTerminator(in: bytes) else {
            if bytes.count > maxHeaderBytes {
                return .failure(statusCode: 431, message: "Request Header Fields Too Large")
            }
            return .incomplete
        }
        if headerEnd > maxHeaderBytes {
            return .failure(statusCode: 431, message: "Request Header Fields Too Large")
        }

        var lines = String(decoding: bytes[0..<headerEnd], as: UTF8.self)
            .components(separatedBy: "\r\n")
        guard !lines.isEmpty else {
            return .failure(statusCode: 400, message: "Malformed request")
        }

        let requestLine = lines.removeFirst()
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count >= 2 else {
            return .failure(statusCode: 400, message: "Malformed request line")
        }
        let method = requestParts[0].uppercased()
        let target = String(requestParts[1])
        // The transport's validators match on path, and a query string is not
        // part of it.
        let path = String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            // Obsolete line folding is not supported; a continuation line has
            // no colon and is rejected here rather than misread.
            guard let colon = line.firstIndex(of: ":") else {
                return .failure(statusCode: 400, message: "Malformed header line")
            }
            let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else {
                return .failure(statusCode: 400, message: "Malformed header line")
            }
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }

        // Refuse chunked bodies rather than mis-parse them. Claude Code does not
        // send them; a different client might, and a wrong answer would be worse
        // than a clear refusal.
        if headerValue("Transfer-Encoding", in: headers) != nil {
            return .failure(statusCode: 501, message: "Transfer-Encoding is not supported")
        }

        let bodyStart = headerEnd + 4

        guard let lengthHeader = headerValue("Content-Length", in: headers) else {
            return .complete(
                request: HTTPRequest(method: method, headers: headers, body: nil, path: path),
                bytesConsumed: bodyStart
            )
        }

        guard let contentLength = Int(lengthHeader), contentLength >= 0 else {
            return .failure(statusCode: 400, message: "Invalid Content-Length")
        }
        guard contentLength <= maxBodyBytes else {
            return .failure(statusCode: 413, message: "Payload Too Large")
        }
        guard bytes.count - bodyStart >= contentLength else {
            return .incomplete
        }

        let body = Data(bytes[bodyStart..<(bodyStart + contentLength)])
        return .complete(
            request: HTTPRequest(method: method, headers: headers, body: body, path: path),
            bytesConsumed: bodyStart + contentLength
        )
    }

    /// Case-insensitive header lookup, matching `HTTPRequest.header(_:)`.
    static func headerValue(_ name: String, in headers: [String: String]) -> String? {
        let wanted = name.lowercased()
        return headers.first { $0.key.lowercased() == wanted }?.value
    }

    private static func indexOfHeaderTerminator(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for index in 0...(bytes.count - 4) where bytes[index] == 0x0D
            && bytes[index + 1] == 0x0A
            && bytes[index + 2] == 0x0D
            && bytes[index + 3] == 0x0A
        {
            return index
        }
        return nil
    }

    // MARK: Response

    static func serialize(_ response: HTTPResponse) -> Data {
        // `StatelessHTTPServerTransport` never produces `.stream` — it has no
        // SSE path at all. If a future transport swap starts producing one,
        // saying so beats emitting a truncated body.
        if case .stream = response {
            return serialize(
                statusCode: 500,
                headers: [HTTPHeaderName.contentType: "text/plain; charset=utf-8"],
                body: Data("Streaming responses are not supported by this listener.".utf8)
            )
        }
        return serialize(
            statusCode: response.statusCode,
            headers: response.headers,
            body: response.bodyData
        )
    }

    /// A refusal raised by the framing layer itself, before the transport is
    /// ever reached — a bad request line, an oversized body, chunked encoding.
    ///
    /// Carried in the SDK's `.error` shape so the client gets the JSON body it
    /// asked for, with the HTTP status that actually describes the problem.
    static func framingError(statusCode: Int, message: String) -> HTTPResponse {
        .error(statusCode: statusCode, .invalidRequest(message))
    }

    static func serialize(statusCode: Int, headers: [String: String], body: Data?) -> Data {
        var head = "HTTP/1.1 \(statusCode) \(reasonPhrase(for: statusCode))\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            // Never let a header value smuggle a CRLF into the response.
            let sanitized = value.replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: "\n", with: "")
            head += "\(name): \(sanitized)\r\n"
        }
        head += "Content-Length: \(body?.count ?? 0)\r\n"
        // Every response closes its connection: no keep-alive means no
        // pipelining, which means the parser never has to handle a second
        // request in the same buffer.
        head += "Connection: close\r\n\r\n"

        var data = Data(head.utf8)
        if let body { data.append(body) }
        return data
    }

    static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 406: "Not Acceptable"
        case 413: "Payload Too Large"
        case 415: "Unsupported Media Type"
        case 421: "Misdirected Request"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        default: "Status \(statusCode)"
        }
    }
}
