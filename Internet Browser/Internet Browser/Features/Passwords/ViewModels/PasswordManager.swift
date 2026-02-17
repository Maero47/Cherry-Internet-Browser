//
//  PasswordManager.swift
//  Cherry Browser
//

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

    // Authentication session: once authenticated, stays valid for the entire app session
    private var isAuthSessionValid: Bool = false

    private init() {}

    // MARK: - Touch ID

    func authenticateWithTouchID(reason: String, completion: @escaping (Bool) -> Void) {
        // If recently authenticated, skip the prompt
        if isAuthSessionValid {
            completion(true)
            return
        }

        let context = LAContext()
        context.localizedFallbackTitle = "Use Password"
        var error: NSError?

        // Use deviceOwnerAuthentication which tries Touch ID first, then falls back
        // to system password if Touch ID fails or is unavailable
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No authentication available at all, allow access
            completion(true)
            return
        }

        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
            DispatchQueue.main.async { [self] in
                if success {
                    isAuthSessionValid = true
                }
                completion(success)
            }
        }
    }

    /// Clears the authentication session so next access requires re-authentication
    func invalidateAuthSession() {
        isAuthSessionValid = false
    }

    // MARK: - Auto-Fill

    func fillCredentials(_ credential: PasswordItem, in webView: WKWebView?) {
        guard let webView else { return }

        let doFill = { [self] in
            guard let password = repository.fetchPassword(for: credential.id) else { return }
            let js = PasswordAutoFillScripts.autoFillScript(username: credential.username, password: password)
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
