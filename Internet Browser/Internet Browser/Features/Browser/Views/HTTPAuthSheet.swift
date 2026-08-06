//
//  HTTPAuthSheet.swift
//  Cherry Browser
//
//  The sheet a `401 WWW-Authenticate` puts on the tab's own window.
//
//  ## Why a sheet on this window and not an app alert
//
//  The same reason `WebActionConsentSheet` is: the question names a host that
//  one particular tab is loading, and a dialog that appears over a different
//  window is a dialog answered about the wrong thing.
//
//  ## What Cancel does
//
//  It declines the challenge, which leaves the tab on the page it was already
//  showing. It does not navigate, it does not blank the page, and it does not
//  raise the failure surface: a cancelled sign-in is a decision, not a failure
//  to explain. A tab with nothing behind it goes to the new-tab page rather
//  than to a white rectangle. See `WebViewWrapper.Coordinator`.
//
//  ## The vault
//
//  Reachable, but only where it is allowed to be. In a normal window a saved
//  credential for this host can be picked from a menu, and "Remember" files a
//  new one after the sign-in actually works. In a private window neither
//  control exists: the vault is not read and nothing is written, which is the
//  same rule password autofill already follows for private tabs.
//

import SwiftUI

struct HTTPAuthSheet: View {

    let prompt: HTTPAuthPrompt
    let savedCredentials: [PasswordItem]
    /// Resolves a saved item to its secret, gated by whatever the password
    /// settings require. Never called in a private window.
    let revealSaved: (PasswordItem, @escaping (String?) -> Void) -> Void
    let onSubmit: (String, String, Bool) -> Void
    let onCancel: () -> Void

    @State private var user = ""
    @State private var password = ""
    @State private var remember = false
    @FocusState private var userFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if prompt.previouslyFailed { rejectedNotice }
            fields
            if !prompt.isPrivate && !savedCredentials.isEmpty { savedMenu }
            if !prompt.isPrivate { rememberToggle } else { privateNotice }
            buttons
        }
        .padding(22)
        .frame(width: 420)
        .onAppear { userFieldFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(prompt.host) is asking for a user name and password")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "person.badge.key")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(SettingsManager.shared.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                // The host, verbatim and not interpolated into a markdown
                // literal: it is the only thing on this sheet that tells the
                // user who they are about to hand a password to.
                Text(verbatim: "Sign in to \(prompt.host)")
                    .font(.system(size: 15, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let realm = prompt.realm {
                    // The server's own words, quoted so it reads as the
                    // server's claim and not as Cherry's.
                    Text(verbatim: "The server asked for: “\(realm)”")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var rejectedNotice: some View {
        Text("That user name and password were not accepted. Try again.")
            .font(.system(size: 12))
            .foregroundStyle(FailurePalette.caution)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("User name", text: $user)
                .textFieldStyle(.roundedBorder)
                .focused($userFieldFocused)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
        }
    }

    private var savedMenu: some View {
        Menu {
            ForEach(savedCredentials) { item in
                Button(item.username.isEmpty ? item.domain : item.username) {
                    revealSaved(item) { secret in
                        guard let secret else { return }
                        user = item.username
                        password = secret
                    }
                }
            }
        } label: {
            Label("Use a saved password", systemImage: "key")
                .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var rememberToggle: some View {
        Toggle(isOn: $remember) {
            Text("Remember this password in Cherry")
                .font(.system(size: 12))
        }
        .toggleStyle(.checkbox)
    }

    private var privateNotice: some View {
        Text("This is a private window, so Cherry will not save this password and does not read your saved ones.")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Spacer()
            // Escape cancels, and cancelling leaves the tab where it was.
            Button("Cancel", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button("Sign In", action: submit)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(user.isEmpty && password.isEmpty)
        }
    }

    private func submit() {
        guard !(user.isEmpty && password.isEmpty) else { return }
        // `remember` cannot be true in a private window: the toggle that sets
        // it is not built there. The write path checks again anyway.
        onSubmit(user, password, remember && !prompt.isPrivate)
    }
}
