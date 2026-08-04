//
//  MCPServerManager.swift
//  Cherry Browser
//
//  Owns the MCP server: the token, the listener, and the per-request server
//  factory that is the whole reason this file is not five lines shorter.
//
//  ## Read this before "simplifying" the factory
//
//  The obvious design is one `MCP.Server` held for the app's lifetime. It is
//  wrong, it works perfectly the first time, and it then fails forever:
//
//      // Sources/MCP/Server/Server.swift:928-929
//      guard await !self.isInitialized else {
//          throw MCPError.invalidRequest("Server is already initialized")
//      }
//
//  `MCP.Server` refuses a second `initialize` for its entire lifetime, and both
//  SDK HTTP server transports hold exactly one session. Cherry is a long-running
//  GUI app connected to by many short-lived client processes over days — every
//  `claude mcp get`, every new Claude Code session, sends its own `initialize`.
//  A shared `Server` serves client #1 and answers every later one with
//  `-32600: Server is already initialized`. The symptom only appears when the
//  CLIENT restarts, not when Cherry does, which is exactly why it survives
//  casual testing.
//
//  So: one `Server` + one `StatelessHTTPServerTransport` per HTTP request.
//  That is legal because `Server.Configuration.default` is `strict: false`
//  (Server.swift:13) and `strict` is the only thing that gates the
//  `checkInitialized()` call (Server.swift:757) — a virgin `Server` that never
//  saw an `initialize` answers `tools/list` and `tools/call` normally.
//
//  The cost is one actor and two closure registrations per request, against a
//  loopback socket serving a handful of calls. It also means no server state
//  survives a request, which is the right security posture anyway.
//
//  ## And read this before deleting the window observers
//
//  Closing Cherry's last window does not quit Cherry. `TabManager` only checks
//  the termination policy on the last-TAB path, and nothing implements
//  `applicationShouldTerminateAfterLastWindowClosed` — so the close button
//  leaves the process alive with zero windows. With the listener still bound
//  that turns a browser into a headless daemon serving the user's history and
//  bookmarks, with no view left anywhere in which the toolbar indicator could
//  warn them. See `observeWindowLifecycle` / `shouldServe`: the socket goes
//  down with the last window and comes back with the next one, using
//  `TabManager`'s own liveness predicate rather than a second opinion.
//

import AppKit
import Foundation
import Observation
import MCP

// MARK: - Per-request server

/// Builds a fresh `MCP.Server` for a single HTTP request and tears it down again.
///
/// `nonisolated` because it runs on the SDK's executor, off the main actor, and
/// must never reach a browser type. Its only inputs are the port (for origin
/// validation), a token lookup, and the tool invoker.
nonisolated struct MCPRequestServer: Sendable {

    /// The seam the five tools attach to, and the only one they needed.
    ///
    /// `MCPToolInvoker` fills it: it parses arguments off-main, hops to the main
    /// actor once to ask `MCPBrowserBridge` for a `Sendable` payload, and encodes
    /// that payload to JSON. Nothing in this file, the listener, the bearer
    /// validator or the token store knows which tools exist or what they return.
    typealias ToolInvoker = @Sendable (CallTool.Parameters) async -> CallTool.Result

    let serverName: String
    let serverVersion: String
    let port: Int
    let expectedToken: @Sendable () -> String?
    let invokeTool: ToolInvoker

    var bearer: MCPBearerValidator { MCPBearerValidator(expectedToken: expectedToken) }

    /// THE token check, and it happens before anything else touches the request.
    ///
    /// `StatelessHTTPServerTransport.handleRequest` answers 405 (with
    /// `Allow: POST`) for a non-POST, and 400 "Empty request body" / "Invalid
    /// JSON-RPC message" for a body it cannot classify — all BEFORE it runs the
    /// pipeline. So a bearer validator that is merely first *inside* the
    /// pipeline is not first: an unauthenticated caller could still fingerprint
    /// Cherry on the port, and — the part that actually matters —
    /// attacker-controlled bytes reached `JSONRPCMessageKind`, a JSON decode
    /// over an unauthenticated body of up to 1 MB, before the token was ever
    /// compared.
    ///
    /// Returns the refusal to send, or `nil` if the caller is authorised.
    /// Nothing is allocated and no byte of the body is looked at either way.
    func authenticate(_ request: HTTPRequest) -> HTTPResponse? {
        bearer.validate(request, context: HTTPValidationContext(httpMethod: request.method.uppercased()))
    }

    /// Authenticate, then dispatch. Callers that need to distinguish the two —
    /// the listener does, so unauthenticated requests never reach the main
    /// actor — call the halves separately.
    func serve(_ request: HTTPRequest) async -> HTTPResponse {
        if let refusal = authenticate(request) { return refusal }
        return await dispatch(request)
    }

    /// Build a fresh `Server` + transport for this one request and run it.
    ///
    /// **Only reachable once `authenticate` has passed.**
    func dispatch(_ request: HTTPRequest) async -> HTTPResponse {
        let server = Server(
            name: serverName,
            version: serverVersion,
            instructions: Self.instructions,
            capabilities: .init(tools: .init(listChanged: false))
        )

        let transport = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [
                // Belt and braces. The check above is the one that holds the
                // "only ever 401" invariant; this one keeps holding it inside
                // the pipeline if the pre-check is ever refactored away, and it
                // costs one read of a 43-byte file.
                bearer,
                // DNS-rebinding protection. The SDK validates `Origin` only when
                // present, which is correct here: Claude Code sends none and
                // passes, while a web page's `fetch()` sends one and is refused.
                OriginValidator.localhost(port: port),
                AcceptHeaderValidator(mode: .jsonOnly),
                ContentTypeValidator(),
                ProtocolVersionValidator(),
            ])
        )

        do {
            try await server.start(transport: transport)
        } catch {
            return .error(statusCode: 500, .internalError("Could not start MCP server: \(error)"))
        }
        defer { Task { await server.stop() } }

        // Registered after `start`, which is where the SDK installs its own
        // default handlers — this way ours can never be overwritten by them.
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: MCPToolRegistry.tools)
        }
        await server.withMethodHandler(CallTool.self) { [invokeTool] params in
            await invokeTool(params)
        }

        return await transport.handleRequest(request)
    }

    /// Shown to the client alongside the tool list.
    static let instructions = """
        Cherry is the user's web browser, running on their Mac. These tools read what is \
        already open or already saved — they do not browse the web on their own, and they \
        cannot click, type, or fill in forms. Everything they return is personal: open tabs, \
        page text, browsing history, bookmarks. Private and incognito windows are never \
        visible through them.
        """
}

// MARK: - Manager

/// The app-facing owner of the MCP server.
///
/// `@MainActor` by construction (this target sets
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), so it can read `SettingsManager`
/// directly and publish indicator state to SwiftUI. Everything that touches the
/// socket lives behind `MCPHTTPListener`, which is `nonisolated`.
@Observable
final class MCPServerManager {

    static let shared = MCPServerManager()

    /// What the listener is doing. Drives the Settings pane in step 8.
    private(set) var status: MCPListenerStatus = .idle

    /// When a client last made a request. Because the server is stateless there
    /// is no persistent "connected" state to show — the honest indicator is
    /// "enabled, last used 4s ago", not a fake connection lamp.
    private(set) var lastActivity: Date?

    /// Requests currently being served. Briefly non-zero; used to pulse the
    /// indicator rather than to gate anything.
    private(set) var activeRequestCount = 0

    private var listener: MCPHTTPListener?
    private var wakeObserver: (any NSObjectProtocol)?
    private var windowObservers: [any NSObjectProtocol] = []

    /// The feature is on, but the listener is deliberately down because no
    /// window is keeping Cherry alive.
    ///
    /// This is what separates "stopped because the user switched it off" from
    /// "stopped until a window comes back". Without it, the resume path would
    /// have to re-derive intent from the settings flag alone, and would retry
    /// `start()` on every window event even when the last attempt failed for a
    /// permanent reason (no Application Support, an unsecurable token file).
    private var suspendedUntilAWindowReturns = false

    var isRunning: Bool { listener != nil }

    /// The command the user pastes into a terminal to register Cherry.
    /// Surfaced by the Settings pane in step 8.
    func registrationCommand(includingToken: Bool) -> String {
        let port = SettingsManager.shared.mcpServerPort
        let store = MCPTokenStore.shared
        let token: String
        if includingToken {
            // A token that cannot be served safely is not shown either — the
            // pane would otherwise hand the user a command that is about to be
            // rejected by the server's own fail-closed check.
            token = store?.tokenForAuthentication() ?? "<token>"
        } else if let path = store?.tokenFileURL.path {
            token = "$(cat \"\(path)\")"
        } else {
            token = "<token>"
        }
        return "claude mcp add --transport http --scope user cherry http://127.0.0.1:\(port)/mcp "
            + "--header \"Authorization: Bearer \(token)\""
    }

    // MARK: Lifecycle

    /// Start only if the user has switched the feature on. This is what the app
    /// launch path calls — the feature is off on a fresh `UserDefaults` and must
    /// stay that way.
    func startIfEnabled() {
        guard SettingsManager.shared.mcpServerEnabled else { return }
        start()
    }

    /// Bind the socket. Safe to call when already running — it rebinds.
    func start() {
        stop()

        // No resolvable Application Support means nowhere safe to keep the
        // token, and there is no acceptable fallback location for it — so the
        // server does not run at all.
        guard let store = MCPTokenStore.shared else {
            status = .failed(reason: MCPTokenStore.Failure.applicationSupportUnavailable.localizedDescription)
            return
        }

        let token: String
        do {
            token = try store.currentToken()
        } catch {
            status = .failed(reason: error.localizedDescription)
            return
        }
        guard !token.isEmpty else {
            status = .failed(reason: "No MCP token could be generated.")
            return
        }

        let port = SettingsManager.shared.mcpServerPort
        let requestServer = MCPRequestServer(
            serverName: "Cherry",
            serverVersion: Self.appVersion,
            port: port,
            // Read from disk per request rather than capturing the string, so
            // rotating the token in Settings invalidates existing clients
            // immediately without restarting the listener — and so a token that
            // becomes unsecurable while the server runs locks it, rather than
            // being served out of a directory someone else now controls.
            expectedToken: { MCPTokenStore.shared?.tokenForAuthentication() },
            // The whole of the browser side of this feature, behind one closure.
            invokeTool: MCPToolInvoker().invoker
        )

        let newListener = MCPHTTPListener(
            handler: { [weak self] request in
                // Authenticate BEFORE any hop to the main actor. The telemetry
                // below mutates `@Observable` state, so doing it first let any
                // web page POST to the port and force two main-actor hops plus
                // an observation invalidation — enough to drive a SwiftUI
                // re-render — before the token was compared, and let
                // unauthenticated garbage write the "last used" timestamp.
                if let refusal = requestServer.authenticate(request) { return refusal }

                await MainActor.run { self?.requestBegan() }
                let response = await requestServer.dispatch(request)
                await MainActor.run { self?.requestEnded() }
                return response
            },
            authorize: { headers in requestServer.bearer.authorizes(headers: headers) },
            statusChanged: { [weak self] newStatus in
                Task { @MainActor in self?.status = newStatus }
            }
        )

        listener = newListener
        newListener.start(port: UInt16(clamping: port))
        observeWake()
    }

    /// Close the socket. Idempotent; safe at termination.
    func stop() {
        listener?.stop()
        listener = nil
        activeRequestCount = 0
        stopObservingWake()
        status = .idle
    }

    /// Apply a port or enablement change made in Settings.
    ///
    /// The pane lives in a tab, so reaching this code at all means a window is
    /// on screen — which is why it can start unconditionally, and why any
    /// window-policy suspension is stale by definition once the user has
    /// clicked something.
    func applySettingsChange() {
        suspendedUntilAWindowReturns = false
        if SettingsManager.shared.mcpServerEnabled {
            start()
        } else {
            stop()
        }
    }

    // MARK: Windows

    /// Whether the listener should be bound, given the feature flag and what
    /// windows exist.
    ///
    /// **The predicate is `TabManager`'s, not a second one.** "Cherry still has
    /// a window" is exactly the question the termination policy answers, and it
    /// is a question with four traps in it — a minimised window is not
    /// `isVisible`, *no* window is `isVisible` while the app is hidden, panels
    /// and borderless helper windows must not count, and a closed window is
    /// still in `NSApp.windows`. `TabManager.shouldTerminateApp` has those
    /// answers and a test file locking them; a hand-rolled copy here would
    /// start identical and drift.
    ///
    /// So: serve exactly when the user has switched the feature on and at least
    /// one window would keep the app alive. The two definitions cannot disagree
    /// because there is only one.
    nonisolated static func shouldServe(
        enabled: Bool,
        windows: [TabManager.WindowLiveness],
        appIsHidden: Bool
    ) -> Bool {
        enabled && !TabManager.shouldTerminateApp(windows: windows, appIsHidden: appIsHidden)
    }

    /// Bring the listener into line with the windows that exist right now.
    ///
    /// `closingWindow` is the window whose `willClose` triggered this. Closing a
    /// window does not take it out of `NSApp.windows` — every browser window
    /// sets `isReleasedWhenClosed = false` — so without excluding it, the last
    /// window closing would find its own corpse and keep serving.
    func reconcileWithWindowState(closing closingWindow: NSWindow? = nil) {
        let enabled = SettingsManager.shared.mcpServerEnabled
        let serve = Self.shouldServe(
            enabled: enabled,
            windows: TabManager.livenessSnapshot(of: NSApp.windows, excluding: closingWindow),
            appIsHidden: NSApp.isHidden
        )

        if serve {
            // Only resume what this policy suspended. Every other reason the
            // listener is down — switched off, failed to bind, no token — is
            // not a window's business to undo, and a window becoming key is far
            // too common an event to retry a permanent failure on.
            guard suspendedUntilAWindowReturns else { return }
            suspendedUntilAWindowReturns = false
            start()
        } else if isRunning {
            suspendedUntilAWindowReturns = enabled
            stop()
        }
    }

    /// Watch for the app losing its last window, and for getting one back.
    ///
    /// Called once at launch, and deliberately independent of whether the
    /// server is running: a suspended listener has to be able to hear a window
    /// arrive, and it cannot do that through an observer it only installs while
    /// it is up.
    ///
    /// **Why these two notifications are the complete set.**
    ///
    /// *Losing the last window.* A window that counts (`keepsAppAlive`) stops
    /// counting only by being closed. Minimising does not do it — `isMiniaturized`
    /// is explicitly allowed. Hiding the app does not do it — `appIsHidden` is
    /// explicitly allowed, and it is the same rule that stops ⌘H from throwing
    /// away every window's tabs. Being ordered off screen would do it, but the
    /// only `orderOut(nil)` calls in the app are on the tab-drag ghost and the
    /// tab hover preview, and both are borderless, so neither ever counted in
    /// the first place. That leaves closing, and closing posts
    /// `willCloseNotification` — for a window closed by its button, by ⌘W, by
    /// the last tab going away, or programmatically.
    ///
    /// *Getting one back.* A window that is going to keep Cherry alive has to be
    /// ordered in, and a window ordered in while Cherry is the active app
    /// becomes key. `didBecomeKeyNotification` therefore covers ⌘N, ⌘T from an
    /// empty state, reopening from the Dock, and a window restored from the
    /// Dock. The two application-level notifications close the case where a
    /// window appears while Cherry is *not* frontmost, so nothing arrives
    /// unseen. Over-triggering the resume side is free: `reconcileWithWindowState`
    /// acts only on a transition, and the asymmetry is deliberate — a missed
    /// suspend leaves history on a socket, a missed resume leaves a feature
    /// looking broken.
    func observeWindowLifecycle() {
        guard windowObservers.isEmpty else { return }
        let center = NotificationCenter.default

        windowObservers.append(
            center.addObserver(
                forName: NSWindow.willCloseNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let closing = notification.object as? NSWindow
                MainActor.assumeIsolated { self?.reconcileWithWindowState(closing: closing) }
            }
        )

        for name in [
            NSWindow.didBecomeKeyNotification,
            NSApplication.didBecomeActiveNotification,
            NSApplication.didUnhideNotification,
        ] {
            windowObservers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reconcileWithWindowState() }
                }
            )
        }
    }

    // MARK: Indicator

    private func requestBegan() {
        activeRequestCount += 1
        lastActivity = Date()
    }

    private func requestEnded() {
        activeRequestCount = max(0, activeRequestCount - 1)
        lastActivity = Date()
    }

    // MARK: Sleep / wake

    /// `NWListener` is not torn down by system sleep, and because every request
    /// carries its own `Server` a dropped connection costs nothing. This is
    /// defensive: if the listener did come back `.failed` or `.cancelled`,
    /// rebuild it rather than leave a switched-on feature silently dead.
    ///
    /// Style precedent: `PasswordManager` observes `NSWorkspace.willSleepNotification`.
    private func observeWake() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartIfListenerDied() }
        }
    }

    private func stopObservingWake() {
        guard let wakeObserver else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        self.wakeObserver = nil
    }

    private func restartIfListenerDied() {
        guard SettingsManager.shared.mcpServerEnabled,
              let listener,
              listener.currentStatus.needsRestart
        else {
            return
        }
        start()
    }

    // MARK: Misc

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
    }
}
