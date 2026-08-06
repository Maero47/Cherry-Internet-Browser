//
//  CertificateWarningTests.swift
//  Internet BrowserTests
//
//  A certificate interstitial that names the wrong problem is worse than none:
//  it teaches people that the warning is noise. These pin the precedence and
//  the promises the copy makes.
//

import XCTest
@testable import Cherry

final class CertificateWarningTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_750_000_000)   // 2025-06-15

    private func facts(
        notBefore: TimeInterval? = -86_400 * 30,
        notAfter: TimeInterval? = 86_400 * 30,
        trustedIgnoringHostname: Bool = false,
        chainLength: Int = 3,
        revoked: Bool = false
    ) -> CertificateFacts {
        CertificateFacts(
            now: now,
            notBefore: notBefore.map { now.addingTimeInterval($0) },
            notAfter: notAfter.map { now.addingTimeInterval($0) },
            trustedIgnoringHostname: trustedIgnoringHostname,
            chainLength: chainLength,
            systemSaysRevoked: revoked,
            systemDescription: "the certificate could not be verified"
        )
    }

    // MARK: - The three cases badssl.com serves, and what each must be called

    /// `expired.badssl.com`: the name is right, the chain is right, the dates
    /// are not.
    func testAnExpiredCertificateIsCalledExpired() {
        let problem = CertificateFacts.problem(from: facts(notAfter: -86_400))
        guard case .expired(let on) = problem else { return XCTFail("got \(problem)") }
        XCTAssertEqual(on, now.addingTimeInterval(-86_400))
    }

    /// `wrong.host.badssl.com`: a genuine, in-date, properly issued certificate
    /// for somewhere else. The only thing failing is the hostname, which is
    /// exactly what `trustedIgnoringHostname` measures.
    func testACertificateThatOnlyFailsOnTheHostnameIsCalledANameMismatch() {
        XCTAssertEqual(
            CertificateFacts.problem(from: facts(trustedIgnoringHostname: true)),
            .nameMismatch
        )
    }

    /// `self-signed.badssl.com`: one certificate, vouching for itself.
    func testAOneCertificateChainIsCalledSelfSigned() {
        XCTAssertEqual(CertificateFacts.problem(from: facts(chainLength: 1)), .selfSigned)
    }

    func testALongerUntrustedChainIsCalledAnUntrustedIssuer() {
        XCTAssertEqual(CertificateFacts.problem(from: facts(chainLength: 2)), .untrustedIssuer)
    }

    func testACertificateThatIsNotValidYetIsCalledThat() {
        let problem = CertificateFacts.problem(from: facts(notBefore: 86_400))
        guard case .notYetValid = problem else { return XCTFail("got \(problem)") }
    }

    // MARK: - Precedence

    func testRevocationOutranksEverything() {
        XCTAssertEqual(
            CertificateFacts.problem(from: facts(
                notAfter: -86_400, trustedIgnoringHostname: true, chainLength: 1, revoked: true
            )),
            .revoked
        )
    }

    /// An expired self-signed certificate is reported as expired, because the
    /// date is the fact the user can check for themselves.
    func testAnExpiryOutranksTheChain() {
        let problem = CertificateFacts.problem(from: facts(notAfter: -1, chainLength: 1))
        guard case .expired = problem else { return XCTFail("got \(problem)") }
    }

    func testDatesOutrankTheHostname() {
        let problem = CertificateFacts.problem(
            from: facts(notAfter: -1, trustedIgnoringHostname: true)
        )
        guard case .expired = problem else { return XCTFail("got \(problem)") }
    }

    // MARK: - What the screen says

    private func warning(
        _ problem: CertificateProblem,
        isPrivate: Bool = false,
        commonName: String? = "*.badssl.com"
    ) -> CertificateWarning {
        CertificateWarning(
            host: "wrong.host.badssl.com",
            port: 443,
            url: URL(string: "https://wrong.host.badssl.com/")!,
            problem: problem,
            certificateCommonName: commonName,
            isPrivate: isPrivate
        )
    }

    func testEveryProblemHasAHeadlineAndADetailAndNeitherShrugs() {
        let problems: [CertificateProblem] = [
            .expired(on: now), .notYetValid(until: now), .nameMismatch,
            .selfSigned, .untrustedIssuer, .revoked, .unspecified("a reason"),
        ]
        for problem in problems {
            let w = warning(problem)
            for string in [w.headline, w.detail, w.risk, w.proceedScope] {
                XCTAssertFalse(string.isEmpty, "\(problem)")
                XCTAssertFalse(string.contains("—"), "\(problem) copy contains an em-dash")
                XCTAssertFalse(string.lowercased().contains("oops"), "\(problem)")
                XCTAssertFalse(
                    string.lowercased().contains("something went wrong"), "\(problem)"
                )
            }
        }
    }

    /// The whole point of the name-mismatch case: say which site it IS for.
    func testANameMismatchPrintsTheNameTheCertificateIsActuallyFor() {
        XCTAssertTrue(
            warning(.nameMismatch).detail.contains("*.badssl.com"),
            warning(.nameMismatch).detail
        )
    }

    func testANameMismatchWithNoReadableNameDoesNotPretendToHaveOne() {
        let detail = warning(.nameMismatch, commonName: nil).detail
        XCTAssertFalse(detail.contains("made out to"))
        XCTAssertTrue(detail.contains("wrong.host.badssl.com"))
    }

    /// The consequence is stated the same way whatever is wrong, so nobody has
    /// to work out from the headline whether this one is serious.
    func testTheRiskSentenceNamesTheHostAndTheStakes() {
        for problem in [CertificateProblem.expired(on: now), .selfSigned, .nameMismatch] {
            let risk = warning(problem).risk
            XCTAssertTrue(risk.contains("wrong.host.badssl.com"))
            XCTAssertTrue(risk.lowercased().contains("password"))
        }
    }

    // MARK: - The scope, as written on the screen

    func testTheScopeSentenceSaysSessionOnlyAndNeverDisk() {
        let scope = warning(.selfSigned).proceedScope.lowercased()
        XCTAssertTrue(scope.contains("session"))
        XCTAssertTrue(scope.contains("never written to disk"))
    }

    func testAPrivateWindowSaysItsExceptionDiesWithTheWindow() {
        let scope = warning(.selfSigned, isPrivate: true).proceedScope.lowercased()
        XCTAssertTrue(scope.contains("private window"))
        XCTAssertTrue(scope.contains("forgotten when the window closes"))
        XCTAssertTrue(scope.contains("never written to disk"))
    }

    func testTheExceptionKeyIsTheHostAndPortAndNothingElse() {
        let w = warning(.selfSigned)
        XCTAssertEqual(w.exceptionKey, CertificateExceptionStore.Key(host: "wrong.host.badssl.com", port: 443))
        XCTAssertNotEqual(w.exceptionKey, CertificateExceptionStore.Key(host: "badssl.com", port: 443))
        XCTAssertNotEqual(w.exceptionKey, CertificateExceptionStore.Key(host: "wrong.host.badssl.com", port: 8443))
    }
}
