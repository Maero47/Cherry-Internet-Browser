//
//  PasswordManager.swift
//  Cherry Browser
//

import AppKit
import Foundation
import LocalAuthentication
import Observation
import WebKit

@Observable
final class PasswordManager {
    static let shared = PasswordManager()

    private let repository = PasswordRepository.shared
    private let settings = SettingsManager.shared

    // Login form detection state
    var loginFormDetected: Bool = false
    var matchingCredentials: [PasswordItem] = []

    // Captured credentials (waiting for navigation to confirm login)
    private var capturedURL: String?
    private var capturedUsername: String?
    private var capturedPassword: String?

    // Save prompt state
    var pendingSaveURL: String?
    var pendingSaveUsername: String?
    var pendingSavePassword: String?
    var showSavePrompt: Bool = false

    var pendingSaveDomain: String {
        if let urlStr = pendingSaveURL, let url = URL(string: urlStr), let host = url.host {
            return host
        }
        return pendingSaveURL ?? ""
    }

    /// How long one successful authentication covers further access. A single
    /// Touch ID at launch used to unlock reveal/copy/edit/autofill for the
    /// whole process lifetime — `invalidateAuthSession()` had no caller.
    private static let authSessionDuration: TimeInterval = 5 * 60

    /// When the current authentication expires. `nil` means locked.
    private var authSessionExpiry: Date?

    private var isAuthSessionValid: Bool {
        guard let expiry = authSessionExpiry else { return false }
        return expiry > Date()
    }

    /// Outstanding `evaluatePolicy` calls. The LocalAuthentication panel is
    /// presented by a system process and takes focus, so `didResignActive`
    /// fires *while the user is authenticating*. Anything that re-locks on
    /// deactivation must skip it for the lifetime of a prompt, or the prompt
    /// throws away its own result: the view swaps back to the lock screen and
    /// the success handler writes into a row that no longer exists.
    private var promptCount = 0

    /// When the outstanding prompts stop being believed. `evaluatePolicy` can
    /// fail to call back at all — the panel left up indefinitely, the context
    /// invalidated — and a `promptCount` that never returns to zero would
    /// suppress every re-lock for the rest of the process lifetime, leaving an
    /// unlocked vault permanently unlockable-again. Suppression expires.
    private var promptDeadline: Date?
    private static let promptSuppressionWindow: TimeInterval = 2 * 60

    /// True while any authentication prompt is on screen. Observable, and
    /// shared — the previous `@State` flag in `PasswordsSettingsView` covered
    /// only the initial unlock, leaving the reveal/copy/edit prompts to
    /// discard their own authentication.
    var isPrompting: Bool {
        guard promptCount > 0, let deadline = promptDeadline else { return false }
        return deadline > Date()
    }

    private init() {
        // Leaving the app, or the machine going to sleep, re-locks the vault:
        // an unattended Mac must not still be one click from revealing a
        // secret because someone authenticated ten minutes ago.
        let center = NotificationCenter.default
        for name in [NSApplication.didResignActiveNotification, NSApplication.willTerminateNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self, !self.isPrompting else { return }
                self.invalidateAuthSession()
            }
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // Sleep is not a prompt artefact — always re-lock.
                self?.invalidateAuthSession()
            }
        }
    }

    // MARK: - Touch ID

    /// - Parameter requireFresh: pass `true` for anything that hands the
    ///   plaintext secret to the user (reveal, copy, edit) — those always
    ///   prompt, never ride an existing session.
    func authenticateWithTouchID(
        reason: String,
        requireFresh: Bool = false,
        completion: @escaping (Bool) -> Void
    ) {
        if !requireFresh, isAuthSessionValid {
            completion(true)
            return
        }

        let context = LAContext()
        context.localizedFallbackTitle = "Use Password"
        // Never let a prompt satisfy itself from macOS's own recent-auth grace
        // period when the caller asked for a fresh check.
        if requireFresh { context.touchIDAuthenticationAllowableReuseDuration = 0 }
        var error: NSError?

        // Use deviceOwnerAuthentication which tries Touch ID first, then falls back
        // to the system password if Touch ID fails or is unavailable.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // FAIL CLOSED. `.deviceOwnerAuthentication` already includes the
            // device-password fallback, so reaching here means the machine
            // offers no way to prove who is sitting at it — which is not a
            // reason to hand over the password vault.
            print("Password authentication unavailable: \(error?.localizedDescription ?? "unknown reason")")
            completion(false)
            return
        }

        promptCount += 1
        promptDeadline = Date().addingTimeInterval(Self.promptSuppressionWindow)
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
            DispatchQueue.main.async { [self] in
                if success {
                    authSessionExpiry = Date().addingTimeInterval(Self.authSessionDuration)
                }
                // Decremented only after the session is recorded, so a
                // `didResignActive` racing the panel's dismissal can't undo it.
                promptCount = max(0, promptCount - 1)
                if promptCount == 0 { promptDeadline = nil }
                completion(success)
            }
        }
    }

    /// Clears the authentication session so next access requires re-authentication
    func invalidateAuthSession() {
        authSessionExpiry = nil
    }

    // MARK: - Auto-Fill

    func fillCredentials(_ credential: PasswordItem, in webView: WKWebView?) {
        guard let webView else { return }
        guard Self.credential(credential, matchesLivePageOf: webView) else { return }

        let doFill = { [self] in
            // Re-checked here, not just above: the Touch ID prompt is async and
            // the page can navigate (or be navigated, by script) while it is up.
            // This is the last instruction before the secret enters the page.
            guard Self.credential(credential, matchesLivePageOf: webView) else { return }
            guard let password = repository.fetchPassword(for: credential.id) else { return }
            // The same origin is re-asserted inside the injected script, so
            // the check also holds in the web content process at the moment
            // the fields are written — evaluateJavaScript is async IPC and
            // isn't pinned to the document checked above.
            let js = PasswordAutoFillScripts.autoFillScript(
                username: credential.username,
                password: password,
                expectedOrigin: Self.expectedOrigin(of: webView)
            )
            webView.evaluateJavaScript(js) { _, error in
                if let error {
                    print("Auto-fill error: \(error)")
                }
            }
            repository.markUsed(id: credential.id)
        }

        if settings.requireTouchIDForAutoFill {
            authenticateWithTouchID(reason: "Auto-fill password for \(credential.domain)") { success in
                if success { doFill() }
            }
        } else {
            doFill()
        }
    }

    /// True when the page currently loaded in `webView` really belongs to the
    /// site the credential was saved for. `webView.url` is WebKit's committed
    /// main-frame URL — it cannot be forged by page script, unlike the origin
    /// the detection message used to carry.
    /// `scheme://host` of the page currently loaded, in the form the injected
    /// script compares against (`location.protocol + '//' + location.hostname`
    /// — hostname, so a non-default port doesn't turn the guard into a silent
    /// autofill failure).
    private static func expectedOrigin(of webView: WKWebView) -> String? {
        guard let url = webView.url,
              let scheme = url.scheme.map(HostNormalizer.foldedASCII),
              let host = url.host, !host.isEmpty else { return nil }
        return "\(scheme)://\(HostNormalizer.foldedASCII(host))"
    }

    private static func credential(_ credential: PasswordItem, matchesLivePageOf webView: WKWebView) -> Bool {
        guard let liveHost = webView.url?.host, !liveHost.isEmpty else { return false }
        guard let scheme = webView.url?.scheme.map(HostNormalizer.foldedASCII),
              scheme == "https" || scheme == "http" else { return false }
        let credentialHost = URL(string: credential.url)?.host ?? credential.url
        guard !credentialHost.isEmpty else { return false }
        return HostNormalizer.hostsAreRelated(liveHost, credentialHost)
    }

    // MARK: - Page Events

    func onLoginFormDetected(url: URL) {
        loginFormDetected = true
        matchingCredentials = repository.credentials(for: url)
    }

    func onCredentialsCaptured(url: String, username: String, password: String) {
        // Store credentials but don't show the banner yet —
        // wait for navigation to confirm the login actually went through
        capturedURL = url
        capturedUsername = username
        capturedPassword = password
    }

    func savePromptAccepted() {
        guard let url = pendingSaveURL,
              let username = pendingSaveUsername,
              let password = pendingSavePassword else { return }

        repository.addCredential(url: url, username: username, password: password)
        clearPendingSave()
    }

    func savePromptDismissed() {
        clearPendingSave()
    }

    /// Called when the page navigates after login — this is when we show the save prompt
    func onNavigationAfterCapture() {
        guard let url = capturedURL,
              let username = capturedUsername,
              let password = capturedPassword else { return }

        // Clear captured data
        capturedURL = nil
        capturedUsername = nil
        capturedPassword = nil

        // Check if we already have this credential
        if let urlObj = URL(string: url) {
            let existing = repository.credentials(for: urlObj)
            let alreadySaved = existing.contains { item in
                item.username == username && repository.fetchPassword(for: item.id) == password
            }
            if alreadySaved { return }

            // Check if it's an update to an existing username
            let sameUser = existing.first { $0.username == username }
            if let sameUser {
                repository.updateCredential(id: sameUser.id, password: password)
                return
            }
        }

        pendingSaveURL = url
        pendingSaveUsername = username
        pendingSavePassword = password
        showSavePrompt = true
    }

    func resetForNavigation() {
        loginFormDetected = false
        matchingCredentials = []
    }

    private func clearPendingSave() {
        pendingSaveURL = nil
        pendingSaveUsername = nil
        pendingSavePassword = nil
        showSavePrompt = false
    }
}
