//
//  PasswordsSettingsView.swift
//  Cherry Browser
//

import SwiftUI
import AppKit

struct PasswordsSettingsView: View {
    @State private var repository = PasswordRepository.shared
    @State private var settings = SettingsManager.shared
    @State private var searchText = ""
    @State private var selectedID: UUID?
    @State private var showAddSheet = false
    @State private var isAuthenticated = false

    private var filteredPasswords: [PasswordItem] {
        if searchText.isEmpty {
            return repository.passwords
        }
        return repository.searchCredentials(query: searchText)
    }

    var body: some View {
        Group {
            if isAuthenticated {
                passwordsContent
            } else {
                authGateView
            }
        }
        .onAppear {
            authenticate()
        }
    }

    private var authGateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("Passwords are locked")
                .font(.headline)

            Text("Authenticate to view your saved passwords")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button("Unlock Passwords") {
                authenticate()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func authenticate() {
        PasswordManager.shared.authenticateWithTouchID(reason: "Access saved passwords") { success in
            isAuthenticated = success
        }
    }

    private var passwordsContent: some View {
        VStack(spacing: 0) {
            // Search + Add bar — fixed height, never resizes
            HStack {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search passwords...", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(6)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)

                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
                .help("Add Password")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .fixedSize(horizontal: false, vertical: true)

            Divider()

            // Password list — takes all remaining space
            if filteredPasswords.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "key")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text(searchText.isEmpty ? "No saved passwords" : "No matching passwords")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredPasswords) { item in
                            PasswordRowView(
                                item: item,
                                isExpanded: selectedID == item.id,
                                requireTouchID: settings.requireTouchIDForViewing,
                                onDelete: { repository.deleteCredential(id: item.id) }
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    selectedID = selectedID == item.id ? nil : item.id
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)

                            Divider()
                                .padding(.leading, 16)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            // Touch ID + Generator settings — fixed height at bottom
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Require Touch ID to auto-fill passwords", isOn: $settings.requireTouchIDForAutoFill)
                Toggle("Require Touch ID to view passwords", isOn: $settings.requireTouchIDForViewing)

                Divider()

                HStack {
                    Text("Password length: \(settings.passwordGeneratorLength)")
                    Slider(value: Binding(
                        get: { Double(settings.passwordGeneratorLength) },
                        set: { settings.passwordGeneratorLength = Int($0) }
                    ), in: 8...40, step: 1)
                }

                Toggle("Include symbols in generated passwords", isOn: $settings.passwordGeneratorIncludeSymbols)
            }
            .padding()
            .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $showAddSheet) {
            AddPasswordSheet { url, username, password in
                repository.addCredential(url: url, username: username, password: password)
            }
        }
    }
}

// MARK: - Password Row

struct PasswordRowView: View {
    let item: PasswordItem
    let isExpanded: Bool
    let requireTouchID: Bool
    let onDelete: () -> Void

    @State private var revealedPassword: String?
    @State private var isEditing = false
    @State private var editUsername: String = ""
    @State private var editPassword: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // Favicon
                if let data = item.faviconData, let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: 16, height: 16)
                        .cornerRadius(2)
                } else {
                    Image(systemName: "globe")
                        .frame(width: 16, height: 16)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.domain)
                        .font(.system(size: 12, weight: .medium))
                    Text(item.username)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("••••••••")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            if isExpanded {
                if isEditing {
                    editView
                } else {
                    expandedView
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var expandedView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            LabeledContent("Website") {
                Text(item.url)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            LabeledContent("Username") {
                HStack {
                    Text(item.username)
                        .font(.system(size: 11))
                        .textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.username, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .help("Copy Username")
                }
            }

            LabeledContent("Password") {
                HStack {
                    if let revealed = revealedPassword {
                        Text(revealed)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                    } else {
                        Text("••••••••••••")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }

                    Button {
                        if revealedPassword != nil {
                            revealedPassword = nil
                        } else {
                            revealPassword()
                        }
                    } label: {
                        Image(systemName: revealedPassword != nil ? "eye.slash" : "eye")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .help(revealedPassword != nil ? "Hide Password" : "Reveal Password")

                    Button {
                        copyPassword()
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .help("Copy Password")
                }
            }

            HStack {
                Spacer()
                Button("Edit") {
                    startEditing()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Delete", role: .destructive, action: onDelete)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.leading, 24)
    }

    @ViewBuilder
    private var editView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            LabeledContent("Website") {
                Text(item.url)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Username") {
                TextField("Username", text: $editUsername)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
            }

            LabeledContent("Password") {
                HStack {
                    TextField("Password", text: $editPassword)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))

                    Button("Generate") {
                        let settings = SettingsManager.shared
                        editPassword = PasswordGenerator.generate(
                            length: settings.passwordGeneratorLength,
                            includeSymbols: settings.passwordGeneratorIncludeSymbols
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    isEditing = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Save") {
                    saveEdits()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(editUsername.isEmpty || editPassword.isEmpty)
            }
        }
        .padding(.leading, 24)
    }

    private func startEditing() {
        editUsername = item.username
        let doEdit = {
            editPassword = PasswordRepository.shared.fetchPassword(for: item.id) ?? ""
            isEditing = true
        }

        if requireTouchID {
            PasswordManager.shared.authenticateWithTouchID(reason: "Edit password for \(item.domain)") { success in
                if success { doEdit() }
            }
        } else {
            doEdit()
        }
    }

    private func saveEdits() {
        PasswordRepository.shared.updateCredential(
            id: item.id,
            username: editUsername,
            password: editPassword
        )
        isEditing = false
        revealedPassword = nil
    }

    private func revealPassword() {
        if requireTouchID {
            PasswordManager.shared.authenticateWithTouchID(reason: "View password for \(item.domain)") { success in
                if success {
                    revealedPassword = PasswordRepository.shared.fetchPassword(for: item.id)
                }
            }
        } else {
            revealedPassword = PasswordRepository.shared.fetchPassword(for: item.id)
        }
    }

    private func copyPassword() {
        let doCopy = {
            if let password = PasswordRepository.shared.fetchPassword(for: item.id) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(password, forType: .string)
            }
        }

        if requireTouchID {
            PasswordManager.shared.authenticateWithTouchID(reason: "Copy password for \(item.domain)") { success in
                if success { doCopy() }
            }
        } else {
            doCopy()
        }
    }
}

// MARK: - Add Password Sheet

struct AddPasswordSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var username = ""
    @State private var password = ""
    @State private var showGenerated = false

    let onSave: (String, String, String) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Add Password")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                TextField("Website URL", text: $url)
                    .textFieldStyle(.roundedBorder)

                TextField("Username", text: $username)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)

                    Button("Generate") {
                        let settings = SettingsManager.shared
                        password = PasswordGenerator.generate(
                            length: settings.passwordGeneratorLength,
                            includeSymbols: settings.passwordGeneratorIncludeSymbols
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save") {
                    var finalURL = url
                    if !finalURL.contains("://") {
                        finalURL = "https://\(finalURL)"
                    }
                    onSave(finalURL, username, password)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(url.isEmpty || username.isEmpty || password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
