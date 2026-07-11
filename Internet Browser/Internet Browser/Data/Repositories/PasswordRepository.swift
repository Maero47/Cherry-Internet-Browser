//
//  PasswordRepository.swift
//  Cherry Browser
//

import CoreData
import Foundation
import Observation

@Observable
final class PasswordRepository {
    static let shared = PasswordRepository()

    private let persistence = PersistenceController.shared
    private(set) var passwords: [PasswordItem] = []

    init() {
        fetchPasswords()
    }

    // MARK: - Fetch

    func fetchPasswords() {
        let context = persistence.viewContext
        let request = NSFetchRequest<PasswordEntity>(entityName: "PasswordEntity")
        request.sortDescriptors = [
            NSSortDescriptor(key: "url", ascending: true)
        ]

        do {
            let entities = try context.fetch(request)
            passwords = entities.map { PasswordItem(entity: $0) }
        } catch {
            print("Failed to fetch passwords: \(error)")
        }
    }

    // MARK: - Add

    @discardableResult
    func addCredential(url: String, username: String, password: String, faviconData: Data? = nil) -> PasswordItem {
        let context = persistence.viewContext
        let id = UUID()

        let entity = PasswordEntity(context: context)
        entity.id = id
        entity.url = url
        entity.username = username
        entity.createdAt = Date()
        entity.faviconData = faviconData

        KeychainHelper.save(password: password, for: id)
        persistence.save()
        fetchPasswords()

        return PasswordItem(
            id: id,
            url: url,
            username: username,
            password: password,
            createdAt: entity.createdAt,
            faviconData: faviconData
        )
    }

    // MARK: - Update

    func updateCredential(id: UUID, username: String? = nil, password: String? = nil, notes: String? = nil) {
        let context = persistence.viewContext
        let request = NSFetchRequest<PasswordEntity>(entityName: "PasswordEntity")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)

        do {
            if let entity = try context.fetch(request).first {
                if let username { entity.username = username }
                if let notes { entity.notes = notes }
                if let password { KeychainHelper.update(password: password, for: id) }
                persistence.save()
                fetchPasswords()
            }
        } catch {
            print("Failed to update credential: \(error)")
        }
    }

    func markUsed(id: UUID) {
        let context = persistence.viewContext
        let request = NSFetchRequest<PasswordEntity>(entityName: "PasswordEntity")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)

        do {
            if let entity = try context.fetch(request).first {
                entity.lastUsedAt = Date()
                persistence.save()
            }
        } catch {
            print("Failed to mark credential as used: \(error)")
        }
    }

    // MARK: - Delete

    func deleteCredential(id: UUID) {
        let context = persistence.viewContext
        let request = NSFetchRequest<PasswordEntity>(entityName: "PasswordEntity")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)

        do {
            if let entity = try context.fetch(request).first {
                context.delete(entity)
                KeychainHelper.delete(for: id)
                persistence.save()
                fetchPasswords()
            }
        } catch {
            print("Failed to delete credential: \(error)")
        }
    }

    // MARK: - Query

    func credentials(for url: URL) -> [PasswordItem] {
        guard let host = url.host?.lowercased() else { return [] }

        // Match the exact host or a parent/subdomain relationship on a dot
        // boundary (www.example.com <-> example.com). Never match on a naive
        // "last two labels" base domain: for hosts under multi-label public
        // suffixes (example.co.uk) that base is "co.uk", which offered — and
        // could auto-fill — one site's password on every other co.uk site.
        return passwords.filter { item in
            let itemHost = URL(string: item.url)?.host?.lowercased() ?? item.url.lowercased()
            return itemHost == host
                || itemHost.hasSuffix("." + host)
                || host.hasSuffix("." + itemHost)
        }
    }

    func fetchPassword(for id: UUID) -> String? {
        KeychainHelper.retrieve(for: id)
    }

    func searchCredentials(query: String) -> [PasswordItem] {
        guard !query.isEmpty else { return passwords }

        let lowercasedQuery = query.lowercased()
        return passwords.filter { item in
            item.url.lowercased().contains(lowercasedQuery) ||
            item.username.lowercased().contains(lowercasedQuery)
        }
    }
}
