//
//  BookmarkEntity.swift
//  Cherry Browser
//

import CoreData
import AppKit

@objc(BookmarkEntity)
public class BookmarkEntity: NSManagedObject {
    @NSManaged public var id: UUID
    @NSManaged public var url: String
    @NSManaged public var title: String
    @NSManaged public var faviconData: Data?
    @NSManaged public var folder: String?
    @NSManaged public var createdAt: Date
    @NSManaged public var visitCount: Int32
    @NSManaged public var sortOrder: Int32
    @NSManaged public var isInBookmarkBar: Bool
}

extension BookmarkEntity {
    var favicon: NSImage? {
        get {
            guard let data = faviconData else { return nil }
            return NSImage(data: data)
        }
        set {
            faviconData = newValue?.tiffRepresentation
        }
    }

    var urlValue: URL? {
        URL(string: url)
    }
}

// MARK: - Bookmark Model (for use in views)

struct Bookmark: Identifiable, Hashable {
    let id: UUID
    var url: URL
    var title: String
    var favicon: NSImage?
    var folder: String?
    var createdAt: Date
    var visitCount: Int
    var sortOrder: Int
    var isInBookmarkBar: Bool

    init(
        id: UUID = UUID(),
        url: URL,
        title: String,
        favicon: NSImage? = nil,
        folder: String? = nil,
        createdAt: Date = Date(),
        visitCount: Int = 0,
        sortOrder: Int = 0,
        isInBookmarkBar: Bool = false
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.favicon = favicon
        self.folder = folder
        self.createdAt = createdAt
        self.visitCount = visitCount
        self.sortOrder = sortOrder
        self.isInBookmarkBar = isInBookmarkBar
    }

    init(entity: BookmarkEntity) {
        self.id = entity.id
        self.url = URL(string: entity.url) ?? URL(string: "about:blank")!
        self.title = entity.title
        self.favicon = entity.favicon
        self.folder = entity.folder
        self.createdAt = entity.createdAt
        self.visitCount = Int(entity.visitCount)
        self.sortOrder = Int(entity.sortOrder)
        self.isInBookmarkBar = entity.isInBookmarkBar
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: Bookmark, rhs: Bookmark) -> Bool {
        lhs.id == rhs.id
    }
}
