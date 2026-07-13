//
//  PasswordCSVParser.swift
//  Cherry Browser
//
//  Universal password CSV import. Any browser can export saved passwords to a
//  CSV file; this parses it (RFC-4180: quoted fields, embedded commas/newlines,
//  "" escapes) and maps the header columns case-insensitively to Cherry's
//  (url, username, password) fields. Handles the real export headers:
//
//    Chrome/Brave/Edge  name,url,username,password,note
//    Firefox            "url","username","password","httpRealm","formActionOrigin",…
//    Safari             Title,URL,Username,Password,Notes,OTPAuth
//
//  Rows missing a url or password are skipped.
//

import Foundation

enum PasswordCSV {

    /// Header aliases (already lowercased) in preference order.
    private static let urlColumns = ["url", "login_uri", "website"]
    private static let usernameColumns = ["username", "login_username"]
    private static let passwordColumns = ["password", "login_password"]

    /// Parses CSV text into credentials, mapping columns from the header row.
    static func credentials(from text: String) -> [ImportedCredential] {
        let rows = parseRows(text)
        guard let header = rows.first else { return [] }

        let headers = header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        func firstIndex(of candidates: [String]) -> Int? {
            for name in candidates {
                if let index = headers.firstIndex(of: name) { return index }
            }
            return nil
        }

        guard let urlIndex = firstIndex(of: urlColumns),
              let passwordIndex = firstIndex(of: passwordColumns) else {
            return []
        }
        let usernameIndex = firstIndex(of: usernameColumns)

        func field(_ row: [String], _ index: Int?) -> String {
            guard let index, index < row.count else { return "" }
            return row[index]
        }

        var credentials: [ImportedCredential] = []
        for row in rows.dropFirst() {
            let url = field(row, urlIndex).trimmingCharacters(in: .whitespacesAndNewlines)
            let password = field(row, passwordIndex)
            guard !url.isEmpty, !password.isEmpty else { continue }
            let username = field(row, usernameIndex)
            credentials.append(ImportedCredential(url: url, username: username, password: password))
        }
        return credentials
    }

    // MARK: - RFC-4180 tokenizer

    /// Splits CSV text into records of fields, honoring quoted fields (which may
    /// contain commas, CR/LF, and `""`-escaped quotes). Accepts LF, CRLF and CR
    /// line breaks and strips a leading UTF-8 BOM. Fully empty rows are dropped.
    static func parseRows(_ text: String) -> [[String]] {
        let characters = Array(text)
        var index = 0
        if characters.first == "\u{FEFF}" { index = 1 }
        let count = characters.count

        var rows: [[String]] = []
        var record: [String] = []
        var field = ""
        var inQuotes = false

        func endField() {
            record.append(field)
            field = ""
        }
        func endRecord() {
            endField()
            rows.append(record)
            record = []
        }

        while index < count {
            let character = characters[index]
            if inQuotes {
                if character == "\"" {
                    if index + 1 < count, characters[index + 1] == "\"" {
                        field.append("\"")
                        index += 2
                        continue
                    }
                    inQuotes = false
                    index += 1
                } else {
                    field.append(character)
                    index += 1
                }
            } else {
                switch character {
                case "\"":
                    inQuotes = true
                    index += 1
                case ",":
                    endField()
                    index += 1
                case "\r":
                    if index + 1 < count, characters[index + 1] == "\n" { index += 1 }
                    endRecord()
                    index += 1
                case "\n":
                    endRecord()
                    index += 1
                default:
                    field.append(character)
                    index += 1
                }
            }
        }
        // Flush a trailing field/record with no closing newline.
        if !field.isEmpty || !record.isEmpty { endRecord() }

        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }
}
