//
//  PersistenceController.swift
//  Cherry Browser
//

import CoreData
import Foundation

final class PersistenceController: @unchecked Sendable {
    static let shared = PersistenceController()

    let container: NSPersistentContainer

    var viewContext: NSManagedObjectContext {
        container.viewContext
    }

    init(inMemory: Bool = false) {
        // Create the managed object model programmatically
        let model = Self.createManagedObjectModel()
        container = NSPersistentContainer(name: "CherryBrowser", managedObjectModel: model)

        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        } else {
            // Store in Application Support
            let storeURL = Self.storeURL
            container.persistentStoreDescriptions.first?.url = storeURL
        }

        container.loadPersistentStores { _, error in
            if let error = error as NSError? {
                // Log error but don't crash - browser should still work without persistence
                print("Core Data error: \(error), \(error.userInfo)")
            }
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    private static var storeURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let browserDir = appSupport.appendingPathComponent("Cherry", isDirectory: true)

        // Create directory if needed
        try? FileManager.default.createDirectory(at: browserDir, withIntermediateDirectories: true)

        return browserDir.appendingPathComponent("CherryBrowser.sqlite")
    }

    // MARK: - Core Data Model

    private static func createManagedObjectModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        // Bookmark Entity
        let bookmarkEntity = NSEntityDescription()
        bookmarkEntity.name = "BookmarkEntity"
        bookmarkEntity.managedObjectClassName = "BookmarkEntity"

        let bookmarkID = NSAttributeDescription()
        bookmarkID.name = "id"
        bookmarkID.attributeType = .UUIDAttributeType
        bookmarkID.isOptional = false

        let bookmarkURL = NSAttributeDescription()
        bookmarkURL.name = "url"
        bookmarkURL.attributeType = .stringAttributeType
        bookmarkURL.isOptional = false

        let bookmarkTitle = NSAttributeDescription()
        bookmarkTitle.name = "title"
        bookmarkTitle.attributeType = .stringAttributeType
        bookmarkTitle.isOptional = false

        let bookmarkFavicon = NSAttributeDescription()
        bookmarkFavicon.name = "faviconData"
        bookmarkFavicon.attributeType = .binaryDataAttributeType
        bookmarkFavicon.isOptional = true

        let bookmarkFolder = NSAttributeDescription()
        bookmarkFolder.name = "folder"
        bookmarkFolder.attributeType = .stringAttributeType
        bookmarkFolder.isOptional = true

        let bookmarkCreatedAt = NSAttributeDescription()
        bookmarkCreatedAt.name = "createdAt"
        bookmarkCreatedAt.attributeType = .dateAttributeType
        bookmarkCreatedAt.isOptional = false

        let bookmarkVisitCount = NSAttributeDescription()
        bookmarkVisitCount.name = "visitCount"
        bookmarkVisitCount.attributeType = .integer32AttributeType
        bookmarkVisitCount.isOptional = false
        bookmarkVisitCount.defaultValue = 0

        let bookmarkSortOrder = NSAttributeDescription()
        bookmarkSortOrder.name = "sortOrder"
        bookmarkSortOrder.attributeType = .integer32AttributeType
        bookmarkSortOrder.isOptional = false
        bookmarkSortOrder.defaultValue = 0

        let bookmarkIsInBar = NSAttributeDescription()
        bookmarkIsInBar.name = "isInBookmarkBar"
        bookmarkIsInBar.attributeType = .booleanAttributeType
        bookmarkIsInBar.isOptional = false
        bookmarkIsInBar.defaultValue = false

        bookmarkEntity.properties = [
            bookmarkID, bookmarkURL, bookmarkTitle, bookmarkFavicon,
            bookmarkFolder, bookmarkCreatedAt, bookmarkVisitCount,
            bookmarkSortOrder, bookmarkIsInBar
        ]

        // History Entity
        let historyEntity = NSEntityDescription()
        historyEntity.name = "HistoryEntity"
        historyEntity.managedObjectClassName = "HistoryEntity"

        let historyID = NSAttributeDescription()
        historyID.name = "id"
        historyID.attributeType = .UUIDAttributeType
        historyID.isOptional = false

        let historyURL = NSAttributeDescription()
        historyURL.name = "url"
        historyURL.attributeType = .stringAttributeType
        historyURL.isOptional = false

        let historyTitle = NSAttributeDescription()
        historyTitle.name = "title"
        historyTitle.attributeType = .stringAttributeType
        historyTitle.isOptional = false

        let historyFavicon = NSAttributeDescription()
        historyFavicon.name = "faviconData"
        historyFavicon.attributeType = .binaryDataAttributeType
        historyFavicon.isOptional = true

        let historyVisitDate = NSAttributeDescription()
        historyVisitDate.name = "visitDate"
        historyVisitDate.attributeType = .dateAttributeType
        historyVisitDate.isOptional = false

        let historyVisitCount = NSAttributeDescription()
        historyVisitCount.name = "visitCount"
        historyVisitCount.attributeType = .integer32AttributeType
        historyVisitCount.isOptional = false
        historyVisitCount.defaultValue = 1

        historyEntity.properties = [
            historyID, historyURL, historyTitle, historyFavicon,
            historyVisitDate, historyVisitCount
        ]

        // Shortcut Entity (for homepage)
        let shortcutEntity = NSEntityDescription()
        shortcutEntity.name = "ShortcutEntity"
        shortcutEntity.managedObjectClassName = "ShortcutEntity"

        let shortcutID = NSAttributeDescription()
        shortcutID.name = "id"
        shortcutID.attributeType = .UUIDAttributeType
        shortcutID.isOptional = false

        let shortcutURL = NSAttributeDescription()
        shortcutURL.name = "url"
        shortcutURL.attributeType = .stringAttributeType
        shortcutURL.isOptional = false

        let shortcutTitle = NSAttributeDescription()
        shortcutTitle.name = "title"
        shortcutTitle.attributeType = .stringAttributeType
        shortcutTitle.isOptional = false

        let shortcutFavicon = NSAttributeDescription()
        shortcutFavicon.name = "faviconData"
        shortcutFavicon.attributeType = .binaryDataAttributeType
        shortcutFavicon.isOptional = true

        let shortcutSortOrder = NSAttributeDescription()
        shortcutSortOrder.name = "sortOrder"
        shortcutSortOrder.attributeType = .integer32AttributeType
        shortcutSortOrder.isOptional = false
        shortcutSortOrder.defaultValue = 0

        shortcutEntity.properties = [
            shortcutID, shortcutURL, shortcutTitle, shortcutFavicon, shortcutSortOrder
        ]

        // Download Entity
        let downloadEntity = NSEntityDescription()
        downloadEntity.name = "DownloadEntity"
        downloadEntity.managedObjectClassName = "DownloadEntity"

        let downloadID = NSAttributeDescription()
        downloadID.name = "id"
        downloadID.attributeType = .UUIDAttributeType
        downloadID.isOptional = false

        let downloadURL = NSAttributeDescription()
        downloadURL.name = "url"
        downloadURL.attributeType = .stringAttributeType
        downloadURL.isOptional = false

        let downloadFilename = NSAttributeDescription()
        downloadFilename.name = "filename"
        downloadFilename.attributeType = .stringAttributeType
        downloadFilename.isOptional = false

        let downloadFilePath = NSAttributeDescription()
        downloadFilePath.name = "filePath"
        downloadFilePath.attributeType = .stringAttributeType
        downloadFilePath.isOptional = true

        let downloadTotalBytes = NSAttributeDescription()
        downloadTotalBytes.name = "totalBytes"
        downloadTotalBytes.attributeType = .integer64AttributeType
        downloadTotalBytes.isOptional = false
        downloadTotalBytes.defaultValue = Int64(0)

        let downloadDownloadedBytes = NSAttributeDescription()
        downloadDownloadedBytes.name = "downloadedBytes"
        downloadDownloadedBytes.attributeType = .integer64AttributeType
        downloadDownloadedBytes.isOptional = false
        downloadDownloadedBytes.defaultValue = Int64(0)

        let downloadStartDate = NSAttributeDescription()
        downloadStartDate.name = "startDate"
        downloadStartDate.attributeType = .dateAttributeType
        downloadStartDate.isOptional = false

        let downloadCompletionDate = NSAttributeDescription()
        downloadCompletionDate.name = "completionDate"
        downloadCompletionDate.attributeType = .dateAttributeType
        downloadCompletionDate.isOptional = true

        let downloadStatusRaw = NSAttributeDescription()
        downloadStatusRaw.name = "statusRaw"
        downloadStatusRaw.attributeType = .stringAttributeType
        downloadStatusRaw.isOptional = false
        downloadStatusRaw.defaultValue = "pending"

        downloadEntity.properties = [
            downloadID, downloadURL, downloadFilename, downloadFilePath,
            downloadTotalBytes, downloadDownloadedBytes, downloadStartDate,
            downloadCompletionDate, downloadStatusRaw
        ]

        model.entities = [bookmarkEntity, historyEntity, shortcutEntity, downloadEntity]
        return model
    }

    // MARK: - Save

    func save() {
        let context = viewContext
        if context.hasChanges {
            do {
                try context.save()
            } catch {
                print("Failed to save context: \(error)")
            }
        }
    }

    // MARK: - Background Context

    func newBackgroundContext() -> NSManagedObjectContext {
        container.newBackgroundContext()
    }
}
