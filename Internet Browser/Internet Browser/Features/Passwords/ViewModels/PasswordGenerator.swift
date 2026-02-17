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
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)

        guard status == errSecSuccess else {
            // Fallback to less secure random if SecRandom fails
            return String((0..<length).map { _ in charArray[Int.random(in: 0..<charArray.count)] })
        }

        return String(bytes.map { charArray[Int($0) % charArray.count] })
    }
}
