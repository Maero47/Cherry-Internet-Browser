//
//  ChromiumPasswordDecryptor.swift
//  Cherry Browser
//
//  Decrypts Chromium-family (Chrome / Brave / Edge / Chromium) saved passwords
//  on macOS. Each `password_value` BLOB in the `Login Data` SQLite database is
//  AES-128-CBC encrypted with a key derived from a per-browser secret that the
//  browser stores in the login Keychain as a generic-password item:
//
//    service = "<Brand> Safe Storage", account = "<Brand>"
//
//  Reading that item triggers a macOS Keychain prompt (Cherry did not create
//  it), which is expected — denial/cancellation is surfaced, never a crash.
//
//    key   = PBKDF2-HMAC-SHA1(secret, salt: "saltysalt", iterations: 1003, 16 bytes)
//    iv    = 16 bytes of 0x20 (space)
//    blob  = "v10"/"v11" 3-byte tag  ++  AES-128-CBC(PKCS7) ciphertext
//

import CommonCrypto
import Foundation
import Security

/// A Chromium-family browser identified by the Keychain "Safe Storage" item
/// that guards its password-encryption secret.
enum ChromiumBrand: Sendable {
    case chrome
    case brave
    case edge
    case chromium

    /// `kSecAttrService` of the generic-password item holding the secret.
    var keychainService: String {
        switch self {
        case .chrome: "Chrome Safe Storage"
        case .brave: "Brave Safe Storage"
        case .edge: "Microsoft Edge Safe Storage"
        case .chromium: "Chromium Safe Storage"
        }
    }

    /// `kSecAttrAccount` of that item.
    var keychainAccount: String {
        switch self {
        case .chrome: "Chrome"
        case .brave: "Brave"
        case .edge: "Microsoft Edge"
        case .chromium: "Chromium"
        }
    }

    var displayName: String { keychainAccount }
}

enum ChromiumPasswordDecryptor {
    /// Fixed PBKDF2 parameters Chromium uses on macOS.
    static let salt = "saltysalt"
    static let iterations: UInt32 = 1003
    static let keyLength = 16 // AES-128

    // MARK: - Keychain secret

    /// Reads the browser's Safe-Storage secret from the login Keychain. This is
    /// the call that prompts the user for access. Throws `keychainAccessDenied`
    /// on denial / cancellation / missing item.
    static func safeStorageKey(for brand: ChromiumBrand) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: brand.keychainService,
            kSecAttrAccount as String: brand.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, !data.isEmpty else {
            throw ImportError.keychainAccessDenied(browser: brand.displayName, status: status)
        }
        return data
    }

    // MARK: - Key derivation

    /// Derives the 16-byte AES key from the Safe-Storage secret via
    /// PBKDF2-HMAC-SHA1 (saltysalt / 1003 iterations). Returns nil on failure.
    static func deriveKey(fromSecret secret: Data) -> Data? {
        guard !secret.isEmpty else { return nil }
        let saltData = Data(salt.utf8)
        var derived = Data(count: keyLength)

        let status = derived.withUnsafeMutableBytes { derivedPtr -> Int32 in
            saltData.withUnsafeBytes { saltPtr in
                secret.withUnsafeBytes { secretPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        secretPtr.baseAddress!.assumingMemoryBound(to: CChar.self),
                        secret.count,
                        saltPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        saltData.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        iterations,
                        derivedPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        keyLength
                    )
                }
            }
        }
        return status == kCCSuccess ? derived : nil
    }

    // MARK: - Decrypt

    /// Decrypts one stored `password_value` BLOB. Strips the `v10`/`v11` tag
    /// if present, then AES-128-CBC/PKCS7 decrypts with a 0x20-filled IV.
    /// Returns nil for empty/short/undecryptable blobs (caller skips them).
    static func decrypt(_ blob: Data, withKey key: Data) -> String? {
        guard key.count == keyLength else { return nil }

        var payload = blob
        if payload.count >= 3 {
            let prefix = payload.prefix(3)
            if prefix.elementsEqual("v10".utf8) || prefix.elementsEqual("v11".utf8) {
                payload = payload.subdata(in: payload.index(payload.startIndex, offsetBy: 3) ..< payload.endIndex)
            }
        }
        guard !payload.isEmpty, payload.count % kCCBlockSizeAES128 == 0 else { return nil }

        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        let outputCapacity = payload.count + kCCBlockSizeAES128
        var output = Data(count: outputCapacity)
        var decryptedCount = 0

        let status = output.withUnsafeMutableBytes { outPtr -> Int32 in
            payload.withUnsafeBytes { inPtr in
                iv.withUnsafeBytes { ivPtr in
                    key.withUnsafeBytes { keyPtr in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, keyLength,
                            ivPtr.baseAddress,
                            inPtr.baseAddress, payload.count,
                            outPtr.baseAddress, outputCapacity,
                            &decryptedCount
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }

        output.removeSubrange(decryptedCount ..< output.count)
        return String(data: output, encoding: .utf8)
    }
}
