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

    /// Speed tracking: bytes per second per download
    private(set) var speedMap: [UUID: Int64] = [:]

    /// ETA tracking: estimated seconds remaining per download
    private(set) var etaMap: [UUID: TimeInterval] = [:]

    /// Internal speed sampling state
    private var lastSpeedCheckTime: [UUID: Date] = [:]
    private var lastSpeedCheckBytes: [UUID: Int64] = [:]

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

    /// - Parameter isPrivate: the download was started from a private window.
    ///   Its source URL is then never written to Core Data — history already
    ///   guards private tabs this way, downloads did not, which quietly left a
    ///   permanent record of every private-window download on disk. The item
    ///   still shows up in the sidebar and the toast for this session.
    func startDownload(_ download: WKDownload, suggestedFilename: String, sourceURL: URL?, isPrivate: Bool) {
        let url = sourceURL ?? URL(string: "about:blank")!
        let item = isPrivate
            ? repository.addEphemeralDownload(url: url, filename: suggestedFilename)
            : repository.addDownload(url: url, filename: suggestedFilename)

        activeDownloads[item.id] = download
        progressMap[item.id] = (0, 0)
        lastSpeedCheckTime[item.id] = Date()
        lastSpeedCheckBytes[item.id] = 0

        // Observe the Foundation Progress on WKDownload
        let itemID = item.id
        let observation = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            Task { @MainActor in
                guard let self else { return }
                let total = progress.totalUnitCount
                let completed = progress.completedUnitCount
                self.progressMap[itemID] = (completed, total)
                self.repository.updateProgress(id: itemID, downloadedBytes: completed, totalBytes: total)
                self.updateSpeed(id: itemID, downloadedBytes: completed, totalBytes: total)
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
            cleanupSpeedState(id: id)
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
        cleanupSpeedState(id: id)
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

        // An installer or executable is one double-click away in the downloads
        // sidebar. Confirm before handing it to LaunchServices — Gatekeeper's
        // own prompt doesn't cover every one of these types.
        if DownloadQuarantine.isRisky(url) {
            let alert = NSAlert()
            alert.messageText = "Open “\(item.filename)”?"
            alert.informativeText = """
            This file can run programs on your Mac. It was downloaded from \
            \(item.url.host ?? item.url.absoluteString). Only open it if you trust that source.
            """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

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
        speedMap.removeAll()
        etaMap.removeAll()
        lastSpeedCheckTime.removeAll()
        lastSpeedCheckBytes.removeAll()
        repository.clearAllDownloads()
    }

    // MARK: - Internal: called by WKDownloadDelegate methods

    func downloadDidUpdateProgress(id: UUID, downloaded: Int64, total: Int64) {
        progressMap[id] = (downloaded, total)
        repository.updateProgress(id: id, downloadedBytes: downloaded, totalBytes: total)
    }

    func downloadDidFinish(id: UUID, at location: URL, finalFilename: String) {
        let destination = uniqueDestination(for: finalFilename)
        let sourceURL = repository.downloads.first(where: { $0.id == id })?.url

        do {
            try FileManager.default.moveItem(at: location, to: destination)
            DownloadQuarantine.apply(to: destination, sourceURL: sourceURL)
            repository.completeDownload(id: id, filePath: destination.path)
        } catch {
            print("Failed to move downloaded file: \(error)")
            repository.failDownload(id: id)
        }

        activeDownloads.removeValue(forKey: id)
        progressObservations.removeValue(forKey: id)
        progressMap.removeValue(forKey: id)
        cleanupSpeedState(id: id)

        lastCompletedDownloadID = id
        downloadCompletedTrigger += 1
    }

    /// Clean up active download state after the file has been moved externally (e.g. NSSavePanel flow)
    func downloadDidCleanup(id: UUID) {
        activeDownloads.removeValue(forKey: id)
        progressObservations.removeValue(forKey: id)
        progressMap.removeValue(forKey: id)
        cleanupSpeedState(id: id)
        lastCompletedDownloadID = id
        downloadCompletedTrigger += 1
    }

    func downloadDidFail(id: UUID, errorMessage: String? = nil) {
        activeDownloads.removeValue(forKey: id)
        progressObservations.removeValue(forKey: id)
        progressMap.removeValue(forKey: id)
        cleanupSpeedState(id: id)
        repository.failDownload(id: id, errorMessage: errorMessage)
    }

    /// Find download item id for a given WKDownload instance
    func itemID(for download: WKDownload) -> UUID? {
        activeDownloads.first(where: { $0.value === download })?.key
    }

    // MARK: - Retry

    func retryDownload(id: UUID) {
        guard let item = repository.downloads.first(where: { $0.id == id }),
              item.status == .failed else { return }
        let url = item.url
        // Remove the failed entry
        repository.deleteDownload(item)
        // Open the URL in the default browser webview to re-trigger the download
        NSWorkspace.shared.open(url)
    }

    // MARK: - Speed & ETA

    private func updateSpeed(id: UUID, downloadedBytes: Int64, totalBytes: Int64) {
        let now = Date()
        guard let lastTime = lastSpeedCheckTime[id],
              let lastBytes = lastSpeedCheckBytes[id] else { return }

        let elapsed = now.timeIntervalSince(lastTime)
        guard elapsed >= 0.5 else { return }

        let bytesDelta = downloadedBytes - lastBytes
        let bytesPerSecond = Int64(Double(bytesDelta) / elapsed)

        lastSpeedCheckTime[id] = now
        lastSpeedCheckBytes[id] = downloadedBytes

        speedMap[id] = max(bytesPerSecond, 0)

        if bytesPerSecond > 0 && totalBytes > 0 {
            let remaining = totalBytes - downloadedBytes
            etaMap[id] = TimeInterval(remaining) / TimeInterval(bytesPerSecond)
        } else {
            etaMap[id] = nil
        }
    }

    private func cleanupSpeedState(id: UUID) {
        speedMap.removeValue(forKey: id)
        etaMap.removeValue(forKey: id)
        lastSpeedCheckTime.removeValue(forKey: id)
        lastSpeedCheckBytes.removeValue(forKey: id)
    }

    func formattedSpeed(for id: UUID) -> String? {
        guard let bps = speedMap[id], bps > 0 else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: bps))/s"
    }

    func formattedETA(for id: UUID) -> String? {
        guard let eta = etaMap[id], eta.isFinite, eta > 0 else { return nil }
        let seconds = Int(eta)
        if seconds < 60 {
            return "\(seconds)s remaining"
        } else if seconds < 3600 {
            let mins = seconds / 60
            let secs = seconds % 60
            return "\(mins)m \(secs)s remaining"
        } else {
            let hours = seconds / 3600
            let mins = (seconds % 3600) / 60
            return "\(hours)h \(mins)m remaining"
        }
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
