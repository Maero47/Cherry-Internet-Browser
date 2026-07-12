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
        // Fixed enum order keeps runs deterministic (bookmarks before history).
        for type in ImportableDataType.allCases where types.contains(type) && type.isSupported {
            statusText = "Reading \(type.displayName.lowercased()) from \(browser.displayName)…"
            do {
                let payload = try await Task.detached(priority: .userInitiated) {
                    try reader.read(type, from: profile)
                }.value

                statusText = "Importing \(type.displayName.lowercased())…"
                await Task.yield() // let the status line render before the write
                switch payload {
                case .bookmarks(let items):
                    let outcome = BookmarkRepository.shared.importBookmarks(items.map {
                        (url: $0.url,
                         title: $0.title,
                         folder: $0.folderPath.isEmpty ? nil : $0.folderPath.joined(separator: "/"),
                         isInBookmarkBar: $0.isInBookmarkBar)
                    })
                    result.bookmarksAdded += outcome.added
                    result.bookmarksSkipped += outcome.skipped
                case .history(let rows):
                    let outcome = HistoryRepository.shared.importHistoryItems(rows.map {
                        (url: $0.url, title: $0.title, visitDate: $0.lastVisit, visitCount: $0.visitCount)
                    })
                    result.historyAdded += outcome.added
                    result.historyMerged += outcome.merged
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
}
