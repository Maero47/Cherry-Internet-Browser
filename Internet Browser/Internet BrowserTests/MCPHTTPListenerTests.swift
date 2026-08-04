//
//  MCPHTTPListenerTests.swift
//  Internet BrowserTests
//
//  The loopback bind is the primary security control on this feature — the
//  bearer token is the second line, not the only one. "We set
//  `requiredLocalEndpoint`" is not evidence; opening a real socket and being
//  refused from the machine's own LAN address is.
//
//  Also pins the off-by-default rule, which is the other property that cannot
//  be allowed to regress quietly.
//

import XCTest
import Network
import MCP
@testable import Cherry

final class MCPHTTPListenerTests: XCTestCase {

    private var listener: MCPHTTPListener?
    private var port: UInt16 = 0

    override func tearDown() {
        listener?.stop()
        listener = nil
        super.tearDown()
    }

    // MARK: - Setup

    /// Bind on a high port picked per-run, so two test runs (or a running copy
    /// of Cherry on 8787) cannot collide.
    private func startListener(
        handler: @escaping MCPHTTPListener.RequestHandler,
        authorize: @escaping MCPHTTPListener.Authorizer = { _ in false }
    ) throws -> UInt16 {
        var candidate = UInt16.random(in: 20000...40000)

        for _ in 0..<10 {
            let settled = XCTestExpectation(description: "listener settled on \(candidate)")
            settled.assertForOverFulfill = false

            let listener = MCPHTTPListener(handler: handler, authorize: authorize, statusChanged: { status in
                switch status {
                case .ready, .failed: settled.fulfill()
                case .idle, .starting, .cancelled: break
                }
            })
            listener.start(port: candidate)
            _ = XCTWaiter().wait(for: [settled], timeout: 3)

            if listener.currentStatus.isReady {
                self.listener = listener
                self.port = candidate
                return candidate
            }
            listener.stop()
            candidate = candidate &+ 137
        }
        throw XCTSkip("could not bind any loopback port in this environment")
    }

    private func post(to host: String, port: UInt16, timeout: TimeInterval = 5) -> (status: Int?, body: String?, error: Error?) {
        var request = URLRequest(url: URL(string: "http://\(host):\(port)/mcp")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8)
        request.timeoutInterval = timeout

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout

        var result: (Int?, String?, Error?) = (nil, nil, nil)
        let done = expectation(description: "request to \(host)")
        URLSession(configuration: configuration).dataTask(with: request) { data, response, error in
            result = (
                (response as? HTTPURLResponse)?.statusCode,
                data.map { String(decoding: $0, as: UTF8.self) },
                error
            )
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: timeout + 5)
        return result
    }

    /// Send raw bytes and read everything back until the server closes.
    ///
    /// URLSession will not emit a malformed request line or a bogus
    /// `Transfer-Encoding`, and those are exactly the framing refusals that must
    /// not answer an unauthenticated caller with anything identifying.
    private func sendRaw(_ request: String, port: UInt16, timeout: TimeInterval = 5) -> String {
        let connection = NWConnection(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        let received = Received()
        let done = expectation(description: "raw exchange on \(port)")
        done.assertForOverFulfill = false

        func read() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let data, !data.isEmpty { received.append(data) }
                if isComplete || error != nil {
                    done.fulfill()
                } else {
                    read()
                }
            }
        }

        connection.stateUpdateHandler = { state in
            if case .ready = state {
                connection.send(content: Data(request.utf8), completion: .contentProcessed { _ in })
                read()
            }
            if case .failed = state { done.fulfill() }
            if case .cancelled = state { done.fulfill() }
        }
        connection.start(queue: .global())
        wait(for: [done], timeout: timeout)
        connection.cancel()
        return received.text
    }

    private final class Received: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// The machine's own non-loopback IPv4 address, if it has one.
    private func lanAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var candidate: String?
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard interface.ifa_addr?.pointee.sa_family == UInt8(AF_INET),
                  (interface.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
                  (interface.ifa_flags & UInt32(IFF_UP)) != 0
            else {
                continue
            }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                interface.ifa_addr,
                socklen_t(interface.ifa_addr.pointee.sa_len),
                &buffer, socklen_t(buffer.count),
                nil, 0, NI_NUMERICHOST
            ) == 0 else {
                continue
            }
            let address = String(cString: buffer)
            if !address.hasPrefix("127.") { candidate = address }
        }
        return candidate
    }

    // MARK: - Loopback binding

    func testAnswersOnLoopback() throws {
        let port = try startListener { _ in
            .data(Data(#"{"stub":true}"#.utf8), headers: ["Content-Type": "application/json"])
        }

        let response = post(to: "127.0.0.1", port: port)
        XCTAssertNil(response.error, "\(String(describing: response.error))")
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.body, #"{"stub":true}"#)
    }

    /// The requirement that matters: nothing on the LAN can reach the socket.
    ///
    /// This used to `XCTSkip` on a machine with no non-loopback IPv4, which
    /// meant the single strongest structural assertion in the feature could go
    /// green having checked nothing. It no longer skips: with no LAN address it
    /// asserts the IPv6-loopback case instead, which every machine has.
    func testRefusesTheMachinesOwnLANAddress() throws {
        let port = try startListener { _ in .data(Data(#"{"stub":true}"#.utf8)) }

        guard let lan = lanAddress() else {
            XCTAssertNil(
                post(to: "[::1]", port: port, timeout: 3).status,
                "no LAN address on this machine, and the IPv6 loopback fallback also reached the listener"
            )
            return
        }

        let response = post(to: lan, port: port, timeout: 3)
        XCTAssertNil(response.status, "the listener answered on \(lan):\(port) — the bind is not loopback-only")
        XCTAssertNotNil(response.error, "expected a connection failure from \(lan)")
    }

    /// The bind is `.ipv4(.loopback)`, so even the *IPv6* loopback is a
    /// different address and must be refused. Unlike the LAN address this one
    /// exists on every machine, so this test can never quietly not run.
    func testRefusesIPv6LoopbackWhichIsADifferentLocalAddress() throws {
        let port = try startListener { _ in .data(Data(#"{"stub":true}"#.utf8)) }

        XCTAssertEqual(post(to: "127.0.0.1", port: port).status, 200, "precondition: IPv4 loopback works")
        XCTAssertNil(
            post(to: "[::1]", port: port, timeout: 3).status,
            "the listener answered on [::1]:\(port) — the bind is wider than ipv4 loopback"
        )
    }

    func testStoppingClosesTheSocket() throws {
        let port = try startListener { _ in .data(Data(#"{"stub":true}"#.utf8)) }
        XCTAssertEqual(post(to: "127.0.0.1", port: port).status, 200, "precondition")

        listener?.stop()
        listener = nil

        let response = post(to: "127.0.0.1", port: port, timeout: 3)
        XCTAssertNil(response.status, "the socket was still answering after stop()")
    }

    // MARK: - Framing over a real socket

    func testHandlerSeesTheParsedRequest() throws {
        let seen = SeenRequest()
        let port = try startListener { request in
            seen.record(request)
            return .data(Data("ok".utf8))
        }

        _ = post(to: "127.0.0.1", port: port)

        XCTAssertEqual(seen.method, "POST")
        XCTAssertEqual(seen.path, "/mcp")
        XCTAssertEqual(seen.contentType, "application/json")
        XCTAssertEqual(seen.body, #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
    }

    func testStatusReportsReadyThenIdle() throws {
        let port = try startListener { _ in .data(Data("ok".utf8)) }
        XCTAssertEqual(listener?.currentStatus, .ready(port: port))
        listener?.stop()
        XCTAssertEqual(listener?.currentStatus, .idle)
    }

    func testStatusKnowsWhenARestartIsNeeded() {
        XCTAssertFalse(MCPListenerStatus.ready(port: 8787).needsRestart)
        XCTAssertFalse(MCPListenerStatus.idle.needsRestart)
        XCTAssertFalse(MCPListenerStatus.starting.needsRestart)
        XCTAssertTrue(MCPListenerStatus.cancelled.needsRestart)
        XCTAssertTrue(MCPListenerStatus.failed(reason: "in use").needsRestart)
    }

    // MARK: - Framing refusals must not answer an unauthenticated caller

    /// Framing-layer refusals used to return a JSON-RPC-shaped body before any
    /// token check, so `Transfer-Encoding: chunked` alone fingerprinted Cherry
    /// with no credentials at all — the exact recon the "unauthenticated callers
    /// only ever see 401" invariant exists to deny. The header block parsed
    /// here, so there IS a token to check, and it decides.
    func testChunkedEncodingWithoutATokenGets401NotDetail() throws {
        let port = try startListener(
            handler: { _ in .data(Data("ok".utf8)) },
            authorize: { headers in headers["authorization"] == "Bearer good" }
        )

        let response = sendRaw(
            "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nTransfer-Encoding: chunked\r\n\r\n",
            port: port
        )
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 401"), response)
        XCTAssertFalse(response.contains("Transfer-Encoding is not supported"), response)
        XCTAssertFalse(response.lowercased().contains("not implemented"), response)
    }

    /// …and with a valid token the caller gets the real, useful diagnosis.
    func testChunkedEncodingWithAValidTokenGetsTheRealReason() throws {
        let port = try startListener(
            handler: { _ in .data(Data("ok".utf8)) },
            authorize: { headers in headers["authorization"] == "Bearer good" }
        )

        let response = sendRaw(
            "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer good\r\nTransfer-Encoding: chunked\r\n\r\n",
            port: port
        )
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 501"), response)
        XCTAssertTrue(response.contains("Transfer-Encoding is not supported"), response)
    }

    func testOversizedContentLengthWithoutATokenGets401() throws {
        let port = try startListener(
            handler: { _ in .data(Data("ok".utf8)) },
            authorize: { headers in headers["authorization"] == "Bearer good" }
        )

        let response = sendRaw(
            "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: \(MCPHTTPWire.maxBodyBytes + 1)\r\n\r\n",
            port: port
        )
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 401"), response)
    }

    /// A malformed request line has no header block, so there is nothing to read
    /// a token from and no way to authenticate the caller. It gets the status
    /// and nothing else — no body, no `Content-Type`, nothing that names us.
    func testMalformedRequestLineGetsABareStatusWithNoBody() throws {
        let port = try startListener(
            handler: { _ in .data(Data("ok".utf8)) },
            authorize: { _ in true }
        )

        let response = sendRaw("GARBAGE\r\n\r\n", port: port)
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 400"), response)
        XCTAssertTrue(response.contains("Content-Length: 0"), response)
        XCTAssertFalse(response.contains("jsonrpc"), response)
        XCTAssertFalse(response.contains("Malformed"), response)
        XCTAssertFalse(response.lowercased().contains("content-type"), response)
    }

    // MARK: - Resource bounds

    /// `maxBodyBytes` bounds one request; nothing bounded how many were in
    /// flight. Past the cap the listener drops the connection without reading a
    /// byte or writing a response — a 503 would be one more thing to fingerprint.
    func testConcurrentConnectionsAreCapped() throws {
        let port = try startListener { _ in .data(Data("ok".utf8)) }

        // Fill the cap with connections that open a request and never finish it.
        var held: [NWConnection] = []
        defer { held.forEach { $0.cancel() } }

        for _ in 0..<MCPHTTPListener.maxConcurrentConnections {
            let connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            connection.start(queue: .global())
            connection.send(content: Data("POST /mcp HTTP/1.1\r\n".utf8), completion: .contentProcessed { _ in })
            held.append(connection)
        }
        pause(0.5)

        XCTAssertNil(
            post(to: "127.0.0.1", port: port, timeout: 3).status,
            "the \(MCPHTTPListener.maxConcurrentConnections + 1)th connection was served — nothing is bounding concurrency"
        )

        // …and the slots come back, so the cap is a bound rather than a wedge.
        held.forEach { $0.cancel() }
        held = []
        pause(0.5)

        XCTAssertEqual(
            post(to: "127.0.0.1", port: port).status, 200,
            "connection slots were never released"
        )
    }

    private func pause(_ seconds: TimeInterval) {
        let settled = XCTestExpectation(description: "pause")
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { settled.fulfill() }
        _ = XCTWaiter().wait(for: [settled], timeout: seconds + 3)
    }

    // MARK: - Off by default

    /// A fresh install opens no socket. This reads the same code path `init`
    /// uses, against a throwaway suite.
    func testFeatureIsOffOnFreshUserDefaults() throws {
        let suiteName = "MCPHTTPListenerTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(SettingsManager.mcpServerEnabled(from: defaults))
        XCTAssertEqual(SettingsManager.mcpServerPort(from: defaults), 8787)
    }

    /// `isValidMCPServerPort` was only consulted on the read path, so the setter
    /// would happily store anything. Port 0 is the dangerous one:
    /// `NWEndpoint.Port(rawValue: 0)` is `.any`, so the listener binds an
    /// OS-assigned port while the origin validator and the registration command
    /// keep describing a port nothing is on — every legitimate client then
    /// gets 421.
    func testSettingAnOutOfRangePortIsRefused() {
        let settings = SettingsManager.shared
        let original = settings.mcpServerPort
        let storedBefore = UserDefaults.standard.object(forKey: "mcpServerPort")
        defer {
            settings.mcpServerPort = original
            if let storedBefore {
                UserDefaults.standard.set(storedBefore, forKey: "mcpServerPort")
            } else {
                UserDefaults.standard.removeObject(forKey: "mcpServerPort")
            }
        }

        for invalid in [0, -1, 80, 1023, 65536, 100_000] {
            settings.mcpServerPort = invalid
            XCTAssertNotEqual(settings.mcpServerPort, invalid, "stored out-of-range port \(invalid)")
            XCTAssertTrue(SettingsManager.isValidMCPServerPort(settings.mcpServerPort))
        }

        settings.mcpServerPort = 9911
        XCTAssertEqual(settings.mcpServerPort, 9911, "a valid port must still be accepted")
    }

    func testStoredPortIsHonouredAndOutOfRangeValuesFallBack() throws {
        let suiteName = "MCPHTTPListenerTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(9999, forKey: "mcpServerPort")
        XCTAssertEqual(SettingsManager.mcpServerPort(from: defaults), 9999)

        for invalid in [0, 80, 1023, 65536, -1] {
            defaults.set(invalid, forKey: "mcpServerPort")
            XCTAssertEqual(
                SettingsManager.mcpServerPort(from: defaults), 8787,
                "port \(invalid) should have fallen back to the default"
            )
        }
    }
}

/// Captures what the listener handed the handler. The handler runs off the main
/// thread on the listener's queue, so this is lock-guarded.
private final class SeenRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var request: HTTPRequest?

    func record(_ request: HTTPRequest) {
        lock.lock()
        self.request = request
        lock.unlock()
    }

    private var snapshot: HTTPRequest? {
        lock.lock()
        defer { lock.unlock() }
        return request
    }

    var method: String? { snapshot?.method }
    var path: String? { snapshot?.path }
    var contentType: String? { snapshot?.header("Content-Type") }
    var body: String? { snapshot?.body.map { String(decoding: $0, as: UTF8.self) } }
}
