//
//  PasswordItem.swift
//  Cherry Browser
//

import CoreData
import Foundation

@objc(PasswordEntity)
public class PasswordEntity: NSManagedObject {
    @NSManaged public var id: UUID
    @NSManaged public var url: String
    @NSManaged public var username: String
    @NSManaged public var createdAt: Date
    @NSManaged public var lastUsedAt: Date?
    @NSManaged public var notes: String?
    @NSManaged public var faviconData: Data?
}

// MARK: - PasswordItem Model (for use in views)

struct PasswordItem: Identifiable, Hashable {
    let id: UUID
    var url: String
    var username: String
    var password: String
    var createdAt: Date
    var lastUsedAt: Date?
    var notes: String?
    var faviconData: Data?

    var domain: String {
        if let urlObj = URL(string: url), let host = urlObj.host {
            return host
        }
        return url
    }

    init(
        id: UUID = UUID(),
        url: String,
        username: String,
        password: String = "",
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil,
        notes: String? = nil,
        faviconData: Data? = nil
    ) {
        self.id = id
        self.url = url
        self.username = username
        self.password = password
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.notes = notes
        self.faviconData = faviconData
    }

    init(entity: PasswordEntity, includePassword: Bool = false) {
        self.id = entity.id
        self.url = entity.url
        self.username = entity.username
        self.password = includePassword ? (KeychainHelper.retrieve(for: entity.id) ?? "") : ""
        self.createdAt = entity.createdAt
        self.lastUsedAt = entity.lastUsedAt
        self.notes = entity.notes
        self.faviconData = entity.faviconData
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: PasswordItem, rhs: PasswordItem) -> Bool {
        lhs.id == rhs.id
    }
}
