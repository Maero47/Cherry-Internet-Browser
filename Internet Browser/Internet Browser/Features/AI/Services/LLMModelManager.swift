//
//  LLMModelManager.swift
//  Cherry Browser
//

import Foundation
import Observation

#if canImport(MLXLLM)
import MLXLMCommon
import Hub
#endif

/// Manages the on-device Qwen3-8B (4-bit) model weights used by the local MLX
/// engine: opt-in download from Hugging Face (via MLXLMCommon/Hub), presence
/// check, and download progress. Weights are stored under Application
/// Support — never the user's Downloads folder, and never through the
/// WKDownload-based `DownloadManager`. Download only ever starts when the
/// user explicitly requests it from Settings; a multi-gigabyte model is
/// never fetched silently.
///
/// `@MainActor`-isolated: every mutable property here (`isDownloading`,
/// `downloadFraction`, `totalBytes`, …) is read by SwiftUI on the main actor
/// while `download()`'s background work reports progress, so all state must be
/// mutated on the main actor to avoid a data race. The download's actual
/// network/disk work happens inside `Hub` (off the main actor); only the
/// `@Observable` state updates hop back here.
@MainActor
@Observable
final class LLMModelManager {
    static let shared = LLMModelManager()

    nonisolated static let modelID = "mlx-community/Qwen3-8B-4bit"

    /// Whether the MLX package is linked into this build at all — independent
    /// of whether the model weights have been downloaded yet. `PageAIService`
    /// uses this to distinguish "Qwen isn't available in this build" from
    /// "Qwen is available but the model hasn't been downloaded yet".
    nonisolated static var isMLXImportable: Bool {
        #if canImport(MLXLLM)
        true
        #else
        false
        #endif
    }

    private(set) var isDownloaded: Bool = false
    private(set) var isDownloading: Bool = false
    private(set) var downloadFraction: Double = 0
    private(set) var downloadedBytes: Int64 = 0
    private(set) var totalBytes: Int64 = 0
    private(set) var speedBytesPerSecond: Int64?
    private(set) var etaSeconds: TimeInterval?
    private(set) var errorMessage: String?

    private var downloadTask: Task<Void, Never>?

    nonisolated static var modelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CherryModels", isDirectory: true)
    }

    private init() {
        refreshDownloadedState()
    }

    // MARK: - Presence

    func refreshDownloadedState() {
        #if canImport(MLXLLM)
        isDownloaded = Self.weightsExistOnDisk()
        #else
        isDownloaded = false
        #endif
    }

    /// Pure logic (no I/O): does this set of filenames look like a complete,
    /// loadable model snapshot? Split out so it's unit-testable without
    /// touching the filesystem or network.
    nonisolated static func directoryLooksComplete(filenames: [String]) -> Bool {
        filenames.contains(where: { $0.hasSuffix(".safetensors") })
            && filenames.contains("config.json")
    }

    // MARK: - Download

    func download() {
        #if canImport(MLXLLM)
        guard !isDownloading, !isDownloaded else { return }
        isDownloading = true
        errorMessage = nil
        downloadFraction = 0
        downloadedBytes = 0
        totalBytes = 0
        speedBytesPerSecond = nil
        etaSeconds = nil

        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let hub = Self.hubApi
                let repo = Hub.Repo(id: Self.modelID)
                let globs = ["*.safetensors", "*.json"]

                let metadata = try await hub.getFileMetadata(from: repo, matching: globs)
                let total = metadata.reduce(Int64(0)) { $0 + Int64($1.size ?? 0) }
                self.totalBytes = total

                try await hub.snapshot(from: repo, matching: globs) { progress, speed in
                    Task { @MainActor in
                        self.applyProgress(fraction: progress.fractionCompleted, speed: speed)
                    }
                }

                try Task.checkCancellation()
                self.isDownloading = false
                self.refreshDownloadedState()
            } catch is CancellationError {
                self.isDownloading = false
            } catch {
                self.isDownloading = false
                self.errorMessage = error.localizedDescription
            }
        }
        #else
        errorMessage = "The local Qwen engine isn't available in this build."
        #endif
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
    }

    private func applyProgress(fraction: Double, speed: Double?) {
        downloadFraction = fraction
        if totalBytes > 0 {
            downloadedBytes = Int64(fraction * Double(totalBytes))
        }
        if let speed, speed > 0 {
            speedBytesPerSecond = Int64(speed)
            if totalBytes > 0 {
                let remaining = totalBytes - downloadedBytes
                etaSeconds = TimeInterval(remaining) / speed
            }
        }
    }

    // MARK: - Formatting (mirrors DownloadManager's speed/ETA presentation)

    var formattedProgressPercent: String {
        "\(Int(downloadFraction * 100))%"
    }

    var formattedDownloadedTotal: String? {
        guard totalBytes > 0 else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: downloadedBytes)) of \(formatter.string(fromByteCount: totalBytes))"
    }

    var formattedSpeed: String? {
        Self.formatSpeed(bytesPerSecond: speedBytesPerSecond)
    }

    var formattedETA: String? {
        Self.formatETA(seconds: etaSeconds)
    }

    /// Pure formatting logic, static + parameterized so it's unit-testable
    /// without a live `LLMModelManager` instance.
    nonisolated static func formatSpeed(bytesPerSecond: Int64?) -> String? {
        guard let bps = bytesPerSecond, bps > 0 else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: bps))/s"
    }

    nonisolated static func formatETA(seconds: TimeInterval?) -> String? {
        guard let eta = seconds, eta.isFinite, eta > 0 else { return nil }
        let totalSeconds = Int(eta)
        if totalSeconds < 60 {
            return "\(totalSeconds)s remaining"
        } else if totalSeconds < 3600 {
            let mins = totalSeconds / 60
            let secs = totalSeconds % 60
            return "\(mins)m \(secs)s remaining"
        } else {
            let hours = totalSeconds / 3600
            let mins = (totalSeconds % 3600) / 60
            return "\(hours)h \(mins)m remaining"
        }
    }

    #if canImport(MLXLLM)
    nonisolated static let hubApi: HubApi = HubApi(downloadBase: modelsDirectory)

    nonisolated static func weightsExistOnDisk() -> Bool {
        let repo = Hub.Repo(id: modelID)
        let dir = hubApi.localRepoLocation(repo)
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return false
        }
        return directoryLooksComplete(filenames: contents)
    }
    #endif
}
