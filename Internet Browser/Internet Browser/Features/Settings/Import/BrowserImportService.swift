//
//  BrowserImportService.swift
//  Cherry Browser
//
//  Orchestrates an import run: detects installed source browsers, reads the
//  chosen data types off the main thread via the per-browser readers, and
//  writes the results into Cherry's repositories on the main actor (their
//  Core Data view context). One data type failing never aborts the others;
//  per-record resilience lives in the readers themselves.
//

import Foundation
import Observation

@MainActor
@Observable
final class BrowserImportService {

    private(set) var sources: [DetectedSource] = []
    private(set) var isDetecting = false
    private(set) var isImporting = false
    /// Short progress line shown next to the spinner while importing.
    private(set) var statusText = ""
    private(set) var lastResult: ImportResult?

    // MARK: - Detection

    func detectSources() async {
        isDetecting = true
        let detector = BrowserSourceDetector()
        sources = await Task.detached(priority: .userInitiated) {
            detector.detectSources()
        }.value
        isDetecting = false
    }

    // MARK: - Import

    /// Imports the selected data types from one profile of one browser.
    /// Progress is published via `statusText`; the outcome via `lastResult`.
    func runImport(browser: SourceBrowser, profile: SourceProfile, types: Set<ImportableDataType>) async {
        guard !isImporting else { return }
        isImporting = true
        lastResult = nil
        var result = ImportResult(browserName: browser.displayName)

        let reader = browser.reader

        // Load the source's favicon store once per run so imported records
        // can carry their site icons. Best-effort: an unreadable store is
        // just empty and the import proceeds icon-less.
        let iconCarryingTypes: Set<ImportableDataType> = [.bookmarks, .history]
        var faviconStore = ImportedFaviconStore.empty
        if !types.intersection(iconCarryingTypes).isEmpty {
            statusText = "Reading site icons from \(browser.displayName)…"
            faviconStore = await Task.detached(priority: .userInitiated) {
                reader.readFavicons(from: profile)
            }.value
        }

        // Fixed enum order keeps runs deterministic (bookmarks before history).
        for type in ImportableDataType.allCases where types.contains(type) && type.isSupported {
            statusText = "Reading \(type.displayName.lowercased()) from \(browser.displayName)…"
            do {
                let payload = try await Task.detached(priority: .userInitiated) { [faviconStore] in
                    try reader.read(type, from: profile).attachingFavicons(from: faviconStore)
                }.value

                statusText = "Importing \(type.displayName.lowercased())…"
                await Task.yield() // let the status line render before the write
                switch payload {
                case .bookmarks(let items):
                    let outcome = BookmarkRepository.shared.importBookmarks(items.map {
                        (url: $0.url,
                         title: $0.title,
                         favicon: $0.favicon,
                         folder: $0.folderPath.isEmpty ? nil : $0.folderPath.joined(separator: "/"),
                         isInBookmarkBar: $0.isInBookmarkBar)
                    })
                    result.bookmarksAdded += outcome.added
                    result.bookmarksSkipped += outcome.skipped
                    result.bookmarkFavicons += outcome.withFavicons
                case .history(let rows):
                    let outcome = HistoryRepository.shared.importHistoryItems(rows.map {
                        (url: $0.url, title: $0.title, favicon: $0.favicon, visitDate: $0.lastVisit, visitCount: $0.visitCount)
                    })
                    result.historyAdded += outcome.added
                    result.historyMerged += outcome.merged
                    result.historyFavicons += outcome.withFavicons
                case .passwords(let credentials):
                    let outcome = PasswordRepository.shared.importCredentials(credentials.map {
                        (url: $0.url, username: $0.username, password: $0.password)
                    })
                    result.passwordsAdded += outcome.added
                    result.passwordsSkipped += outcome.skipped
                }
            } catch {
                let importError = ImportError.wrapping(error)
                if case .fullDiskAccessRequired = importError {
                    result.needsFullDiskAccess = true
                }
                result.errors.append("\(type.displayName): \(importError.localizedDescription)")
            }
        }

        statusText = ""
        lastResult = result
        isImporting = false
    }

    // MARK: - CSV import

    /// Imports passwords from a user-chosen CSV export (any browser). The file
    /// is read and parsed off-main; the repository write happens on the main
    /// actor. Progress via `statusText`, outcome via `lastResult`.
    func importCSV(from fileURL: URL) async {
        guard !isImporting else { return }
        isImporting = true
        lastResult = nil
        statusText = "Reading \(fileURL.lastPathComponent)…"
        var result = ImportResult(browserName: fileURL.lastPathComponent)

        do {
            let credentials = try await Task.detached(priority: .userInitiated) {
                let text = try Self.readText(fileURL)
                return PasswordCSV.credentials(from: text)
            }.value

            statusText = "Importing passwords…"
            await Task.yield()
            let outcome = PasswordRepository.shared.importCredentials(credentials.map {
                (url: $0.url, username: $0.username, password: $0.password)
            })
            result.passwordsAdded += outcome.added
            result.passwordsSkipped += outcome.skipped
        } catch {
            let importError = ImportError.wrapping(error)
            if case .fullDiskAccessRequired = importError { result.needsFullDiskAccess = true }
            result.errors.append("CSV: \(importError.localizedDescription)")
        }

        statusText = ""
        lastResult = result
        isImporting = false
    }

    /// Reads a CSV file as text, trying UTF-8 then falling back to encodings a
    /// browser export might use (UTF-16 with BOM, ISO-Latin-1).
    private nonisolated static func readText(_ fileURL: URL) throws -> String {
        let data = try Data(contentsOf: fileURL)
        for encoding: String.Encoding in [.utf8, .utf16, .isoLatin1] {
            if let text = String(data: data, encoding: encoding) { return text }
        }
        throw ImportError.parseError("the CSV file is not valid text")
    }
}
