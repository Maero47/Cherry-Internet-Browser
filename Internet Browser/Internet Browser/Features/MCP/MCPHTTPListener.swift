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
        /// Parsed once, then never again for this connection.
        var head: MCPHTTPWire.RequestHead?
        /// Where the CRLFCRLF search resumes, so the header scan is not
        /// restarted from byte zero on every segment.
        var scanOffset = 0
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

            // Parse the head at most once per connection. After that, "has the
            // whole request arrived?" is one integer comparison per segment
            // rather than a fresh copy-and-reparse of everything received so far.
            if connection.head == nil {
                switch MCPHTTPWire.parseHead(from: connection.buffer, resumingAt: connection.scanOffset) {
                case .failure(let statusCode, let message):
                    respond(MCPHTTPWire.framingError(statusCode: statusCode, message: message), on: connection)
                    return
                case .incomplete(let nextScanOffset):
                    connection.scanOffset = nextScanOffset
                case .complete(let head):
                    connection.head = head
                }
            }

            if let head = connection.head, connection.buffer.count >= head.totalLength {
                let request = MCPHTTPWire.request(from: connection.buffer, head: head)
                connection.handedOff = true
                let handler = handler
                Task {
                    let response = await handler(request)
                    self.queue.async { self.respond(response, on: connection) }
                }
                return
            }

            if isComplete {
                // Client hung up mid-request.
                connection.nw.cancel()
                return
            }
            // Before a head is parsed the header cap applies; after it, the
            // request's own declared length is the ceiling and `parseHead`
            // already refused anything over the body cap.
            let ceiling = connection.head?.totalLength ?? MCPHTTPWire.maxHeaderBytes
            if connection.buffer.count > ceiling {
                respond(
                    MCPHTTPWire.framingError(statusCode: 413, message: "Payload Too Large"),
                    on: connection
                )
                return
            }
            receive(connection)
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

    // MARK: Request head

    /// Everything a request declares before its body.
    ///
    /// Parsed exactly once per connection. Once it is in hand, deciding whether
    /// the rest of the request has arrived is a single integer comparison — see
    /// `totalLength`. That is the whole point of splitting it out: re-running a
    /// full parse on every TCP segment made a slow 1 MB upload cost
    /// O(segments × buffer) in memcpy and header re-parsing, on the single
    /// serial queue that also services the accept handler and every other
    /// connection. No token was needed to trigger it.
    struct RequestHead: Sendable, Equatable {
        let method: String
        let path: String
        /// Header names are lowercased on insertion — see `parseHead`.
        let headers: [String: String]
        /// Bytes from the start of the request through the terminating CRLFCRLF.
        let headerBlockLength: Int
        /// `false` when no `Content-Length` was sent at all, which is different
        /// from `Content-Length: 0`.
        let declaresBody: Bool
        let contentLength: Int

        /// The exact size of the whole request on the wire.
        var totalLength: Int { headerBlockLength + contentLength }
    }

    enum HeadParseResult: Sendable {
        /// The header block has not fully arrived. `nextScanOffset` is where the
        /// terminator search may resume, so the scan is not restarted from zero
        /// on every segment.
        case incomplete(nextScanOffset: Int)
        case complete(RequestHead)
        case failure(statusCode: Int, message: String)
    }

    private static let headerTerminator = Data([0x0D, 0x0A, 0x0D, 0x0A])

    static func parseHead(from buffer: Data, resumingAt scanOffset: Int = 0) -> HeadParseResult {
        let start = buffer.startIndex
        let searchFrom = start + max(0, min(scanOffset, buffer.count))

        guard let terminator = buffer.range(of: headerTerminator, in: searchFrom..<buffer.endIndex) else {
            if buffer.count > maxHeaderBytes {
                return .failure(statusCode: 431, message: "Request Header Fields Too Large")
            }
            // Resume three bytes back, so a CRLFCRLF split across two segments
            // is still found.
            return .incomplete(nextScanOffset: max(0, buffer.count - 3))
        }

        let headerEnd = buffer.distance(from: start, to: terminator.lowerBound)
        if headerEnd > maxHeaderBytes {
            return .failure(statusCode: 431, message: "Request Header Fields Too Large")
        }

        var lines = String(decoding: buffer[start..<terminator.lowerBound], as: UTF8.self)
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
            // LOWERCASED ON INSERTION, and this is load-bearing. Folding
            // duplicates with ", " is what makes `Content-Length: 10` plus a
            // second `Content-Length: 0` fail `Int("10, 0")` and get rejected.
            // Keying on the raw name defeated that for `content-length: 0`,
            // which landed in a second dictionary entry — and every lookup,
            // ours and the SDK's, resolves with `headers.first { … }`, whose
            // order is undefined. The same request framed differently between
            // runs, with an attacker choosing which `Authorization`, `Origin`
            // or `Host` the validators saw.
            let name = String(line[line.startIndex..<colon])
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
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
        if headers["transfer-encoding"] != nil {
            return .failure(statusCode: 501, message: "Transfer-Encoding is not supported")
        }

        let headerBlockLength = headerEnd + headerTerminator.count

        guard let lengthHeader = headers["content-length"] else {
            return .complete(RequestHead(
                method: method,
                path: path,
                headers: headers,
                headerBlockLength: headerBlockLength,
                declaresBody: false,
                contentLength: 0
            ))
        }

        guard let contentLength = Int(lengthHeader), contentLength >= 0 else {
            return .failure(statusCode: 400, message: "Invalid Content-Length")
        }
        guard contentLength <= maxBodyBytes else {
            return .failure(statusCode: 413, message: "Payload Too Large")
        }

        return .complete(RequestHead(
            method: method,
            path: path,
            headers: headers,
            headerBlockLength: headerBlockLength,
            declaresBody: true,
            contentLength: contentLength
        ))
    }

    /// Slice the body out of a buffer known to hold `head.totalLength` bytes.
    static func request(from buffer: Data, head: RequestHead) -> HTTPRequest {
        let bodyStart = buffer.startIndex + head.headerBlockLength
        let body: Data? = head.declaresBody
            ? Data(buffer[bodyStart..<(bodyStart + head.contentLength)])
            : nil
        return HTTPRequest(method: head.method, headers: head.headers, body: body, path: head.path)
    }

    // MARK: Whole-request convenience

    /// One-shot parse over a complete buffer. The listener does not use this —
    /// it keeps the head across segments — but it is the shape fixtures and
    /// tests want.
    static func parseRequest(from buffer: Data) -> ParseResult {
        switch parseHead(from: buffer) {
        case .incomplete:
            return .incomplete
        case .failure(let statusCode, let message):
            return .failure(statusCode: statusCode, message: message)
        case .complete(let head):
            guard buffer.count >= head.totalLength else { return .incomplete }
            return .complete(request: request(from: buffer, head: head), bytesConsumed: head.totalLength)
        }
    }

    /// Case-insensitive header lookup, matching `HTTPRequest.header(_:)`.
    static func headerValue(_ name: String, in headers: [String: String]) -> String? {
        let wanted = name.lowercased()
        return headers.first { $0.key.lowercased() == wanted }?.value
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
