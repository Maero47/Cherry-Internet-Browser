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

    /// Answers "does this request carry a valid token?" for refusals raised by
    /// the framing layer itself, which never reach `RequestHandler`.
    typealias Authorizer = @Sendable ([String: String]) -> Bool

    /// How long a connection may sit without completing a request line + headers
    /// + body before it is dropped. Bounds slow-loris style hangs; it is
    /// cancelled the moment a response is written, so a slow tool call is never
    /// cut off and a finished connection is not pinned waiting for it to fire.
    private static let requestReadTimeout: TimeInterval = 30

    /// How many connections may be open at once.
    ///
    /// `maxBodyBytes` bounds one request; without this, nothing bounded how many
    /// were in flight, so an unauthenticated client — a web page included —
    /// could take a 401 per connection and still pin megabytes by opening more.
    /// Claude Code uses one connection at a time; 16 is generous for the real
    /// workload and small enough to bound the worst case.
    static let maxConcurrentConnections = 16

    private let handler: RequestHandler
    private let authorize: Authorizer
    private let statusChanged: (@Sendable (MCPListenerStatus) -> Void)?

    /// Every `NWListener` and `NWConnection` callback is delivered here, so all
    /// per-connection state below is confined to this serial queue and needs no
    /// further locking.
    private let queue = DispatchQueue(label: "com.cherry.mcp.http-listener")

    private let stateLock = NSLock()
    private var listener: NWListener?
    private var status: MCPListenerStatus = .idle

    /// Number of live connections. Only touched on `queue`.
    private var openConnections = 0

    init(
        handler: @escaping RequestHandler,
        authorize: @escaping Authorizer = { _ in false },
        statusChanged: (@Sendable (MCPListenerStatus) -> Void)? = nil
    ) {
        self.handler = handler
        self.authorize = authorize
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
        /// The read deadline, cancelled the moment a response is written so a
        /// finished connection is not held alive waiting for it to fire.
        var readDeadline: DispatchWorkItem?
        /// Guards the open-connection count against a double decrement.
        var counted = true

        init(_ nw: NWConnection) { self.nw = nw }

        /// Drop the accumulated bytes. Called at hand-off: without it a 1 MB
        /// body stayed resident for the whole life of the connection, long
        /// after the request had been parsed out of it.
        func releaseBuffer() {
            buffer = Data()
        }
    }

    private func accept(_ nwConnection: NWConnection) {
        // Over the cap, drop the connection without reading a byte or writing a
        // response — silence leaks nothing, and a 503 would be one more thing an
        // unauthenticated caller could fingerprint.
        guard openConnections < Self.maxConcurrentConnections else {
            nwConnection.cancel()
            return
        }
        openConnections += 1

        let connection = Connection(nwConnection)

        nwConnection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receive(connection)
            case .failed, .cancelled:
                nwConnection.stateUpdateHandler = nil
                self?.release(connection)
            default:
                break
            }
        }

        let deadline = DispatchWorkItem { [weak nwConnection] in
            nwConnection?.cancel()
        }
        connection.readDeadline = deadline
        queue.asyncAfter(deadline: .now() + Self.requestReadTimeout, execute: deadline)

        nwConnection.start(queue: queue)
    }

    /// Give back the connection's slot and stop its deadline. Idempotent.
    private func release(_ connection: Connection) {
        connection.readDeadline?.cancel()
        connection.readDeadline = nil
        connection.releaseBuffer()
        guard connection.counted else { return }
        connection.counted = false
        openConnections = max(0, openConnections - 1)
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
                case .failure(let statusCode, let message, let headers):
                    refuse(statusCode: statusCode, message: message, headers: headers, on: connection)
                    return
                case .incomplete(let nextScanOffset):
                    connection.scanOffset = nextScanOffset
                case .complete(let head):
                    connection.head = head
                }
            }

            if let head = connection.head, connection.buffer.count >= head.totalLength {
                let request = MCPHTTPWire.request(from: connection.buffer, head: head)
                connection.releaseBuffer()
                connection.readDeadline?.cancel()
                connection.readDeadline = nil
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
            receive(connection)
        }
    }

    /// A refusal raised by the framing layer, before any request reached the
    /// handler — and therefore before anything checked the token.
    ///
    /// Answering these with a JSON-RPC body let `Transfer-Encoding: chunked`
    /// fingerprint Cherry with no credentials at all, which is exactly what the
    /// "unauthenticated callers only ever see 401" invariant forbids. So:
    /// where headers were parsed, the token decides; where they were not (a
    /// malformed request line — there is nothing to read a token from), the
    /// status goes back bare, with no body to identify us.
    private func refuse(
        statusCode: Int,
        message: String,
        headers: [String: String]?,
        on connection: Connection
    ) {
        guard let headers else {
            respond(raw: MCPHTTPWire.bareStatus(statusCode), on: connection)
            return
        }
        guard authorize(headers) else {
            respond(MCPBearerValidator.unauthorized, on: connection)
            return
        }
        respond(MCPHTTPWire.framingError(statusCode: statusCode, message: message), on: connection)
    }

    private func respond(_ response: HTTPResponse, on connection: Connection) {
        respond(raw: MCPHTTPWire.serialize(response), on: connection)
    }

    private func respond(raw data: Data, on connection: Connection) {
        connection.readDeadline?.cancel()
        connection.readDeadline = nil
        connection.releaseBuffer()
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
    ///
    /// Note what enforces this: `parseHead` refuses an oversized declared length
    /// up front, and past that the connection stops reading the moment
    /// `buffer.count >= head.totalLength`. There is deliberately no separate
    /// post-head byte ceiling in the receive loop — the one that used to be
    /// there was unreachable in both branches (431 already fires pre-head at the
    /// same threshold, and the hand-off fires first post-head), and an inert
    /// check that reads like a control is worse than no check.
    static let maxBodyBytes = 1024 * 1024

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
        /// `headers` is non-nil when the failure was diagnosed AFTER the header
        /// block parsed (chunked encoding, a bad or oversized `Content-Length`),
        /// which is what lets the caller check the token before answering with
        /// anything more informative than `401`. It is nil when there was never
        /// a readable header block to take a token from.
        case failure(statusCode: Int, message: String, headers: [String: String]?)
    }

    private static let headerTerminator = Data([0x0D, 0x0A, 0x0D, 0x0A])

    static func parseHead(from buffer: Data, resumingAt scanOffset: Int = 0) -> HeadParseResult {
        let start = buffer.startIndex
        let searchFrom = start + max(0, min(scanOffset, buffer.count))

        guard let terminator = buffer.range(of: headerTerminator, in: searchFrom..<buffer.endIndex) else {
            if buffer.count > maxHeaderBytes {
                return .failure(statusCode: 431, message: "Request Header Fields Too Large", headers: nil)
            }
            // Resume three bytes back, so a CRLFCRLF split across two segments
            // is still found.
            return .incomplete(nextScanOffset: max(0, buffer.count - 3))
        }

        let headerEnd = buffer.distance(from: start, to: terminator.lowerBound)
        if headerEnd > maxHeaderBytes {
            return .failure(statusCode: 431, message: "Request Header Fields Too Large", headers: nil)
        }

        var lines = String(decoding: buffer[start..<terminator.lowerBound], as: UTF8.self)
            .components(separatedBy: "\r\n")
        guard !lines.isEmpty else {
            return .failure(statusCode: 400, message: "Malformed request", headers: nil)
        }

        let requestLine = lines.removeFirst()
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count >= 2 else {
            return .failure(statusCode: 400, message: "Malformed request line", headers: nil)
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
                return .failure(statusCode: 400, message: "Malformed header line", headers: nil)
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
                return .failure(statusCode: 400, message: "Malformed header line", headers: nil)
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
            return .failure(statusCode: 501, message: "Transfer-Encoding is not supported", headers: headers)
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
            return .failure(statusCode: 400, message: "Invalid Content-Length", headers: headers)
        }
        guard contentLength <= maxBodyBytes else {
            return .failure(statusCode: 413, message: "Payload Too Large", headers: headers)
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
        case .failure(let statusCode, let message, _):
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
    /// ever reached — an oversized body, chunked encoding.
    ///
    /// Carried in the SDK's `.error` shape so the client gets the JSON body it
    /// asked for, with the HTTP status that actually describes the problem.
    /// **Only ever sent to a caller that presented a valid token** — see
    /// `MCPHTTPListener.refuse`.
    static func framingError(statusCode: Int, message: String) -> HTTPResponse {
        .error(statusCode: statusCode, .invalidRequest(message))
    }

    /// A status line and nothing else: no body, no `Content-Type`, nothing that
    /// says which server this is.
    ///
    /// For refusals where there were never any headers to read a token from, so
    /// the caller cannot be authenticated and must not be told anything.
    static func bareStatus(_ statusCode: Int) -> Data {
        serialize(statusCode: statusCode, headers: [:], body: nil)
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
