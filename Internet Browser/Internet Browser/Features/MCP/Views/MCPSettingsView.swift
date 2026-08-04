//
//  MCPSettingsView.swift
//  Cherry Browser
//
//  Settings ▸ Connections. The switch that lets an outside program read this
//  browser, and the copy that has to be straight about what that means.
//
//  ## The copy is the feature
//
//  This pane grants a local program the ability to list the user's tabs, read
//  the page in front of them, and search their history and bookmarks. A pane
//  that oversells the token would be worse than no pane: the failure to avoid
//  is a user who believes the switch is safer than it is. So, in order:
//
//  - What the token DOES stop: unauthenticated localhost callers, above all a
//    web page doing `fetch('http://127.0.0.1:8787/mcp')` from inside a browser.
//    That is a real and well-known footgun, and the token closes it.
//  - What it does NOT stop: anything already running under this user account.
//    Such a program can read the token file, and could read Cherry's stored
//    history directly whether this switch is on or off. Said plainly, not
//    buried.
//  - That Cherry has to be running, and that closing the last window quits
//    Cherry. Without this a client just reports "failed to connect".
//  - That regenerating the token breaks every registered client instantly.
//    Said on the button, before it is pressed.
//
//  ## And the states
//
//  Off, starting, running-idle, running-with-a-client, and four ways of not
//  running. `MCPServerPresentation` owns that mapping and is unit-tested; this
//  file only draws it. A pane that renders the happy path is half a pane, and
//  the half it is missing is the half users see when something is wrong.
//

import AppKit
import SwiftUI

struct MCPSettingsView: View {

    @Bindable private var settings = SettingsManager.shared
    @State private var manager = MCPServerManager.shared

    /// The port field's live text. Committed deliberately, not on every
    /// keystroke: half a port number is a valid prefix of a real one, and
    /// rebinding the listener on "87" would be absurd.
    @State private var portText = ""
    @State private var portEntry: MCPPortEntry = .empty

    /// The token is a secret, so the pane defaults to the `$(cat …)` command
    /// form and never puts it on screen unasked. Revealing it is a button.
    @State private var revealToken = false

    @State private var copiedCommand = false
    @State private var confirmingRegenerate = false
    @State private var regenerateOutcome: RegenerateOutcome?

    /// Re-read while a client is active so "a moment ago" does not freeze.
    /// Bounded: see `tickWhileActive()`.
    @State private var now = Date()

    private enum RegenerateOutcome: Equatable {
        case done
        case failed(String)
    }

    private var presentation: MCPServerPresentation {
        MCPServerPresentation.make(
            enabled: settings.mcpServerEnabled,
            status: manager.status,
            port: settings.mcpServerPort,
            activeRequestCount: manager.activeRequestCount,
            lastActivity: manager.lastActivity,
            now: now
        )
    }

    var body: some View {
        SettingsStack {
            serverCard
            if settings.mcpServerEnabled {
                registrationCard
                tokenCard
            }
            exposureCard
            reachCard
        }
        .onAppear {
            portText = String(settings.mcpServerPort)
            portEntry = .valid(settings.mcpServerPort)
            now = Date()
        }
        .task(id: manager.lastActivity) { await tickWhileActive() }
    }

    // MARK: - The switch and its state

    private var serverCard: some View {
        SettingsCard(
            icon: "point.3.connected.trianglepath.dotted",
            title: "MCP Server",
            subtitle: "Lets Claude Code use this browser."
        ) {
            statusBlock

            Divider()

            SettingsToggleRow(
                title: "Serve Cherry to local MCP clients",
                isOn: Binding(
                    get: { settings.mcpServerEnabled },
                    set: { newValue in
                        settings.mcpServerEnabled = newValue
                        MCPServerManager.shared.applySettingsChange()
                    }
                )
            )

            MCPBodyText(
                "Off until you switch it on. While it is on, Cherry listens on 127.0.0.1 and any client "
                    + "holding the token can read what is listed below."
            )

            Divider()

            portRow
        }
    }

    private var statusBlock: some View {
        let state = presentation

        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: state.tone.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(state.tone.color)
                .frame(width: 16, height: 18)
                // The indicator does not breathe, blink, or loop. It changes
                // when the server's state changes and is still the rest of the
                // time; a settings pane that pulses is a settings pane you
                // cannot stop looking at.
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(state.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(state.tone.titleColor)
                    .fixedSize(horizontal: false, vertical: true)

                MCPBodyText(state.detail)

                if let remedy = state.remedy {
                    MCPBodyText(remedy)
                }

                if let technical = state.technical {
                    Text(technical)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("MCP server status: \(state.title). \(state.detail)")
    }

    // MARK: - Port

    private var portRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsLabeledRow(title: "Port") {
                HStack(spacing: 8) {
                    TextField("Port", text: $portText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 84)
                        .multilineTextAlignment(.trailing)
                        .onSubmit(commitPort)
                        .onChange(of: portText) { _, newValue in
                            portEntry = MCPPortEntry.parse(newValue)
                        }
                        .accessibilityLabel("MCP server port")

                    Button("Set Port", action: commitPort)
                        .controlSize(.small)
                        .disabled(portEntry.port == nil || portEntry.port == settings.mcpServerPort)
                }
            }

            if let message = portEntry.message {
                MCPNoticeText(message, tone: .failure)
            } else if portEntry.port != settings.mcpServerPort {
                MCPBodyText(
                    "Changing the port restarts the server and invalidates the command you already copied. "
                        + "Register your clients again with the new one."
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func commitPort() {
        guard let port = MCPPortEntry.parse(portText).port else { return }
        guard port != settings.mcpServerPort else { return }
        settings.mcpServerPort = port
        // The setter refuses anything out of range, so read back rather than
        // trusting the write, and show the field what actually stuck.
        portText = String(settings.mcpServerPort)
        portEntry = .valid(settings.mcpServerPort)
        MCPServerManager.shared.applySettingsChange()
    }

    // MARK: - The command

    private var registrationCard: some View {
        SettingsCard(
            icon: "terminal",
            title: "Register Claude Code",
            subtitle: "Run this once in Terminal."
        ) {
            Text(command)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                }
                .accessibilityLabel("Registration command")

            HStack(spacing: 8) {
                Button(copiedCommand ? "Copied" : "Copy Command", action: copyCommand)
                    .controlSize(.small)

                Button(revealToken ? "Hide Token" : "Show Token") {
                    revealToken.toggle()
                    copiedCommand = false
                }
                .controlSize(.small)
                .help(revealToken
                      ? "Go back to the form that reads the token from its file"
                      : "Put the token itself in the command, on screen")

                Spacer(minLength: 0)
            }

            if revealToken {
                MCPNoticeText(
                    "The token is on screen. Anyone looking at this window, and any screen recording running "
                        + "right now, can read it.",
                    tone: .failure
                )
            } else {
                MCPBodyText(
                    "This form reads the token out of its file when you run it, so the secret never appears on "
                        + "screen or in your shell history."
                )
            }

            MCPBodyText("Cherry has only been verified against Claude Code. Claude Desktop is untested.")
        }
    }

    private var command: String {
        manager.registrationCommand(includingToken: revealToken)
    }

    private func copyCommand() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
        copiedCommand = true
    }

    // MARK: - Token

    private var tokenCard: some View {
        SettingsCard(icon: "key.horizontal", title: "Token") {
            MCPBodyText(
                "One token, in a file only your account can read. Cherry checks it before it looks at anything "
                    + "else in a request."
            )

            Button("Regenerate Token") { confirmingRegenerate = true }
                .controlSize(.small)

            MCPNoticeText(
                "Every client you have already registered stops working the moment you do this, and has to be "
                    + "registered again with the new command above.",
                tone: .failure
            )

            switch regenerateOutcome {
            case .done:
                MCPBodyText("New token in place. Register your clients again with the command above.")
            case .failed(let message):
                MCPNoticeText(message, tone: .failure)
            case nil:
                EmptyView()
            }
        }
        .confirmationDialog(
            "Regenerate the MCP token?",
            isPresented: $confirmingRegenerate,
            titleVisibility: .visible
        ) {
            Button("Regenerate Token", role: .destructive, action: regenerateToken)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Every client registered with the current token stops working immediately and has to be "
                    + "registered again."
            )
        }
    }

    private func regenerateToken() {
        // Never force-unwrap the store: no Application Support means no token,
        // and the pane's job at that point is to say so.
        guard let store = MCPTokenStore.shared else {
            regenerateOutcome = .failed(
                MCPTokenStore.Failure.applicationSupportUnavailable.localizedDescription
            )
            return
        }
        do {
            try store.rotate()
            regenerateOutcome = .done
            copiedCommand = false
            // The request path re-reads the file per request, so live clients
            // start failing with 401 without a restart. The listener is only
            // restarted so a server that had failed closed on an unsecurable
            // token gets a chance to come back.
            MCPServerManager.shared.applySettingsChange()
        } catch {
            regenerateOutcome = .failed(error.localizedDescription)
        }
    }

    // MARK: - What this costs you

    private var exposureCard: some View {
        SettingsCard(icon: "eye", title: "What a connected client can see") {
            MCPFact("rectangle.stack", "Every tab open in Cherry, with its title and address.")
            MCPFact("doc.text", "The readable text of a page you have on screen.")
            MCPFact("clock.arrow.circlepath", "Your browsing history, by title and address.")
            MCPFact("bookmark", "Your bookmarks, and the folders you filed them in.")
            MCPFact("plus.rectangle.on.rectangle", "It can also open a URL in a new tab, which changes what is on your screen.")

            Divider()

            MCPFact("eye.slash", "Private windows are never visible, and Cherry never recorded history from them.")
            MCPFact("lock", "Saved passwords are not reachable through these tools.")
        }
    }

    private var reachCard: some View {
        SettingsCard(icon: "lock.shield", title: "What the token protects, and what it does not") {
            MCPBodyText(
                "The token stops any local caller that does not have it. The one that matters is a web page: "
                    + "without a token, a site you visit could run fetch on http://127.0.0.1:\(settings.mcpServerPort)/mcp "
                    + "and read your browsing from inside your own browser. The token closes that."
            )

            MCPBodyText(
                "It is not protection from software already running under your account. Anything running as you "
                    + "can read the token file, and could read Cherry's stored history and bookmarks directly "
                    + "whether this switch is on or off."
            )

            MCPBodyText(
                "The server listens on 127.0.0.1 only. Nothing else on your network can reach it."
            )

            Divider()

            MCPBodyText(
                "Cherry has to be running. Closing the last window quits Cherry, and the server goes with it, so "
                    + "a client will report that it could not connect until you open Cherry again."
            )
        }
    }

    // MARK: - Clock

    /// Keep `now` fresh for as long as the pane is claiming a client is
    /// connected, then stop.
    ///
    /// Not a `TimelineView`: the pane would then redraw once a second forever,
    /// for a line of text that is only precise inside a ten-second window. This
    /// ticks only while that window is open, and is restarted by `.task(id:)`
    /// the moment another request lands.
    private func tickWhileActive() async {
        guard let lastActivity = manager.lastActivity else { return }
        while !Task.isCancelled,
              Date().timeIntervalSince(lastActivity) < MCPServerPresentation.activityWindow {
            now = Date()
            try? await Task.sleep(for: .seconds(1))
        }
        if !Task.isCancelled { now = Date() }
    }
}

// MARK: - Text

/// Supporting copy that still clears 4.5:1 in both appearances.
///
/// Not `.secondary`: `NSColor.secondaryLabelColor` measures 3.95:1 on this
/// pane's surface in light mode, and none of the sentences on this pane are
/// optional reading. See `MCPStatusPalette`.
private struct MCPBodyText: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(MCPStatusPalette.supporting)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A line the user is meant to read before acting, in the measured status red.
private struct MCPNoticeText: View {
    let text: String
    let tone: MCPServerPresentation.Tone

    init(_ text: String, tone: MCPServerPresentation.Tone) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tone.color)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(tone.titleColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One "this is what it can reach" line: a glyph and a sentence.
private struct MCPFact: View {
    let symbol: String
    let text: String

    init(_ symbol: String, _ text: String) {
        self.symbol = symbol
        self.text = text
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(MCPStatusPalette.supporting)
                .frame(width: 15, height: 15)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
