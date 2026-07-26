//
//  DownloadToastView.swift
//  Cherry Browser
//

import SwiftUI

struct DownloadToastView: View {
    var downloadManager: DownloadManager
    var downloadRepository: DownloadRepository
    let downloadID: UUID
    let isCompleted: Bool
    let onShowAll: () -> Void
    let onDismiss: () -> Void

    private var item: DownloadItem? {
        downloadRepository.downloads.first(where: { $0.id == downloadID })
    }

    private var progress: (downloaded: Int64, total: Int64)? {
        downloadManager.progressMap[downloadID]
    }

    private var activeCount: Int {
        downloadManager.activeDownloadCount
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                // File icon or status icon
                if isCompleted {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 18))
                } else {
                    fileIcon
                }

                VStack(alignment: .leading, spacing: 2) {
                    if activeCount > 1 {
                        Text("\(activeCount) downloads in progress")
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                    } else if let item {
                        Text(item.filename)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                    }

                    if isCompleted {
                        Text("Download complete")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 4) {
                            Text(progressText)
                            if let speed = downloadManager.formattedSpeed(for: downloadID) {
                                Text("— \(speed)")
                            }
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 4)

                // Dismiss button
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            // Progress bar for active downloads
            if !isCompleted, let prog = progress, prog.total > 0 {
                ProgressView(value: Double(prog.downloaded), total: Double(prog.total))
                    .progressViewStyle(.linear)
            }

            // Show All button
            HStack {
                Spacer()
                Button("Show All") {
                    onShowAll()
                }
                .font(.system(size: 11))
                .buttonStyle(.borderless)
            }
        }
        .padding(12)
        .frame(width: 280)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
        }
        .padding(.top, 8)
        .padding(.trailing, 8)
    }

    @ViewBuilder
    private var fileIcon: some View {
        let ext = ((item?.filename ?? "") as NSString).pathExtension.lowercased()
        let iconName: String = {
            switch ext {
            case "pdf": return "doc.richtext"
            case "zip", "gz", "tar", "rar", "7z": return "doc.zipper"
            case "jpg", "jpeg", "png", "gif", "svg", "webp": return "photo"
            case "mp4", "mov", "avi", "mkv", "webm": return "film"
            case "mp3", "wav", "aac", "flac", "m4a": return "music.note"
            case "dmg", "pkg", "app": return "internaldrive"
            default: return "arrow.down.circle"
            }
        }()

        Image(systemName: iconName)
            .font(.system(size: 18))
            .foregroundStyle(.secondary)
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
}
