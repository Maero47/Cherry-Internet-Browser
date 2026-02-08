//
//  ShortcutEntity.swift
//  Cherry Browser
//

import CoreData
import AppKit

@objc(ShortcutEntity)
public class ShortcutEntity: NSManagedObject {
    @NSManaged public var id: UUID
    @NSManaged public var url: String
    @NSManaged public var title: String
    @NSManaged public var faviconData: Data?
    @NSManaged public var sortOrder: Int32
}

extension ShortcutEntity {
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

// MARK: - Shortcut Model (for use in views)

struct Shortcut: Identifiable, Hashable {
    let id: UUID
    var url: URL
    var title: String
    var favicon: NSImage?
    var sortOrder: Int

    init(
        id: UUID = UUID(),
        url: URL,
        title: String,
        favicon: NSImage? = nil,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.favicon = favicon
        self.sortOrder = sortOrder
    }

    init(entity: ShortcutEntity) {
        self.id = entity.id
        self.url = URL(string: entity.url) ?? URL(string: "about:blank")!
        self.title = entity.title
        self.favicon = entity.favicon
        self.sortOrder = Int(entity.sortOrder)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: Shortcut, rhs: Shortcut) -> Bool {
        lhs.id == rhs.id
    }
}
