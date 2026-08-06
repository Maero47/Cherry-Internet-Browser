//
//  CertificateExceptionStoreTests.swift
//  Internet BrowserTests
//
//  The interstitial promises, in writing, that continuing past it covers one
//  host, for this session, and is never written to disk. This is the file that
//  makes those three claims checkable.
//

import XCTest
@testable import Cherry

@MainActor
final class CertificateExceptionStoreTests: XCTestCase {

    private var store: CertificateExceptionStore { .shared }

    override func setUp() {
        super.setUp()
        store.forgetAllExceptions()
    }

    override func tearDown() {
        store.forgetAllExceptions()
        super.tearDown()
    }

    private func key(_ host: String, _ port: Int = 443) -> CertificateExceptionStore.Key {
        CertificateExceptionStore.Key(host: host, port: port)
    }

    // MARK: - One host, one port

    func testAnExceptionCoversOnlyTheHostItWasMadeFor() {
        store.allow(key("self-signed.badssl.com"), isPrivate: false)
        XCTAssertTrue(store.allows(key("self-signed.badssl.com"), isPrivate: false))
        XCTAssertFalse(store.allows(key("expired.badssl.com"), isPrivate: false))
        XCTAssertFalse(
            store.allows(key("badssl.com"), isPrivate: false),
            "an exception must not climb to the parent domain"
        )
        XCTAssertFalse(
            store.allows(key("evil.self-signed.badssl.com"), isPrivate: false),
            "an exception must not spread to subdomains"
        )
    }

    func testAnExceptionCoversOnlyThePortItWasMadeFor() {
        store.allow(key("localhost", 8443), isPrivate: false)
        XCTAssertTrue(store.allows(key("localhost", 8443), isPrivate: false))
        XCTAssertFalse(store.allows(key("localhost", 443), isPrivate: false))
    }

    /// Case and Unicode folding go through `HostNormalizer`, so a second
    /// spelling of an already-trusted host cannot become a second, separately
    /// prompted entry (or, worse, a way to make the check miss).
    func testHostsAreMatchedWithTheSameFoldingTheRestOfCherryUses() {
        store.allow(key("Self-Signed.BadSSL.com"), isPrivate: false)
        XCTAssertTrue(store.allows(key("self-signed.badssl.com"), isPrivate: false))
    }

    // MARK: - Private windows

    func testAPrivateExceptionIsInvisibleToNormalWindows() {
        store.allow(key("self-signed.badssl.com"), isPrivate: true)
        XCTAssertTrue(store.allows(key("self-signed.badssl.com"), isPrivate: true))
        XCTAssertFalse(
            store.allows(key("self-signed.badssl.com"), isPrivate: false),
            "a decision made in a private window must not change what a normal window trusts"
        )
    }

    func testANormalExceptionIsInvisibleToPrivateWindows() {
        store.allow(key("self-signed.badssl.com"), isPrivate: false)
        XCTAssertFalse(
            store.allows(key("self-signed.badssl.com"), isPrivate: true),
            "a private window should warn exactly as a fresh browser would"
        )
    }

    func testEndingPrivateBrowsingForgetsPrivateExceptionsAndKeepsTheRest() {
        store.allow(key("private.example"), isPrivate: true)
        store.allow(key("normal.example"), isPrivate: false)

        store.forgetPrivateExceptions()

        XCTAssertFalse(store.allows(key("private.example"), isPrivate: true))
        XCTAssertTrue(store.allows(key("normal.example"), isPrivate: false))
    }

    // MARK: - Never on disk

    /// The store has no persistence API at all, which is the real guarantee.
    /// This is the regression guard for somebody adding one: nothing about an
    /// exception may appear in the app's defaults.
    func testAllowingAnExceptionWritesNothingToUserDefaults() {
        let host = "never-persisted-\(UUID().uuidString).example"
        store.allow(key(host), isPrivate: false)

        let defaults = UserDefaults.standard.dictionaryRepresentation()
        for (defaultsKey, value) in defaults {
            XCTAssertFalse(
                defaultsKey.lowercased().contains("certificateexception"),
                "an exception key appeared in UserDefaults: \(defaultsKey)"
            )
            if let string = value as? String {
                XCTAssertFalse(string.contains(host), "the host was written to \(defaultsKey)")
            }
            if let array = value as? [String] {
                XCTAssertFalse(array.contains(where: { $0.contains(host) }), "the host was written to \(defaultsKey)")
            }
        }
    }

    func testForgettingEverythingIsAvailableWithoutQuitting() {
        store.allow(key("a.example"), isPrivate: false)
        store.allow(key("b.example"), isPrivate: true)
        XCTAssertEqual(store.exceptionCount.session, 1)
        XCTAssertEqual(store.exceptionCount.private, 1)

        store.forgetAllExceptions()

        XCTAssertEqual(store.exceptionCount.session, 0)
        XCTAssertEqual(store.exceptionCount.private, 0)
    }

    // MARK: - Nothing is trusted by default

    func testAFreshStoreTrustsNothing() {
        XCTAssertFalse(store.allows(key("expired.badssl.com"), isPrivate: false))
        XCTAssertFalse(store.allows(key("expired.badssl.com"), isPrivate: true))
    }
}
