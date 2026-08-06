//
//  CertificateWarning.swift
//  Cherry Browser
//
//  What is wrong with a site's certificate, worked out from the trust object
//  rather than from the error code.
//
//  ## Why the error code is not enough
//
//  `NSURLErrorServerCertificateUntrusted` is the code you get for a self-signed
//  certificate, an unknown root, and a certificate that is fine except that it
//  belongs to a different site. Those are three different things to tell a
//  person, and only one of them ("it is for another site, and here is which
//  one") lets them work out whether they are being attacked or whether the
//  admin made a typo. So Cherry evaluates the `SecTrust` itself.
//
//  ## How each answer is reached
//
//  | Kind | How it is established |
//  | --- | --- |
//  | `.revoked` | the system's own trust error says so |
//  | `.expired` / `.notYetValid` | the leaf's own validity dates, read from the certificate, compared with now |
//  | `.nameMismatch` | the dates are fine AND the chain evaluates cleanly under a policy with no hostname in it, so the hostname is the only thing failing |
//  | `.selfSigned` | the chain is one certificate long: it vouches for itself |
//  | `.untrustedIssuer` | a chain that does not reach a root this Mac trusts |
//
//  The order matters and is tested. An expired self-signed certificate is
//  reported as expired, because that is the fact the user can check.
//
//  Revocation is recognised, not hunted for: Cherry does not attach a
//  revocation policy (that would put an OCSP round trip in front of every
//  HTTPS page load). `.revoked` therefore appears when the system already knew,
//  which is the same condition under which Safari knows.
//

import Foundation
import Security

// MARK: - The problem

enum CertificateProblem: Equatable {
    case expired(on: Date)
    case notYetValid(until: Date)
    case nameMismatch
    case selfSigned
    case untrustedIssuer
    case revoked
    /// The trust failed for a reason none of the above explains. The system's
    /// own sentence is carried instead of a guess.
    case unspecified(String)
}

/// Everything the decision below is made from, separated from `SecTrust` so the
/// precedence can be tested without a live server.
struct CertificateFacts: Equatable {
    var now: Date
    var notBefore: Date?
    var notAfter: Date?
    /// Whether the chain evaluates cleanly once the hostname is taken out of
    /// the policy. True here with a hostname-policy failure means the hostname
    /// is the only thing wrong.
    var trustedIgnoringHostname: Bool
    var chainLength: Int
    var systemSaysRevoked: Bool
    var systemDescription: String

    static func problem(from facts: CertificateFacts) -> CertificateProblem {
        if facts.systemSaysRevoked { return .revoked }
        if let notAfter = facts.notAfter, notAfter < facts.now {
            return .expired(on: notAfter)
        }
        if let notBefore = facts.notBefore, notBefore > facts.now {
            return .notYetValid(until: notBefore)
        }
        if facts.trustedIgnoringHostname { return .nameMismatch }
        if facts.chainLength <= 1 { return .selfSigned }
        if facts.chainLength > 1 { return .untrustedIssuer }
        return .unspecified(facts.systemDescription)
    }
}

// MARK: - The warning a tab shows

/// A live certificate warning: one host, one tab, blocking.
struct CertificateWarning: Identifiable, Equatable {
    let id = UUID()
    /// The host the certificate was presented for. Exceptions are scoped to
    /// this plus the port, never to a whole site or a whole session.
    let host: String
    let port: Int
    /// The address the user asked for, so Retry and Proceed reload the page
    /// they wanted rather than the bare host.
    let url: URL
    let problem: CertificateProblem
    /// The name on the certificate, when there is one to show. The point of
    /// printing it is the name-mismatch case: "it is a real certificate, for
    /// somewhere else, and here is where."
    let certificateCommonName: String?
    /// Whether the tab this is shown in belongs to a private window. Carried on
    /// the warning so the proceed path cannot forget to ask.
    let isPrivate: Bool

    static func == (lhs: CertificateWarning, rhs: CertificateWarning) -> Bool {
        lhs.id == rhs.id
    }

    var exceptionKey: CertificateExceptionStore.Key {
        CertificateExceptionStore.Key(host: host, port: port)
    }

    // MARK: - Copy
    //
    // This is the one screen in a browser where the copy IS the security
    // feature, so every sentence below states a fact about the certificate that
    // was actually presented, and none of it softens.

    var headline: String {
        switch problem {
        case .expired:
            return "This site's certificate expired"
        case .notYetValid:
            return "This site's certificate is not valid yet"
        case .nameMismatch:
            return "This certificate is for a different site"
        case .selfSigned:
            return "This site vouches for itself"
        case .untrustedIssuer:
            return "Cherry does not trust who issued this certificate"
        case .revoked:
            return "This site's certificate was revoked"
        case .unspecified:
            return "Cherry cannot verify this site's certificate"
        }
    }

    /// What is wrong, in one or two sentences of plain words.
    var detail: String {
        switch problem {
        case .expired(let date):
            return "The certificate \(host) presented stopped being valid on \(Self.dateText(date)). Cherry cannot tell whether it still belongs to this site."
        case .notYetValid(let date):
            return "The certificate \(host) presented does not start being valid until \(Self.dateText(date)). Either the site's certificate was issued for later, or this Mac's clock is wrong."
        case .nameMismatch:
            if let name = certificateCommonName {
                return "The certificate \(host) presented is made out to \(name), not to \(host). A connection to the wrong site can be read by whoever is running it."
            }
            return "The certificate \(host) presented does not cover \(host). A connection to the wrong site can be read by whoever is running it."
        case .selfSigned:
            return "The certificate \(host) presented was signed by itself, so nothing independent confirms who is on the other end. Anyone able to sit between you and this site can present a certificate exactly like it."
        case .untrustedIssuer:
            return "The certificate \(host) presented was signed by an authority this Mac does not trust, so nothing confirms who is on the other end."
        case .revoked:
            return "The certificate \(host) presented was withdrawn by the authority that issued it. That happens when a certificate's private key has been exposed."
        case .unspecified(let reason):
            return "The certificate \(host) presented could not be verified. The system reported: \(reason)"
        }
    }

    /// The consequence, stated once, in the same place every time.
    var risk: String {
        "Until this is fixed, anything you send to \(host), including passwords, may be readable by someone else."
    }

    /// What proceeding actually costs, spelled out next to the control that
    /// does it. The scope stated here is enforced by `CertificateExceptionStore`.
    var proceedScope: String {
        isPrivate
            ? "Continuing trusts \(host) for this private window only. It is forgotten when the window closes and is never written to disk."
            : "Continuing trusts \(host) for the rest of this Cherry session only. It is never written to disk, and it covers no other site."
    }

    private static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

// MARK: - Reading the trust object

enum CertificateInspector {

    /// Works out what is wrong with `trust`, which has already failed
    /// evaluation for `host`.
    static func problem(with trust: SecTrust, host: String, now: Date = Date()) -> CertificateProblem {
        var trustError: CFError?
        _ = SecTrustEvaluateWithError(trust, &trustError)
        let description = (trustError as Error?)?.localizedDescription ?? "the certificate could not be verified"

        let chain = certificateChain(of: trust)
        let leaf = chain.first
        let validity: (notBefore: Date?, notAfter: Date?) =
            leaf.map(validityDates(of:)) ?? (notBefore: nil, notAfter: nil)

        let facts = CertificateFacts(
            now: now,
            notBefore: validity.notBefore,
            notAfter: validity.notAfter,
            trustedIgnoringHostname: leaf.map { evaluatesIgnoringHostname(chain: chain, leaf: $0) } ?? false,
            chainLength: chain.count,
            systemSaysRevoked: description.range(of: "revoked", options: .caseInsensitive) != nil,
            systemDescription: description
        )
        _ = host
        return CertificateFacts.problem(from: facts)
    }

    /// The name on the leaf certificate, for the name-mismatch case.
    static func commonName(of trust: SecTrust) -> String? {
        guard let leaf = certificateChain(of: trust).first else { return nil }
        var name: CFString?
        guard SecCertificateCopyCommonName(leaf, &name) == errSecSuccess else { return nil }
        return (name as String?).flatMap { $0.isEmpty ? nil : $0 }
    }

    static func certificateChain(of trust: SecTrust) -> [SecCertificate] {
        (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
    }

    /// Re-evaluates the same certificates under an SSL policy carrying no
    /// hostname. Success means every other part of the chain is fine and the
    /// hostname is the single reason the real evaluation failed.
    private static func evaluatesIgnoringHostname(chain: [SecCertificate], leaf: SecCertificate) -> Bool {
        _ = leaf
        var anonymous: SecTrust?
        let policy = SecPolicyCreateSSL(true, nil)
        guard SecTrustCreateWithCertificates(chain as CFArray, policy, &anonymous) == errSecSuccess,
              let anonymous else { return false }
        return SecTrustEvaluateWithError(anonymous, nil)
    }

    /// The leaf's own validity window, read off the certificate. Read directly
    /// rather than inferred from the trust error, because "expired" is a fact
    /// with a date on it and the user can check a date.
    static func validityDates(of certificate: SecCertificate) -> (notBefore: Date?, notAfter: Date?) {
        let keys = [kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter] as CFArray
        guard let values = SecCertificateCopyValues(certificate, keys, nil) as? [String: Any] else {
            return (nil, nil)
        }
        func date(_ oid: CFString) -> Date? {
            guard let entry = values[oid as String] as? [String: Any],
                  let seconds = entry[kSecPropertyKeyValue as String] as? NSNumber else { return nil }
            // The value is a CFAbsoluteTime: seconds since 2001-01-01 UTC.
            return Date(timeIntervalSinceReferenceDate: seconds.doubleValue)
        }
        return (date(kSecOIDX509V1ValidityNotBefore), date(kSecOIDX509V1ValidityNotAfter))
    }
}
