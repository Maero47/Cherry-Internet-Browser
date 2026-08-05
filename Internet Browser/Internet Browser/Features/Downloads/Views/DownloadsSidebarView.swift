//
//  DownloadsSidebarView.swift
//  Cherry Browser
//

import SwiftUI
import Quartz

struct DownloadsSidebarView: View {
    @Bindable var repository: DownloadRepository
    let downloadManager: DownloadManager
    let onClose: () -> Void
    /// Private windows are never themed by an imported Firefox theme.
    var isPrivateMode: Bool = false

    @State private var searchText: String = ""
    @State private var showingClearAlert: Bool = false

    var filteredDownloads: [DownloadItem] {
        if searchText.isEmpty {
            return repository.downloads
        }
        return repository.searchDownloads(query: searchText)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Downloads")
                    .font(.headline)

                Spacer()

                if !repository.downloads.isEmpty {
                    Button(action: { showingClearAlert = true }) {
                        Text("Clear All")
                            .font(.subheadline)
                    }
                    .buttonStyle(.borderless)
                }

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search downloads", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(8)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider()

            // Downloads list
            if filteredDownloads.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("No downloads")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredDownloads) { item in
                        DownloadItemRow(
                            item: item,
                            progress: downloadManager.progressMap[item.id],
                            speedText: downloadManager.formattedSpeed(for: item.id),
                            etaText: downloadManager.formattedETA(for: item.id),
                            onOpen: { downloadManager.openFile(id: item.id) },
                            onReveal: { downloadManager.revealInFinder(id: item.id) },
                            onCancel: { downloadManager.cancelDownload(id: item.id) },
                            onRemove: { downloadManager.removeDownload(id: item.id) },
                            onQuickLook: {
                                if let path = item.filePath {
                                    DownloadQuickLookHelper.shared.previewFile(at: path)
                                }
                            },
                            onRetry: { downloadManager.retryDownload(id: item.id) }
                        )
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .foregroundStyle((isPrivateMode ? nil : FirefoxThemeManager.shared.sidebarText) ?? Color.primary)
        .background(
            (isPrivateMode ? nil : FirefoxThemeManager.shared.sidebarBackground)
                ?? Color(nsColor: .windowBackgroundColor)
        )
        .alert("Clear Downloads", isPresented: $showingClearAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) {
                downloadManager.clearAll()
            }
        } message: {
            Text("This will cancel active downloads and clear the downloads list.")
        }
    }
}

// MARK: - Download Item Row

struct DownloadItemRow: View {
    let item: DownloadItem
    let progress: (downloaded: Int64, total: Int64)?
    let speedText: String?
    let etaText: String?
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onCancel: () -> Void
    let onRemove: () -> Void
    let onQuickLook: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                // File icon
                fileIcon

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.filename)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)

                    if item.isActive {
                        // Size info during download
                        Text(progressText)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    } else if item.status == .failed, let errorMsg = item.errorMessage {
                        Text(errorMsg)
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    } else {
                        // Status text
                        Text(statusText)
                            .font(.system(size: 10))
                            .foregroundStyle(statusColor)
                    }
                }

                Spacer()

                // macOS refused to mark this file as downloaded-from-the-internet,
                // so opening it gets no Gatekeeper check. Say so.
                if item.status == .completed, DownloadManager.shared.isUnquarantined(id: item.id) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 12))
                        .help("Not marked as downloaded from the internet — this file will open without a Gatekeeper check.")
                }

                // Quick Look button for completed downloads
                if item.status == .completed, item.filePath != nil {
                    Button(action: onQuickLook) {
                        Image(systemName: "eye")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .help("Quick Look")
                }

                statusIcon
            }

            // Progress bar for active downloads
            if item.isActive, let prog = progress, prog.total > 0 {
                ProgressView(value: Double(prog.downloaded), total: Double(prog.total))
                    .progressViewStyle(.linear)

                // Speed & ETA
                if let speed = speedText {
                    HStack(spacing: 0) {
                        Text(speed)
                        if let eta = etaText {
                            Text(" — \(eta)")
                        }
                    }
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if item.status == .completed {
                onOpen()
            }
        }
        .cherryContextMenu {
            if item.status == .completed {
                CherryMenuItem.action("Open") { onOpen() }
                CherryMenuItem.action("Quick Look") { onQuickLook() }
                CherryMenuItem.action("Reveal in Finder") { onReveal() }
                CherryMenuItem.separator
            }
            if item.status == .failed {
                CherryMenuItem.action("Retry") { onRetry() }
                CherryMenuItem.separator
            }
            if item.isActive {
                CherryMenuItem.action("Cancel") { onCancel() }
                CherryMenuItem.separator
            }
            CherryMenuItem.action("Remove from List") { onRemove() }
        }
    }

    @ViewBuilder
    private var fileIcon: some View {
        let ext = (item.filename as NSString).pathExtension.lowercased()
        let iconName: String = {
            switch ext {
            case "pdf": return "doc.richtext"
            case "zip", "gz", "tar", "rar", "7z": return "doc.zipper"
            case "jpg", "jpeg", "png", "gif", "svg", "webp": return "photo"
            case "mp4", "mov", "avi", "mkv", "webm": return "film"
            case "mp3", "wav", "aac", "flac", "m4a": return "music.note"
            case "dmg", "pkg", "app": return "internaldrive"
            default: return "doc"
            }
        }()

        Image(systemName: iconName)
            .font(.system(size: 16))
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 14))
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 14))
        case .cancelled:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
                .font(.system(size: 14))
        case .downloading, .pending:
            Button(action: onCancel) {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .help("Cancel download")
        }
    }

    private var progressText: String {
        guard let prog = progress else { return "Starting..." }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        if prog.total > 0 {
            return "\(formatter.string(fromByteCount: prog.downloaded)) of \(formatter.string(fromByteCount: prog.total))"
        } else if prog.downloaded > 0 {
            return "\(formatter.string(fromByteCount: prog.downloaded)) downloaded"
        }
        return "Starting..."
    }

    private var statusText: String {
        switch item.status {
        case .completed:
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return item.totalBytes > 0 ? formatter.string(fromByteCount: item.totalBytes) : "Completed"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        case .downloading, .pending:
            return "Downloading..."
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .completed: return .secondary
        case .failed: return .red
        case .cancelled: return .secondary
        case .downloading, .pending: return .secondary
        }
    }
}
