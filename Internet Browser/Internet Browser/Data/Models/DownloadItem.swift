//
//  DownloadItem.swift
//  Cherry Browser
//

import CoreData
import Foundation

@objc(DownloadEntity)
public class DownloadEntity: NSManagedObject {
    @NSManaged public var id: UUID
    @NSManaged public var url: String
    @NSManaged public var filename: String
    @NSManaged public var filePath: String?
    @NSManaged public var totalBytes: Int64
    @NSManaged public var downloadedBytes: Int64
    @NSManaged public var startDate: Date
    @NSManaged public var completionDate: Date?
    @NSManaged public var statusRaw: String
    @NSManaged public var errorMessage: String?
}

extension DownloadEntity {
    var status: DownloadStatus {
        get { DownloadStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }
}

// MARK: - Download Status

enum DownloadStatus: String {
    case pending
    case downloading
    case completed
    case failed
    case cancelled
}

// MARK: - DownloadItem Model (for use in views)

struct DownloadItem: Identifiable, Hashable {
    let id: UUID
    var url: URL
    var filename: String
    var filePath: String?
    var totalBytes: Int64
    var downloadedBytes: Int64
    var startDate: Date
    var completionDate: Date?
    var status: DownloadStatus
    var errorMessage: String?

    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(downloadedBytes) / Double(totalBytes)
    }

    var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        if totalBytes > 0 {
            return "\(formatter.string(fromByteCount: downloadedBytes)) / \(formatter.string(fromByteCount: totalBytes))"
        } else if downloadedBytes > 0 {
            return formatter.string(fromByteCount: downloadedBytes)
        }
        return ""
    }

    var isActive: Bool {
        status == .downloading || status == .pending
    }

    init(
        id: UUID = UUID(),
        url: URL,
        filename: String,
        filePath: String? = nil,
        totalBytes: Int64 = 0,
        downloadedBytes: Int64 = 0,
        startDate: Date = Date(),
        completionDate: Date? = nil,
        status: DownloadStatus = .pending,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.url = url
        self.filename = filename
        self.filePath = filePath
        self.totalBytes = totalBytes
        self.downloadedBytes = downloadedBytes
        self.startDate = startDate
        self.completionDate = completionDate
        self.status = status
        self.errorMessage = errorMessage
    }

    init(entity: DownloadEntity) {
        self.id = entity.id
        self.url = URL(string: entity.url) ?? URL(string: "about:blank")!
        self.filename = entity.filename
        self.filePath = entity.filePath
        self.totalBytes = entity.totalBytes
        self.downloadedBytes = entity.downloadedBytes
        self.startDate = entity.startDate
        self.completionDate = entity.completionDate
        self.status = entity.status
        self.errorMessage = entity.errorMessage
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: DownloadItem, rhs: DownloadItem) -> Bool {
        lhs.id == rhs.id
    }
}
