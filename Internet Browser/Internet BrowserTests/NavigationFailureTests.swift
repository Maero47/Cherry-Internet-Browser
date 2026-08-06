//
//  NavigationFailureTests.swift
//  Internet BrowserTests
//
//  The error surface is only as good as the mapping behind it, and the mapping
//  is the part that can silently rot: a code moves families, a new WebKit
//  version starts reporting something else, and the screen confidently tells
//  somebody to check their Wi-Fi when the real problem was a redirect loop.
//

import XCTest
@testable import Cherry

final class NavigationFailureTests: XCTestCase {

    private func error(_ domain: String, _ code: Int, url: URL? = nil) -> NSError {
        var info: [String: Any] = [NSLocalizedDescriptionKey: "system sentence"]
        if let url { info[NSURLErrorFailingURLErrorKey] = url }
        return NSError(domain: domain, code: code, userInfo: info)
    }

    private let target = URL(string: "https://example.invalid/page?q=1")!

    // MARK: - Every family the surface claims to cover

    func testEachNamedFamilyIsReachedFromTheCodeThatActuallyCausesIt() {
        let cases: [(Int, NavigationFailure.Family)] = [
            (NSURLErrorNotConnectedToInternet, .offline),
            (NSURLErrorCannotFindHost, .hostNotFound),
            (NSURLErrorDNSLookupFailed, .hostNotFound),
            (NSURLErrorCannotConnectToHost, .connectionRefused),
            (NSURLErrorNetworkConnectionLost, .connectionLost),
            (NSURLErrorTimedOut, .timedOut),
            (NSURLErrorHTTPTooManyRedirects, .tooManyRedirects),
            (NSURLErrorCancelled, .cancelled),
            (NSURLErrorUnsupportedURL, .unsupportedScheme),
            (NSURLErrorSecureConnectionFailed, .secureConnectionFailed),
            (NSURLErrorServerCertificateUntrusted, .secureConnectionFailed),
        ]
        for (code, expected) in cases {
            XCTAssertEqual(
                NavigationFailure.family(domain: NSURLErrorDomain, code: code), expected,
                "NSURLErrorDomain \(code)"
            )
        }
    }

    func testWebKitCannotShowURLIsAnUnsupportedScheme() {
        XCTAssertEqual(
            NavigationFailure.family(
                domain: NavigationFailure.webKitErrorDomain,
                code: NavigationFailure.webKitCannotShowURL
            ),
            .unsupportedScheme
        )
    }

    // MARK: - The fallback

    func testAnUnknownErrorFallsBackWithoutInventingAnExplanation() {
        let failure = NavigationFailure.make(
            from: error("SomeFrameworkErrorDomain", 4242, url: target),
            requestedURL: nil
        )
        XCTAssertEqual(failure?.family, .unrecognised)
        // The explanation IS the system's sentence, not a guess.
        XCTAssertEqual(failure?.explanation, "system sentence")
        // And it stays reportable.
        XCTAssertEqual(failure?.diagnosticLine, "SomeFrameworkErrorDomain 4242")
        XCTAssertNil(failure?.nextStep, "an unknown failure must not suggest a fix")
    }

    func testOnlyTheFallbackCarriesADiagnosticLine() {
        for code in [NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCancelled] {
            let failure = NavigationFailure.make(from: error(NSURLErrorDomain, code), requestedURL: target)
            XCTAssertNil(failure?.diagnosticLine, "NSURLErrorDomain \(code) is a named family")
        }
    }

    // MARK: - The two failures that are not events

    func testWebKitHandOffCodesProduceNoFailureAtAll() {
        for code in [
            NavigationFailure.webKitFrameLoadInterrupted,
            NavigationFailure.webKitPlugInWillHandleLoad,
        ] {
            XCTAssertNil(
                NavigationFailure.make(
                    from: error(NavigationFailure.webKitErrorDomain, code),
                    requestedURL: target
                ),
                "WebKitErrorDomain \(code) is bookkeeping, not a failure"
            )
        }
    }

    func testACancellationIsSilentOnlyWhileSomethingElseIsLoading() {
        let cancelled = NavigationFailure.make(
            from: error(NSURLErrorDomain, NSURLErrorCancelled), requestedURL: target
        )!
        XCTAssertTrue(
            cancelled.isSilent(whileStillLoading: true),
            "a link clicked mid-load must not paint an error page"
        )
        XCTAssertFalse(
            cancelled.isSilent(whileStillLoading: false),
            "pressing Stop with nothing else running has to say something"
        )
    }

    func testNoOtherFamilyIsEverSilenced() {
        for code in [NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorNotConnectedToInternet] {
            let failure = NavigationFailure.make(from: error(NSURLErrorDomain, code), requestedURL: target)!
            XCTAssertFalse(failure.isSilent(whileStillLoading: true))
            XCTAssertFalse(failure.isSilent(whileStillLoading: false))
        }
    }

    // MARK: - The address

    func testTheFailingURLOnTheErrorWinsOverTheOneTheTabRemembered() {
        let redirected = URL(string: "https://elsewhere.invalid/final")!
        let failure = NavigationFailure.make(
            from: error(NSURLErrorDomain, NSURLErrorCannotFindHost, url: redirected),
            requestedURL: target
        )
        XCTAssertEqual(failure?.url, redirected, "a redirect chain fails where it got to")
    }

    func testTheRequestedURLIsUsedWhenTheErrorCarriesNone() {
        let failure = NavigationFailure.make(
            from: error(NSURLErrorDomain, NSURLErrorTimedOut), requestedURL: target
        )
        XCTAssertEqual(failure?.url, target)
    }

    func testTheHostIsWhatTheCopyNames() {
        let failure = NavigationFailure.make(
            from: error(NSURLErrorDomain, NSURLErrorCannotFindHost, url: target), requestedURL: nil
        )!
        XCTAssertEqual(failure.host, "example.invalid")
        XCTAssertTrue(failure.title.contains("example.invalid"))
    }

    // MARK: - Ports no browser will open
    //
    // WebKit refuses these below the navigation delegate, with no error and no
    // callback: before this check existed, `http://127.0.0.1:1` left the tab on
    // about:blank with the omnibox rewritten and nothing said. Verified in the
    // running app, which is why the check is made before the load rather than
    // in the failure handler.

    func testAMainFrameNavigationToABlockedPortIsRefusedWithAnExplanation() {
        let failure = NavigationFailure.blockedPortFailure(for: URL(string: "http://127.0.0.1:1/")!)
        XCTAssertEqual(failure?.family, .blockedPort)
        XCTAssertTrue(failure?.title.contains("port 1") ?? false, failure?.title ?? "nil")
        XCTAssertTrue(failure?.explanation.contains("port 1") ?? false)
        XCTAssertNotNil(failure?.nextStep)
    }

    func testTheUsualDevelopmentPortsAreNotBlocked() {
        for port in [80, 443, 3000, 5173, 8000, 8080, 8443, 9999] {
            XCTAssertNil(
                NavigationFailure.blockedPortFailure(for: URL(string: "http://127.0.0.1:\(port)/")!),
                "port \(port) must load"
            )
        }
    }

    func testAnAddressWithNoPortIsNeverBlocked() {
        XCTAssertNil(NavigationFailure.blockedPortFailure(for: URL(string: "https://example.com/")!))
    }

    /// Only http(s). `ftp://host:21` is handed to the system by
    /// `decidePolicyFor` long before this, and blocking port 21 for it here
    /// would break the one scheme that legitimately uses it.
    func testOnlyWebSchemesAreCheckedForBlockedPorts() {
        XCTAssertNil(NavigationFailure.blockedPortFailure(for: URL(string: "ftp://example.com:21/")!))
        XCTAssertNil(NavigationFailure.blockedPortFailure(for: URL(string: "file:///tmp/x")!))
    }

    func testTheBlockedListIsTheFetchBadPortsList() {
        // Spot checks across the list, including the boundaries people hit:
        // SMTP, IMAP, the IRC block, and the one four-digit entry.
        for port in [1, 22, 25, 143, 6666, 6697, 10080] {
            XCTAssertTrue(NavigationFailure.blockedPorts.contains(port), "port \(port)")
        }
    }

    // MARK: - Copy rules
    //
    // Stated as tests because they are requirements, not preferences.

    private var everyFamilysCopy: [(NavigationFailure.Family, [String])] {
        let families: [NavigationFailure.Family] = [
            .offline, .hostNotFound, .connectionRefused, .connectionLost, .timedOut,
            .tooManyRedirects, .cancelled, .unsupportedScheme, .blockedPort,
            .secureConnectionFailed, .unrecognised,
        ]
        return families.map { family in
            let failure = NavigationFailure(
                family: family, url: target,
                systemDescription: "system sentence",
                domain: NSURLErrorDomain, code: -1
            )
            return (family, [failure.title, failure.explanation, failure.nextStep].compactMap { $0 })
        }
    }

    func testNoCopyUsesAnEmDash() {
        for (family, strings) in everyFamilysCopy {
            for string in strings {
                XCTAssertFalse(string.contains("—"), "\(family) copy contains an em-dash: \(string)")
            }
        }
    }

    func testNoCopyShrugs() {
        let banned = ["oops", "something went wrong", "whoops", "uh oh"]
        for (family, strings) in everyFamilysCopy {
            for string in strings {
                let lowered = string.lowercased()
                for phrase in banned {
                    XCTAssertFalse(lowered.contains(phrase), "\(family) copy says \"\(phrase)\"")
                }
            }
        }
    }

    func testEveryFamilyHasATitleAndAnExplanation() {
        for (family, strings) in everyFamilysCopy {
            XCTAssertGreaterThanOrEqual(strings.count, 2, "\(family) is missing copy")
            for string in strings {
                XCTAssertFalse(string.trimmingCharacters(in: .whitespaces).isEmpty, "\(family)")
            }
        }
    }

    func testEveryFamilyHasASymbolOfItsOwn() {
        let symbols = everyFamilysCopy.map { family, _ in
            NavigationFailure(
                family: family, url: target, systemDescription: "",
                domain: NSURLErrorDomain, code: -1
            ).symbolName
        }
        XCTAssertEqual(Set(symbols).count, symbols.count, "two families share a symbol")
    }

    /// The port matters for a refused connection: "nothing is listening on port
    /// 1" is actionable, "nothing is listening" is not.
    func testARefusedConnectionNamesThePortWhenThereIsOne() {
        let failure = NavigationFailure(
            family: .connectionRefused,
            url: URL(string: "http://127.0.0.1:1/")!,
            systemDescription: "", domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost
        )
        XCTAssertTrue(failure.explanation.contains("port 1"), failure.explanation)
    }
}
