//
//  NavigationFailure.swift
//  Cherry Browser
//
//  What went wrong when a page did not load, in the user's language.
//
//  ## Why this is a model and not a string in the delegate
//
//  `didFail` hands us an `Error`. Almost every browser bug in this area comes
//  from reading only half of it: the CODE alone is ambiguous (`-999` is both
//  "you pressed Stop" and "a second navigation replaced the first"), and the
//  DOMAIN alone says nothing. So the mapping reads both, it lives in one place,
//  and it is a value type a test can build without a web view.
//
//  ## The families, and why an unrecognised error is not one of them
//
//  Seven failures have a name the user can act on, and they are named here.
//  Everything else falls to `.unrecognised`, which does NOT invent an
//  explanation: it carries the system's own sentence, the domain and the code,
//  and the surface says plainly that Cherry has no better account of it. A
//  browser that guesses "check your connection" at a TLS handshake failure has
//  told the user something false and sent them to fix the wrong thing.
//
//  ## Not every failure is a screen
//
//  Two of these are bookkeeping, not events:
//
//  * `WebKitErrorDomain` 102 (frame load interrupted) is what a navigation that
//    turned into a download, or was cancelled by a policy decision, looks like
//    from here. Cherry's own `decidePolicyFor` returns `.cancel` for Focus Mode
//    blocks and for non-web schemes it hands to `NSWorkspace`, and each of those
//    arrives here as a "failure" of a navigation that did exactly what it was
//    told to.
//  * `NSURLErrorCancelled` (-999) fires on every ordinary interruption: clicking
//    a link while a page is still loading, a redirect, a scripted
//    `location.replace`.
//
//  `isSilent(whileStillLoading:)` is the single expression of that: a
//  cancellation with another navigation already in flight is invisible, a
//  cancellation with nothing in flight is the user pressing Stop and gets a
//  surface, because otherwise they are looking at a half-drawn page with no
//  explanation of why it stopped.
//

import Foundation
import WebKit

struct NavigationFailure: Equatable {

    /// The failures with a name, plus the honest fallback.
    enum Family: Equatable {
        case offline
        case hostNotFound
        case connectionRefused
        case connectionLost
        case timedOut
        case tooManyRedirects
        case cancelled
        case unsupportedScheme
        /// A port browsers refuse to open. Not a network failure at all: the
        /// request is never sent.
        case blockedPort
        /// A TLS failure that did not come through the certificate
        /// interstitial (see `CertificateWarning`) — a protocol-level
        /// handshake failure rather than a certificate Cherry can describe.
        case secureConnectionFailed
        /// A `webkit-extension://` page belonging to no loaded extension —
        /// removed, disabled, or a URL restored from a session in which it
        /// still existed. Not a network failure: nothing was requested, and no
        /// web view in the process could have served it.
        case extensionPageUnavailable
        case unrecognised
    }

    let family: Family
    /// The address the user asked for. Kept even when WebKit reverts the web
    /// view to the previous page, because it is the thing they need to see and
    /// edit.
    let url: URL?
    /// The system's own sentence. Shown only for `.unrecognised`, where it is
    /// the most truthful thing available.
    let systemDescription: String
    let domain: String
    let code: Int

    // MARK: - Reading an Error properly

    /// `WebKitErrorDomain`. Not exported as a constant by WebKit on macOS.
    static let webKitErrorDomain = "WebKitErrorDomain"
    /// `WebKitErrorFrameLoadInterruptedByPolicyChange`.
    static let webKitFrameLoadInterrupted = 102
    /// `WebKitErrorPlugInWillHandleLoad` — the load was handed off, not lost.
    static let webKitPlugInWillHandleLoad = 204
    /// `WebKitErrorCannotShowURL`.
    static let webKitCannotShowURL = 101

    /// Builds a failure from what WebKit reported.
    ///
    /// `nil` means "this is not a failure the user should be told about":
    /// the two WebKit hand-off codes above. Cancellation is NOT filtered here —
    /// it depends on whether another navigation is already running, which only
    /// the caller can see. See `isSilent(whileStillLoading:)`.
    static func make(from error: Error, requestedURL: URL?) -> NavigationFailure? {
        let nsError = error as NSError
        let domain = nsError.domain
        let code = nsError.code

        if domain == webKitErrorDomain,
           code == webKitFrameLoadInterrupted || code == webKitPlugInWillHandleLoad {
            return nil
        }

        // The failing URL is on the error itself for every URL-loading failure,
        // and it is more precise than the tab's idea of where it was going: a
        // redirect chain fails at the URL it reached, not the one that was typed.
        let failingURL = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? requestedURL

        // A −1008 on an extension URL is the one failure whose family cannot be
        // read from domain and code alone: `NSURLErrorResourceUnavailable` is
        // generic, but on a `webkit-extension://` URL it means precisely that
        // no loaded extension serves that page. Cherry cancels those before the
        // load (see `extensionPageUnavailable(for:)`); this catches any that
        // still reach WebKit, so the user is never shown "<random uuid> did not
        // load" for a page of the browser's own.
        if code == NSURLErrorResourceUnavailable, ExtensionPageRouting.isExtensionURL(failingURL) {
            return extensionPageUnavailable(for: failingURL ?? requestedURL ?? URL(string: "\(ExtensionPageRouting.scheme)://")!)
        }

        return NavigationFailure(
            family: family(domain: domain, code: code),
            url: failingURL,
            systemDescription: nsError.localizedDescription,
            domain: domain,
            code: code
        )
    }

    // MARK: - Blocked ports
    //
    // WebKit refuses to open a connection to a port that belongs to another
    // protocol, and it does it BELOW the navigation delegate: `didFail` is
    // never called, no error is produced, and the tab is simply left on
    // `about:blank`. Measured, not assumed — `http://127.0.0.1:1` was driven
    // through Cherry and produced no delegate callback of any kind, only a
    // blank page and an omnibox that had quietly become `about:blank`.
    //
    // That is the exact failure mode this whole feature exists to end, so the
    // check is made here, before the load, and the user gets a screen.

    /// The WHATWG Fetch "bad ports" list, which is what WebKit and Chromium
    /// both implement. Applied only to main-frame http(s) navigations, so no
    /// subresource and no other scheme is affected by it.
    static let blockedPorts: Set<Int> = [
        1, 7, 9, 11, 13, 15, 17, 19, 20, 21, 22, 23, 25, 37, 42, 43, 53, 69, 77,
        79, 87, 95, 101, 102, 103, 104, 109, 110, 111, 113, 115, 117, 119, 123,
        135, 137, 139, 143, 161, 179, 389, 427, 465, 512, 513, 514, 515, 526,
        530, 531, 532, 540, 548, 554, 556, 563, 587, 601, 636, 989, 990, 993,
        995, 1719, 1720, 1723, 2049, 3659, 4045, 4190, 5060, 5061, 6000, 6566,
        6665, 6666, 6667, 6668, 6669, 6679, 6697, 10080,
    ]

    /// A failure for a main-frame navigation to a port no browser will open,
    /// or `nil` when the address is fine.
    static func blockedPortFailure(for url: URL) -> NavigationFailure? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let port = url.port, blockedPorts.contains(port) else { return nil }
        return NavigationFailure(
            family: .blockedPort,
            url: url,
            systemDescription: "",
            domain: NSURLErrorDomain,
            code: NSURLErrorUnsupportedURL
        )
    }

    // MARK: - Extension pages with no extension

    /// A `webkit-extension://` page that no loaded extension can serve.
    ///
    /// Built by Cherry before the load rather than read off an error, for the
    /// same reason as `blockedPortFailure`: what WebKit produces on its own for
    /// this is a bare `NSURLErrorDomain −1008`, whose only rendering is
    /// "<random uuid> did not load" over the system's untranslated sentence.
    /// The user cannot act on that, and it names the browser's own internal
    /// host as though it were a site that was down.
    static func extensionPageUnavailable(for url: URL) -> NavigationFailure {
        NavigationFailure(
            family: .extensionPageUnavailable,
            url: url,
            systemDescription: "",
            domain: NSURLErrorDomain,
            code: NSURLErrorResourceUnavailable
        )
    }

    static func family(domain: String, code: Int) -> Family {
        if domain == webKitErrorDomain {
            return code == webKitCannotShowURL ? .unsupportedScheme : .unrecognised
        }
        guard domain == NSURLErrorDomain else { return .unrecognised }
        switch code {
        case NSURLErrorNotConnectedToInternet,
             NSURLErrorInternationalRoamingOff,
             NSURLErrorDataNotAllowed:
            return .offline
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return .hostNotFound
        case NSURLErrorCannotConnectToHost:
            return .connectionRefused
        case NSURLErrorNetworkConnectionLost:
            return .connectionLost
        case NSURLErrorTimedOut:
            return .timedOut
        case NSURLErrorHTTPTooManyRedirects, NSURLErrorRedirectToNonExistentLocation:
            return .tooManyRedirects
        case NSURLErrorCancelled, NSURLErrorUserCancelledAuthentication:
            return .cancelled
        case NSURLErrorUnsupportedURL, NSURLErrorBadURL:
            return .unsupportedScheme
        case NSURLErrorSecureConnectionFailed,
             NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid,
             NSURLErrorClientCertificateRejected,
             NSURLErrorClientCertificateRequired:
            return .secureConnectionFailed
        default:
            return .unrecognised
        }
    }

    /// Whether this failure should draw nothing at all.
    ///
    /// A cancellation is only worth a screen when nothing replaced it. With a
    /// navigation already in flight the cancellation IS the replacement, and a
    /// browser that painted "you stopped loading this page" every time a link
    /// was clicked mid-load would be unusable.
    func isSilent(whileStillLoading: Bool) -> Bool {
        family == .cancelled && whileStillLoading
    }

    // MARK: - Copy
    //
    // Every string below names the problem and then the recovery. No "Oops",
    // no "Something went wrong", no em-dashes, and no advice that does not
    // follow from the error that was actually reported.

    /// The host, for the copy. Falls back to the whole address for URLs with
    /// no host (a malformed `about:` or a bare scheme).
    var host: String {
        url?.host ?? url?.absoluteString ?? "that address"
    }

    var title: String {
        switch family {
        case .offline:
            return "This Mac is not connected to the internet"
        case .hostNotFound:
            return "Cherry cannot find \(host)"
        case .connectionRefused:
            return "\(host) refused the connection"
        case .connectionLost:
            return "The connection to \(host) was lost"
        case .timedOut:
            return "\(host) took too long to answer"
        case .tooManyRedirects:
            return "\(host) redirected too many times"
        case .cancelled:
            return "You stopped loading this page"
        case .unsupportedScheme:
            return "Cherry cannot open this address"
        case .blockedPort:
            return "Cherry will not connect to port \(url?.port ?? 0)"
        case .secureConnectionFailed:
            return "Cherry could not open a secure connection to \(host)"
        case .extensionPageUnavailable:
            return "That extension is no longer installed"
        case .unrecognised:
            return "\(host) did not load"
        }
    }

    /// One sentence saying what happened, in terms of what the network did.
    var explanation: String {
        switch family {
        case .offline:
            return "No network connection was available, so the request was never sent."
        case .hostNotFound:
            return "The name \(host) could not be looked up. Either it does not exist, or this Mac cannot reach a DNS server right now."
        case .connectionRefused:
            return "The address was reached, but nothing accepted the connection\(portClause)."
        case .connectionLost:
            return "The connection opened and then dropped before the page arrived."
        case .timedOut:
            return "The connection was made but no reply arrived in time."
        case .tooManyRedirects:
            return "The server kept sending Cherry somewhere else, and that loop never reached a page."
        case .cancelled:
            return "The load was stopped before the page finished arriving."
        case .unsupportedScheme:
            return "This is not an address a page can be loaded from. Web pages come from http and https addresses, and from files on this Mac."
        case .blockedPort:
            return "Every browser refuses a short list of ports that belong to other protocols, and port \(url?.port ?? 0) is on it. The request was never sent."
        case .secureConnectionFailed:
            return "The encrypted connection could not be established. This is a failure of the connection itself, not of the site's certificate."
        case .extensionPageUnavailable:
            return "This page belongs to an extension, and no extension it could have come from is installed and enabled right now."
        case .unrecognised:
            return systemDescription
        }
    }

    private var portClause: String {
        guard let port = url?.port else { return "" }
        return " on port \(port)"
    }

    /// The one next step that is likely to work, or `nil` when there honestly
    /// isn't one. An empty suggestion is better than a confident wrong one.
    var nextStep: String? {
        switch family {
        case .offline:
            return "Check Wi-Fi or your Ethernet cable, then retry."
        case .hostNotFound:
            return "Check the spelling of the address in the toolbar."
        case .connectionRefused:
            return "If this is a server you run, check that it is started and listening on that port."
        case .connectionLost, .timedOut:
            return "Retry. If it keeps happening, the site is probably down."
        case .tooManyRedirects:
            return "Clearing this site's cookies usually ends a redirect loop."
        case .cancelled:
            return nil
        case .unsupportedScheme:
            return "Check the part of the address before the colon."
        case .blockedPort:
            return "If this is a server you run, move it to a port browsers will open, such as 8000 or 8080."
        case .secureConnectionFailed:
            return "Retry. If it keeps happening, the site's server and Cherry could not agree on how to encrypt the connection, and only the site can fix that."
        case .extensionPageUnavailable:
            return "Install or enable the extension in Settings \u{25B8} Extensions, then open its page again."
        case .unrecognised:
            return nil
        }
    }

    /// The line under the fallback that says what Cherry actually knows, so an
    /// unrecognised failure is still reportable rather than a shrug.
    var diagnosticLine: String? {
        guard family == .unrecognised else { return nil }
        return "\(domain) \(code)"
    }

    /// Whether the failure screen offers Pearl's runner.
    ///
    /// Only `.offline`. That screen is a WAIT — the network is gone and the
    /// user is stuck until it returns — so a game while waiting is a kindness.
    /// Every other family is an INSTRUCTION (fix the spelling, check the
    /// server, read what the system said), and burying an instruction under
    /// a game would make those screens worse at their one job. The rule
    /// lives here, on the model, so `PearlRunnerOfferTests` can walk every
    /// family and prove the game appears on exactly one of them.
    var offersPearlRunner: Bool {
        family == .offline
    }

    /// The SF Symbol on the surface. Deliberately not an alarm: these are
    /// conditions to read, not warnings to heed. The one screen in Cherry with
    /// a warning mark is the certificate interstitial.
    var symbolName: String {
        switch family {
        case .offline: return "wifi.slash"
        case .hostNotFound: return "questionmark.circle"
        case .connectionRefused: return "hand.raised"
        case .connectionLost: return "bolt.horizontal"
        case .timedOut: return "clock"
        case .tooManyRedirects: return "arrow.triangle.2.circlepath"
        case .cancelled: return "stop.circle"
        case .unsupportedScheme: return "link.badge.plus"
        case .blockedPort: return "nosign"
        case .secureConnectionFailed: return "lock.slash"
        case .extensionPageUnavailable: return "puzzlepiece.extension"
        case .unrecognised: return "exclamationmark.circle"
        }
    }
}
