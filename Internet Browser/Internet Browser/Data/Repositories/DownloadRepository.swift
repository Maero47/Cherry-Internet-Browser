//
//  DownloadRepository.swift
//  Cherry Browser
//

import CoreData
import Foundation
import Observation

@Observable
final class DownloadRepository {
    static let shared = DownloadRepository()

    private let persistence = PersistenceController.shared
    private(set) var downloads: [DownloadItem] = []

    init() {
        fetchDownloads()
    }

    // MARK: - Fetch

    func fetchDownloads() {
        let context = persistence.viewContext
        let request = NSFetchRequest<DownloadEntity>(entityName: "DownloadEntity")
        request.sortDescriptors = [
            NSSortDescriptor(key: "startDate", ascending: false)
        ]

        do {
            let entities = try context.fetch(request)
            downloads = entities.map { DownloadItem(entity: $0) }
        } catch {
            print("Failed to fetch downloads: \(error)")
        }
    }

    // MARK: - Add

    @discardableResult
    func addDownload(url: URL, filename: String) -> DownloadItem {
        let context = persistence.viewContext

        let entity = DownloadEntity(context: context)
        entity.id = UUID()
        entity.url = url.absoluteString
        entity.filename = filename
        entity.totalBytes = 0
        entity.downloadedBytes = 0
        entity.startDate = Date()
        entity.status = .downloading

        persistence.save()
        fetchDownloads()

        return DownloadItem(entity: entity)
    }

    // MARK: - Update

    func updateProgress(id: UUID, downloadedBytes: Int64, totalBytes: Int64) {
        let context = persistence.viewContext
        let request = NSFetchRequest<DownloadEntity>(entityName: "DownloadEntity")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)

        do {
            if let entity = try context.fetch(request).first {
                entity.downloadedBytes = downloadedBytes
                entity.totalBytes = totalBytes
                persistence.save()
                // Update in-memory item directly for performance
                if let index = downloads.firstIndex(where: { $0.id == id }) {
                    downloads[index].downloadedBytes = downloadedBytes
                    downloads[index].totalBytes = totalBytes
                }
            }
        } catch {
            print("Failed to update download progress: \(error)")
        }
    }

    func completeDownload(id: UUID, filePath: String) {
        let context = persistence.viewContext
        let request = NSFetchRequest<DownloadEntity>(entityName: "DownloadEntity")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)

        do {
            if let entity = try context.fetch(request).first {
                entity.status = .completed
                entity.filePath = filePath
                entity.completionDate = Date()
                entity.downloadedBytes = entity.totalBytes
                persistence.save()
                fetchDownloads()
            }
        } catch {
            print("Failed to complete download: \(error)")
        }
    }

    func failDownload(id: UUID, errorMessage: String? = nil) {
        let context = persistence.viewContext
        let request = NSFetchRequest<DownloadEntity>(entityName: "DownloadEntity")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)

        do {
            if let entity = try context.fetch(request).first {
                entity.status = .failed
                entity.completionDate = Date()
                entity.errorMessage = errorMessage
                persistence.save()
                fetchDownloads()
            }
        } catch {
            print("Failed to mark download as failed: \(error)")
        }
    }

    func cancelDownload(id: UUID) {
        let context = persistence.viewContext
        let request = NSFetchRequest<DownloadEntity>(entityName: "DownloadEntity")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)

        do {
            if let entity = try context.fetch(request).first {
                entity.status = .cancelled
                entity.completionDate = Date()
                persistence.save()
                fetchDownloads()
            }
        } catch {
            print("Failed to cancel download: \(error)")
        }
    }

    // MARK: - Delete

    func deleteDownload(_ item: DownloadItem) {
        let context = persistence.viewContext
        let request = NSFetchRequest<DownloadEntity>(entityName: "DownloadEntity")
        request.predicate = NSPredicate(format: "id == %@", item.id as CVarArg)

        do {
            if let entity = try context.fetch(request).first {
                context.delete(entity)
                persistence.save()
                fetchDownloads()
            }
        } catch {
            print("Failed to delete download: \(error)")
        }
    }

    func clearAllDownloads() {
        let context = persistence.viewContext
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "DownloadEntity")
        let deleteRequest = NSBatchDeleteRequest(fetchRequest: request)

        do {
            try context.execute(deleteRequest)
            persistence.save()
            fetchDownloads()
        } catch {
            print("Failed to clear all downloads: \(error)")
        }
    }

    // MARK: - Search

    func searchDownloads(query: String) -> [DownloadItem] {
        guard !query.isEmpty else { return downloads }

        let lowercasedQuery = query.lowercased()
        return downloads.filter { item in
            item.filename.lowercased().contains(lowercasedQuery) ||
            item.url.absoluteString.lowercased().contains(lowercasedQuery)
        }
    }
}
