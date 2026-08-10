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
//  - That Cherry has to be running with a window open, and that closing the
//    last window takes the server down with it. Without this a client just
//    reports "failed to connect".
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

    /// Which client the registration card is currently explaining. One card,
    /// one client at a time: the two flows differ in exactly the way the copy
    /// has to dwell on (inline header versus environment variable), and
    /// showing both at once would be two near-identical walls of text with
    /// the one difference that matters buried between them.
    @State private var registrationClient: RegistrationClient = .claudeCode

    private enum RegistrationClient: String, CaseIterable {
        case claudeCode = "Claude Code"
        case codex = "Codex"
    }

    /// The command most recently copied, so each Copy button can say "Copied"
    /// about its own command and not about a neighbour's.
    @State private var copiedCommand: String?
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
            subtitle: "Lets Claude Code or Codex use this browser."
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
        .accessibilityLabel(Self.spokenStatus(state))
    }

    /// Everything in the status block, spoken.
    ///
    /// The first version combined the children and then replaced the label with
    /// title + detail, which silently dropped `remedy` and `technical` — in all
    /// five cannot-run states, where they are the only actionable content and
    /// the only place the path the user has to repair appears. A sighted user
    /// could read it and a VoiceOver user could not.
    static func spokenStatus(_ state: MCPServerPresentation) -> String {
        var spoken = "MCP server status: \(state.title). \(state.detail)"
        if let remedy = state.remedy {
            spoken += " \(remedy)"
        }
        if let technical = state.technical {
            spoken += " Reported by the system: \(technical)"
        }
        return spoken
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
            title: "Register a coding agent",
            subtitle: "Both talk to the same server, port, and token."
        ) {
            Picker("Client", selection: $registrationClient) {
                ForEach(RegistrationClient.allCases, id: \.self) { client in
                    Text(client.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch registrationClient {
            case .claudeCode: claudeRegistration
            case .codex: codexRegistration
            }

            HStack(spacing: 8) {
                Button(revealToken ? "Hide Token" : "Show Token") {
                    revealToken.toggle()
                    copiedCommand = nil
                }
                .controlSize(.small)
                .help(revealToken
                      ? "Go back to the form that reads the token from its file"
                      : "Put the token itself on screen")

                Spacer(minLength: 0)
            }

            if revealToken {
                MCPNoticeText(
                    "The token is on screen. Anyone looking at this window, and any screen recording running "
                        + "right now, can read it.",
                    tone: .failure
                )
            }
        }
    }

    /// Claude Code takes the secret inline, as a header, so this really is one
    /// command: run it and you are done.
    @ViewBuilder
    private var claudeRegistration: some View {
        MCPBodyText("Run this once in Terminal:")

        commandBlock(claudeCommand, label: "Claude Code registration command")
        copyRow(for: claudeCommand)

        if !revealToken {
            MCPBodyText(
                "This form reads the token out of its file when you run it, so the secret never appears on "
                    + "screen or in your shell history."
            )
        }

        MCPBodyText("Cherry has been verified against Claude Code. Claude Desktop is untested.")
    }

    /// Codex never takes the token. Its `--bearer-token-env-var` flag takes the
    /// NAME of an environment variable, and Codex reads that variable from its
    /// own environment when it connects, not when it registers. So the flow is
    /// honestly two steps, and the pane says why rather than pretending the
    /// second command is the whole story: a variable exported once, in the
    /// shell where the add was typed, dies with that shell, and from then on
    /// registration looks fine while every connection fails to authenticate.
    @ViewBuilder
    private var codexRegistration: some View {
        MCPBodyText(
            "Codex is different: the command below hands it the name of an environment variable, "
                + "\(MCPServerManager.codexTokenEnvironmentVariable), and Codex reads that variable itself "
                + "every time it connects. The variable therefore has to exist in every shell you run Codex "
                + "from, which makes this two steps."
        )

        MCPBodyText("1. Add this line to your shell profile (for example ~/.zshrc), then open a new terminal:")
        commandBlock(codexProfileLine, label: "Shell profile line for the Codex token")
        copyRow(for: codexProfileLine)

        MCPBodyText("2. In that new terminal, register Cherry:")
        commandBlock(codexAddCommand, label: "Codex registration command")
        copyRow(for: codexAddCommand)

        MCPNoticeText(
            "Typing the export once instead of putting it in your profile seems to work: registration "
                + "succeeds. But the variable dies with that shell, and every Codex session started after it "
                + "fails to authenticate against Cherry. The profile is what makes the variable exist "
                + "wherever Codex runs.",
            tone: .failure
        )

        if !revealToken {
            MCPBodyText(
                "The profile line reads the token out of its file each time a shell starts, so the secret is "
                    + "not written into your profile, your history, or this screen. It does sit in the "
                    + "environment of every shell you open afterwards, where anything you start from that "
                    + "shell can read it. That is the trade the Codex flow makes."
            )
        }

        MCPBodyText(
            "What has been verified on a real codex command line: registration with exactly this command "
                + "succeeds, and Codex stores the address and the variable name. A live Codex session "
                + "reading Cherry has not been tested."
        )
    }

    private func commandBlock(_ command: String, label: String) -> some View {
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
            .accessibilityLabel(label)
    }

    private func copyRow(for command: String) -> some View {
        HStack(spacing: 8) {
            Button(copiedCommand == command ? "Copied" : "Copy Command") { copy(command) }
                .controlSize(.small)
            Spacer(minLength: 0)
        }
    }

    private var claudeCommand: String {
        manager.registrationCommand(includingToken: revealToken)
    }

    private var codexProfileLine: String {
        manager.codexProfileLine(includingToken: revealToken)
    }

    private var codexAddCommand: String {
        manager.codexRegistrationCommand()
    }

    private func copy(_ command: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
        copiedCommand = command
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
            copiedCommand = nil
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

    /// The pane's exhaustive answer to "what does this give away". Every line
    /// below was checked against `MCPBrowserBridge` and `MCPToolPayloads`, not
    /// against the tool descriptions, because the descriptions are written for
    /// the model and the payloads are what actually leaves the machine.
    private var exposureCard: some View {
        SettingsCard(icon: "eye", title: "What a connected client can see") {
            MCPFact(
                "rectangle.stack",
                "Every tab open in every window: title, address, which window it is in, which window is "
                    + "in front, and whether each tab is selected, pinned, asleep, or still loading."
            )
            // This sentence used to read "a page you have on screen", which was
            // false by one to two orders of magnitude. `read_page` takes a
            // tab_id from list_tabs and reaches ANY tab in ANY non-private
            // window; the gates below it are only sleeping / cherry:// page /
            // new-tab page / PDF / never-displayed.
            MCPFact(
                "doc.text",
                "The readable text of any loaded page, not only the one in front of you. Background tabs, "
                    + "tabs in windows behind this one, and tabs on other Spaces can all be read. Tabs that "
                    + "are asleep or that you have never opened cannot."
            )
            MCPFact(
                "clock.arrow.circlepath",
                "Your browsing history: title, address, the exact date and time of each visit, and how many "
                    + "times you have been there."
            )
            MCPFact(
                "bookmark",
                "Your bookmarks: title, address, the folder you filed each one in, whether it is on the "
                    + "bookmarks bar, and when you saved it."
            )
            MCPFact(
                "plus.rectangle.on.rectangle",
                "It can also open a URL in a new tab, which changes what is on your screen. Only http and "
                    + "https, at most five a minute, and in the background unless it asks otherwise."
            )

            Divider()

            MCPFact(
                "eye.slash",
                "Private windows are never visible. Their tabs cannot be listed or read, and Cherry never "
                    + "recorded history from them."
            )
            MCPFact("lock", "Your saved passwords are not reachable through any of these tools.")
            MCPFact(
                "hand.raised",
                "Nothing can click, type, scroll, fill in a form, or run scripts on a page. Opening a tab is "
                    + "the only thing that changes anything."
            )
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

            // This used to say Cherry keeps answering with no window open, and
            // that reading could therefore happen with no sign of it. Both were
            // true when they were written: closing the last window leaves the
            // process alive, and the listener stayed bound to a browser that
            // had no view left to show an indicator in.
            // `MCPServerManager.observeWindowLifecycle` now closes the socket
            // with the last window and reopens it with the next one, using
            // `TabManager`'s own liveness rule — so the limit below is real
            // again, and the warning it replaces no longer describes anything.
            MCPBodyText(
                "Cherry has to be running with a window open. Close your last window and the server stops "
                    + "answering a moment later, whether or not Cherry itself quits; open a window and it "
                    + "starts again. A window minimised in the Dock still counts, and so does hiding "
                    + "Cherry with Command H — in both, your tabs are still there and so is the indicator "
                    + "in the toolbar."
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
