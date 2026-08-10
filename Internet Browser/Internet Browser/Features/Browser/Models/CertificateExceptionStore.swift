//
//  CertificateExceptionStore.swift
//  Cherry Browser
//
//  The whole scope of "Continue anyway", in one file.
//
//  ## What an exception is, and what it is not
//
//  It is one host and one port, held in memory, for as long as this process
//  runs. It is not a site, not a wildcard, not a preference, and not a file.
//  There is deliberately no `save`, no `UserDefaults` key and no Keychain item
//  anywhere in this type: an exception that could outlive the app is an
//  exception the user would never be asked about again, and the certificate
//  interstitial promises the opposite in writing.
//
//  ## Private windows
//
//  A private window's exceptions live in a second set that
//  `forgetPrivateExceptions()` empties when the last private window closes.
//  They are also never consulted for a normal tab and never promoted into the
//  session set: proceeding past a warning in a private window must not change
//  what a normal window trusts, or the private window has leaked a decision.
//
//  Normal exceptions are deliberately NOT consulted for a private tab either.
//  The direction people worry about is the private window leaking outward, but
//  the reverse also matters: a private window should present the same warnings
//  a fresh browser would.
//

import Foundation

@Observable
final class CertificateExceptionStore {

    static let shared = CertificateExceptionStore()

    struct Key: Hashable {
        let host: String
        let port: Int

        init(host: String, port: Int) {
            // Hosts are compared case-insensitively and with the same folding
            // the rest of Cherry uses, so `EXPIRED.badssl.com` cannot be a
            // second, separately-trusted spelling of a host already trusted.
            self.host = HostNormalizer.foldedASCII(host)
            self.port = port
        }
    }

    /// Exceptions made in normal windows. Cleared only by quitting Cherry.
    private var sessionExceptions: Set<Key> = []
    /// Exceptions made in private windows, dropped when private browsing ends.
    private var privateExceptions: Set<Key> = []

    private init() {}

    func allows(_ key: Key, isPrivate: Bool) -> Bool {
        isPrivate ? privateExceptions.contains(key) : sessionExceptions.contains(key)
    }

    /// Records the user's decision. `isPrivate` picks which set it lands in;
    /// there is no path that writes into both.
    func allow(_ key: Key, isPrivate: Bool) {
        if isPrivate {
            privateExceptions.insert(key)
        } else {
            sessionExceptions.insert(key)
        }
    }

    /// Called when private browsing ends (the last private window closes, or
    /// the window leaves private mode). Normal exceptions are untouched.
    func forgetPrivateExceptions() {
        privateExceptions.removeAll()
    }

    /// Test seam, and the answer to "how do I undo this without quitting":
    /// there is one, and it clears everything.
    func forgetAllExceptions() {
        sessionExceptions.removeAll()
        privateExceptions.removeAll()
    }

    var exceptionCount: (session: Int, private: Int) {
        (sessionExceptions.count, privateExceptions.count)
    }
}
