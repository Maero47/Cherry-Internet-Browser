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

    /// Everything the UI shows: the persisted downloads plus the private-window
    /// ones, newest first.
    private(set) var downloads: [DownloadItem] = []

    private var persistedDownloads: [DownloadItem] = []

    /// Downloads started from a private window. They live here and nowhere
    /// else — no Core Data row, so the source URL never reaches disk — but
    /// they still appear in the sidebar and the toast for the session, because
    /// a download the user can't see isn't private, it's broken.
    private var ephemeralDownloads: [DownloadItem] = []

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
            persistedDownloads = entities.map { DownloadItem(entity: $0) }
            rebuildDownloads()
        } catch {
            print("Failed to fetch downloads: \(error)")
        }
    }

    private func rebuildDownloads() {
        downloads = (persistedDownloads + ephemeralDownloads)
            .sorted { $0.startDate > $1.startDate }
    }

    /// Applies `mutate` to a private-window download and returns true if the
    /// id belonged to one — every persisting method calls this first so a
    /// private download never falls through to Core Data.
    private func mutateEphemeral(id: UUID, _ mutate: (inout DownloadItem) -> Void) -> Bool {
        guard let index = ephemeralDownloads.firstIndex(where: { $0.id == id }) else { return false }
        mutate(&ephemeralDownloads[index])
        rebuildDownloads()
        return true
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

    /// In-memory counterpart of `addDownload` for private windows.
    @discardableResult
    func addEphemeralDownload(url: URL, filename: String) -> DownloadItem {
        let item = DownloadItem(url: url, filename: filename, status: .downloading)
        ephemeralDownloads.append(item)
        rebuildDownloads()
        return item
    }

    // MARK: - Update

    func updateProgress(id: UUID, downloadedBytes: Int64, totalBytes: Int64) {
        if mutateEphemeral(id: id, { item in
            item.downloadedBytes = downloadedBytes
            item.totalBytes = totalBytes
        }) { return }

        let context = persistence.viewContext
        let request = NSFetchRequest<DownloadEntity>(entityName: "DownloadEntity")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)

        do {
            if let entity = try context.fetch(request).first {
                entity.downloadedBytes = downloadedBytes
                entity.totalBytes = totalBytes
                persistence.save()
                // Update in-memory item directly for performance
                if let index = persistedDownloads.firstIndex(where: { $0.id == id }) {
                    persistedDownloads[index].downloadedBytes = downloadedBytes
                    persistedDownloads[index].totalBytes = totalBytes
                    rebuildDownloads()
                }
            }
        } catch {
            print("Failed to update download progress: \(error)")
        }
    }

    func completeDownload(id: UUID, filePath: String) {
        if mutateEphemeral(id: id, { item in
            item.status = .completed
            item.filePath = filePath
            item.completionDate = Date()
            item.downloadedBytes = item.totalBytes
        }) { return }

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
        if mutateEphemeral(id: id, { item in
            item.status = .failed
            item.completionDate = Date()
            item.errorMessage = errorMessage
        }) { return }

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
        if mutateEphemeral(id: id, { item in
            item.status = .cancelled
            item.completionDate = Date()
        }) { return }

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
        if ephemeralDownloads.contains(where: { $0.id == item.id }) {
            ephemeralDownloads.removeAll { $0.id == item.id }
            rebuildDownloads()
            return
        }

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
        ephemeralDownloads.removeAll()
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "DownloadEntity")

        do {
            try persistence.batchDelete(fetchRequest: request)
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
