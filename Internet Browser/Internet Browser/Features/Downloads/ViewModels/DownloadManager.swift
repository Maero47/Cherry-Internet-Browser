//
//  DownloadManager.swift
//  Cherry Browser
//

import Foundation
import WebKit
import Observation
import AppKit

@Observable
final class DownloadManager: NSObject {
    static let shared = DownloadManager()

    /// Active WKDownload instances keyed by DownloadItem id
    private var activeDownloads: [UUID: WKDownload] = [:]

    /// KVO observations for download progress
    private var progressObservations: [UUID: NSKeyValueObservation] = [:]

    /// Progress tracking: maps download id -> (downloadedBytes, totalBytes)
    private(set) var progressMap: [UUID: (downloaded: Int64, total: Int64)] = [:]

    /// The most recently started download ID (for toast display)
    private(set) var latestDownloadID: UUID?

    /// Incremented each time a download starts — observed by views to show toast
    private(set) var downloadStartedTrigger: Int = 0

    /// The most recently completed download ID
    private(set) var lastCompletedDownloadID: UUID?

    /// Incremented each time a download completes — observed by views to update toast
    private(set) var downloadCompletedTrigger: Int = 0

    private let repository = DownloadRepository.shared

    private var downloadsDirectory: URL {
        let dir = SettingsManager.shared.downloadDirectoryURL
        // Ensure the directory exists
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Number of currently active downloads
    var activeDownloadCount: Int {
        activeDownloads.count
    }

    override private init() {
        super.init()
    }

    // MARK: - Start Download

    func startDownload(_ download: WKDownload, suggestedFilename: String, sourceURL: URL?) {
        let url = sourceURL ?? URL(string: "about:blank")!
        let item = repository.addDownload(url: url, filename: suggestedFilename)

        activeDownloads[item.id] = download
        progressMap[item.id] = (0, 0)

        // Observe the Foundation Progress on WKDownload
        let itemID = item.id
        let observation = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            Task { @MainActor in
                guard let self else { return }
                let total = progress.totalUnitCount
                let completed = progress.completedUnitCount
                self.progressMap[itemID] = (completed, total)
                self.repository.updateProgress(id: itemID, downloadedBytes: completed, totalBytes: total)
            }
        }
        progressObservations[item.id] = observation

        latestDownloadID = item.id
        downloadStartedTrigger += 1
    }

    // MARK: - Cancel

    func cancelDownload(id: UUID) {
        if let download = activeDownloads[id] {
            download.cancel()
            activeDownloads.removeValue(forKey: id)
            progressObservations.removeValue(forKey: id)
            progressMap.removeValue(forKey: id)
        }
        repository.cancelDownload(id: id)

        // Remove partial file
        if let item = repository.downloads.first(where: { $0.id == id }),
           let filePath = item.filePath {
            try? FileManager.default.removeItem(atPath: filePath)
        }
    }

    // MARK: - Remove from list

    func removeDownload(id: UUID) {
        activeDownloads.removeValue(forKey: id)
        progressObservations.removeValue(forKey: id)
        progressMap.removeValue(forKey: id)
        if let item = repository.downloads.first(where: { $0.id == id }) {
            repository.deleteDownload(item)
        }
    }

    // MARK: - File Actions

    func revealInFinder(id: UUID) {
        guard let item = repository.downloads.first(where: { $0.id == id }),
              let filePath = item.filePath else { return }
        let url = URL(fileURLWithPath: filePath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openFile(id: UUID) {
        guard let item = repository.downloads.first(where: { $0.id == id }),
              let filePath = item.filePath else { return }
        let url = URL(fileURLWithPath: filePath)
        NSWorkspace.shared.open(url)
    }

    // MARK: - Clear All

    func clearAll() {
        for (id, download) in activeDownloads {
            download.cancel()
            progressMap.removeValue(forKey: id)
            progressObservations.removeValue(forKey: id)
        }
        activeDownloads.removeAll()
        progressObservations.removeAll()
        progressMap.removeAll()
        repository.clearAllDownloads()
    }

    // MARK: - Internal: called by WKDownloadDelegate methods

    func downloadDidUpdateProgress(id: UUID, downloaded: Int64, total: Int64) {
        progressMap[id] = (downloaded, total)
        repository.updateProgress(id: id, downloadedBytes: downloaded, totalBytes: total)
    }

    func downloadDidFinish(id: UUID, at location: URL, finalFilename: String) {
        let destination = uniqueDestination(for: finalFilename)

        do {
            try FileManager.default.moveItem(at: location, to: destination)
            repository.completeDownload(id: id, filePath: destination.path)
        } catch {
            print("Failed to move downloaded file: \(error)")
            repository.failDownload(id: id)
        }

        activeDownloads.removeValue(forKey: id)
        progressObservations.removeValue(forKey: id)
        progressMap.removeValue(forKey: id)

        lastCompletedDownloadID = id
        downloadCompletedTrigger += 1
    }

    /// Clean up active download state after the file has been moved externally (e.g. NSSavePanel flow)
    func downloadDidCleanup(id: UUID) {
        activeDownloads.removeValue(forKey: id)
        progressObservations.removeValue(forKey: id)
        progressMap.removeValue(forKey: id)
        lastCompletedDownloadID = id
        downloadCompletedTrigger += 1
    }

    func downloadDidFail(id: UUID) {
        activeDownloads.removeValue(forKey: id)
        progressObservations.removeValue(forKey: id)
        progressMap.removeValue(forKey: id)
        repository.failDownload(id: id)
    }

    /// Find download item id for a given WKDownload instance
    func itemID(for download: WKDownload) -> UUID? {
        activeDownloads.first(where: { $0.value === download })?.key
    }

    // MARK: - Helpers

    private func uniqueDestination(for filename: String) -> URL {
        let base = downloadsDirectory.appendingPathComponent(filename)
        if !FileManager.default.fileExists(atPath: base.path) {
            return base
        }

        let name = base.deletingPathExtension().lastPathComponent
        let ext = base.pathExtension
        var counter = 1

        while true {
            let suffix = ext.isEmpty ? "" : ".\(ext)"
            let candidate = downloadsDirectory.appendingPathComponent("\(name) (\(counter))\(suffix)")
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            counter += 1
        }
    }
}
