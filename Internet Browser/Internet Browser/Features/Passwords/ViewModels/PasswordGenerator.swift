//
//  PasswordGenerator.swift
//  Cherry Browser
//

import Foundation
import Security

enum PasswordGenerator {
    static func generate(
        length: Int = 20,
        includeUppercase: Bool = true,
        includeLowercase: Bool = true,
        includeNumbers: Bool = true,
        includeSymbols: Bool = true
    ) -> String {
        var charset = ""
        if includeUppercase { charset += "ABCDEFGHIJKLMNOPQRSTUVWXYZ" }
        if includeLowercase { charset += "abcdefghijklmnopqrstuvwxyz" }
        if includeNumbers { charset += "0123456789" }
        if includeSymbols { charset += "!@#$%^&*()-_=+[]{}|;:,.<>?" }

        guard !charset.isEmpty, length > 0 else { return "" }

        let charArray = Array(charset)

        // Rejection sampling: byte % count is biased toward the start of the
        // charset whenever 256 is not a multiple of count (it never is for
        // these charsets), which measurably weakens generated passwords.
        let limit = 256 - (256 % charArray.count)
        var result = ""
        result.reserveCapacity(length)
        while result.count < length {
            var bytes = [UInt8](repeating: 0, count: length)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            guard status == errSecSuccess else {
                // Fallback to arc4random-backed random if SecRandom fails
                return String((0..<length).map { _ in charArray[Int.random(in: 0..<charArray.count)] })
            }
            for byte in bytes where Int(byte) < limit {
                result.append(charArray[Int(byte) % charArray.count])
                if result.count == length { break }
            }
        }
        return result
    }
}
