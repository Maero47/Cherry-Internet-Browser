//
//  ImportModels.swift
//  Cherry Browser
//
//  Shared model types for importing data from other browsers.
//

import Foundation
import Security

// MARK: - Importable data types

/// The kinds of data Cherry can (or will be able to) import from another
/// browser. Adding a new kind (e.g. passwords) means adding a case here,
/// a payload case in `ImportedPayload`, and reader support — the engine
/// and UI iterate over this enum rather than hard-coding types.
enum ImportableDataType: String, CaseIterable, Identifiable, Sendable {
    case bookmarks
    case history
    case passwords

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bookmarks: "Bookmarks"
        case .history: "History"
        case .passwords: "Passwords"
        }
    }

    var icon: String {
        switch self {
        case .bookmarks: "star"
        case .history: "clock.arrow.circlepath"
        case .passwords: "key.fill"
        }
    }

    /// Whether the current import engine can actually import this type.
    var isSupported: Bool {
        switch self {
        case .bookmarks, .history, .passwords: true
        }
    }
}

// MARK: - Source browsers

/// Browsers Cherry knows how to import from.
enum SourceBrowser: String, CaseIterable, Identifiable, Sendable {
    case chrome
    case brave
    case edge
    case firefox
    case safari

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chrome: "Google Chrome"
        case .brave: "Brave"
        case .edge: "Microsoft Edge"
        case .firefox: "Firefox"
        case .safari: "Safari"
        }
    }

    var icon: String {
        switch self {
        case .chrome: "globe"
        case .brave: "shield.lefthalf.filled"
        case .edge: "e.circle"
        case .firefox: "flame"
        case .safari: "safari"
        }
    }

    /// True for the Chromium family (same on-disk formats).
    var isChromium: Bool {
        switch self {
        case .chrome, .brave, .edge: true
        case .firefox, .safari: false
        }
    }
}

// MARK: - Detected sources

/// One profile of a detected source browser.
struct SourceProfile: Identifiable, Hashable, Sendable {
    /// Stable identifier (the profile directory name, or "Safari").
    let id: String
    /// Human-readable name shown in the picker (e.g. "Mehmet Ali (Default)").
    let displayName: String
    /// The profile directory containing the data files.
    let directory: URL
    /// Which data types have a readable-looking source file in this profile.
    let availableTypes: Set<ImportableDataType>
}

/// An installed browser plus its discovered profiles.
struct DetectedSource: Identifiable, Sendable {
    let browser: SourceBrowser
    let profiles: [SourceProfile]
    var id: String { browser.id }
}

// MARK: - Parsed records

/// A bookmark parsed from a source browser, before writing into Cherry.
struct ImportedBookmark: Sendable {
    let url: URL
    let title: String
    /// Folder chain from the source, outermost first (e.g. ["Dev", "Swift"]).
    /// Empty for top-level items. Flattened to "Dev/Swift" when written,
    /// because Cherry's bookmark model has a single flat folder name.
    let folderPath: [String]
    /// True for items sitting directly on the source's bookmarks bar.
    let isInBookmarkBar: Bool
    /// Encoded icon bytes (PNG) matched from the source browser's favicon
    /// store, attached by the import engine after reading. Nil when the
    /// store has no icon for this URL.
    var favicon: Data? = nil
}

/// A history entry parsed from a source browser, aggregated per URL.
struct ImportedHistoryRow: Sendable {
    let url: URL
    let title: String
    /// The real most-recent visit time from the source browser.
    let lastVisit: Date
    let visitCount: Int
    /// Encoded icon bytes (PNG) matched from the source browser's favicon
    /// store, attached by the import engine after reading.
    var favicon: Data? = nil
}

/// A saved credential parsed from a source browser (decrypted Chromium
/// `Login Data`, or a CSV export), before writing into Cherry.
struct ImportedCredential: Sendable {
    /// The origin/login URL string as stored by the source (kept verbatim —
    /// Cherry's password store keys on the raw string, not a parsed URL).
    let url: String
    let username: String
    let password: String
}

/// What a reader produced for one data type. New importable types add a
/// case here (e.g. `passwords([ImportedCredential])`).
enum ImportedPayload: Sendable {
    case bookmarks([ImportedBookmark])
    case history([ImportedHistoryRow])
    case passwords([ImportedCredential])
}

// MARK: - Reader protocol

/// Reads one data type from one profile of a source browser. Implementations
/// must be read-only with respect to the source files (copy to temp before
/// opening anything SQLite).
protocol BrowserDataReader: Sendable {
    func read(_ type: ImportableDataType, from profile: SourceProfile) throws -> ImportedPayload

    /// Loads the profile's favicon store for attaching icons to imported
    /// records. Best-effort: browsers without a readable store (Safari)
    /// return `.empty`, and failures must never throw.
    func readFavicons(from profile: SourceProfile) -> ImportedFaviconStore
}

extension BrowserDataReader {
    func readFavicons(from profile: SourceProfile) -> ImportedFaviconStore { .empty }
}

extension ImportedPayload {
    /// Returns the payload with each record's `favicon` filled from `store`
    /// (exact page URL first, then host). Passwords pass through unchanged.
    func attachingFavicons(from store: ImportedFaviconStore) -> ImportedPayload {
        guard !store.isEmpty else { return self }
        switch self {
        case .bookmarks(let items):
            return .bookmarks(items.map { item in
                var item = item
                item.favicon = store.icon(for: item.url)
                return item
            })
        case .history(let rows):
            return .history(rows.map { row in
                var row = row
                row.favicon = store.icon(for: row.url)
                return row
            })
        case .passwords:
            return self
        }
    }
}

extension SourceBrowser {
    /// The reader that understands this browser's on-disk formats.
    var reader: BrowserDataReader {
        switch self {
        case .chrome: ChromiumImportReader(brand: .chrome)
        case .brave: ChromiumImportReader(brand: .brave)
        case .edge: ChromiumImportReader(brand: .edge)
        case .firefox: FirefoxImportReader()
        case .safari: SafariImportReader()
        }
    }
}

// MARK: - Errors and results

enum ImportError: LocalizedError {
    /// Reading `~/Library/Safari` was denied by TCC.
    case fullDiskAccessRequired
    case sourceFileMissing(String)
    case unsupportedDataType(ImportableDataType)
    case databaseError(String)
    case parseError(String)
    /// The browser's Safe-Storage Keychain secret could not be read (user
    /// denied/cancelled the prompt, or no such item). Carries the OSStatus.
    case keychainAccessDenied(browser: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .fullDiskAccessRequired:
            "Grant Cherry Full Disk Access in System Settings → Privacy & Security → Full Disk Access, then retry."
        case .sourceFileMissing(let name):
            "Could not find \(name)."
        case .unsupportedDataType(let type):
            "Importing \(type.displayName.lowercased()) is not supported yet."
        case .databaseError(let message):
            "Database error: \(message)"
        case .parseError(let message):
            "Could not parse source data: \(message)"
        case .keychainAccessDenied(let browser, let status):
            switch status {
            case errSecItemNotFound:
                "No saved-password key was found for \(browser). Open \(browser) and save a password first, or import via CSV."
            case errSecUserCanceled:
                "Access to \(browser)'s saved-password key was cancelled. Cherry needs Keychain permission to decrypt \(browser) passwords — try again and click Allow, or import via CSV."
            default:
                "macOS denied access to \(browser)'s saved-password key (Keychain status \(status)). Click Allow when prompted, or import via CSV."
            }
        }
    }

    /// Maps a thrown error to `.fullDiskAccessRequired` when it looks like a
    /// TCC permission denial (Cocoa NSFileRead*Permission or POSIX EPERM/EACCES).
    static func wrapping(_ error: Error) -> ImportError {
        if let importError = error as? ImportError { return importError }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSFileReadNoPermissionError || nsError.code == NSFileReadUnknownError {
            let underlying = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError)
            if underlying == nil || underlying?.domain == NSPOSIXErrorDomain,
               underlying == nil || underlying?.code == Int(EPERM) || underlying?.code == Int(EACCES) {
                return .fullDiskAccessRequired
            }
        }
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(EPERM) || nsError.code == Int(EACCES) {
            return .fullDiskAccessRequired
        }
        return .databaseError(nsError.localizedDescription)
    }
}

/// Outcome of one import run, for the summary UI.
struct ImportResult: Sendable {
    let browserName: String
    var bookmarksAdded = 0
    var bookmarksSkipped = 0
    /// How many imported bookmarks carried a site icon from the source.
    var bookmarkFavicons = 0
    var historyAdded = 0
    var historyMerged = 0
    /// How many imported history entries carried a site icon from the source.
    var historyFavicons = 0
    var passwordsAdded = 0
    var passwordsSkipped = 0
    var errors: [String] = []
    var needsFullDiskAccess = false

    var summaryLines: [String] {
        var lines: [String] = []
        if bookmarksAdded > 0 || bookmarksSkipped > 0 {
            var line = "Imported \(bookmarksAdded.formatted()) bookmark\(bookmarksAdded == 1 ? "" : "s")"
            var notes: [String] = []
            if bookmarkFavicons > 0 { notes.append("\(bookmarkFavicons.formatted()) with site icons") }
            if bookmarksSkipped > 0 { notes.append("\(bookmarksSkipped.formatted()) already existed") }
            if !notes.isEmpty { line += " (\(notes.joined(separator: ", ")))" }
            lines.append(line)
        }
        if historyAdded > 0 || historyMerged > 0 {
            var line = "Imported \(historyAdded.formatted()) history entr\(historyAdded == 1 ? "y" : "ies")"
            var notes: [String] = []
            if historyFavicons > 0 { notes.append("\(historyFavicons.formatted()) with site icons") }
            if historyMerged > 0 { notes.append("\(historyMerged.formatted()) merged with existing") }
            if !notes.isEmpty { line += " (\(notes.joined(separator: ", ")))" }
            lines.append(line)
        }
        if passwordsAdded > 0 || passwordsSkipped > 0 {
            var line = "Imported \(passwordsAdded.formatted()) password\(passwordsAdded == 1 ? "" : "s")"
            if passwordsSkipped > 0 { line += " (\(passwordsSkipped.formatted()) already existed)" }
            lines.append(line)
        }
        if lines.isEmpty && errors.isEmpty {
            lines.append("Nothing new to import from \(browserName).")
        }
        return lines
    }
}

// MARK: - Epoch conversions

enum BrowserEpoch {
    /// Seconds between 1601-01-01 (Windows/Chrome epoch) and 1970-01-01 (Unix).
    static let windowsToUnixSeconds: Double = 11_644_473_600

    /// Chromium `last_visit_time`: microseconds since 1601-01-01 UTC.
    static func dateFromChromium(microseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(microseconds) / 1_000_000 - windowsToUnixSeconds)
    }

    /// Firefox `visit_date`: microseconds since 1970-01-01 UTC.
    static func dateFromFirefox(microseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(microseconds) / 1_000_000)
    }

    /// Safari `visit_time`: CFAbsoluteTime, seconds since 2001-01-01 UTC.
    static func dateFromSafari(seconds: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }
}

// MARK: - URL filtering

extension ImportableDataType {
    /// Schemes that never make sense to import (browser-internal pages).
    static let internalSchemes: Set<String> = [
        "chrome", "chrome-extension", "chrome-native", "chrome-search",
        "brave", "edge", "devtools", "about", "javascript", "data",
        "view-source", "moz-extension", "place", "file"
    ]
}

/// True when a source URL string is worth importing (non-empty, parseable,
/// not a browser-internal scheme).
func isImportableSourceURL(_ string: String) -> URL? {
    guard !string.isEmpty, let url = URL(string: string), let scheme = url.scheme?.lowercased() else { return nil }
    guard !ImportableDataType.internalSchemes.contains(scheme) else { return nil }
    return url
}
