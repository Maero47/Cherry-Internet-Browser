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

    /// Batch add for browser import: skips a credential whose (url, username)
    /// already exists (in the store or earlier in `entries`), writes each
    /// secret to the Keychain, and saves + refetches once. Returns how many
    /// were added vs skipped as duplicates. Case-insensitive on the dedup key.
    @discardableResult
    func importCredentials(_ entries: [(url: String, username: String, password: String)]) -> (added: Int, skipped: Int) {
        let context = persistence.viewContext

        func key(_ url: String, _ username: String) -> String {
            "\(url.lowercased())\u{0}\(username.lowercased())"
        }
        var existing = Set(passwords.map { key($0.url, $0.username) })

        var pendingSecrets: [(id: UUID, password: String)] = []
        for entry in entries {
            guard existing.insert(key(entry.url, entry.username)).inserted else { continue }

            let id = UUID()
            let entity = PasswordEntity(context: context)
            entity.id = id
            entity.url = entry.url
            entity.username = entry.username
            entity.createdAt = Date()
            pendingSecrets.append((id, entry.password))
        }

        let added = pendingSecrets.count
        if added > 0 {
            for secret in pendingSecrets {
                KeychainHelper.save(password: secret.password, for: secret.id)
            }
            persistence.save()
            fetchPasswords()
        }
        return (added, entries.count - added)
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
        guard let rawHost = url.host else { return [] }
        let host = HostNormalizer.foldedASCII(rawHost)

        // Match the exact host or a parent/subdomain relationship on a dot
        // boundary (www.example.com <-> example.com). Never match on a naive
        // "last two labels" base domain: for hosts under multi-label public
        // suffixes (example.co.uk) that base is "co.uk", which offered — and
        // could auto-fill — one site's password on every other co.uk site.
        // The rule itself is unchanged; it now lives in `HostNormalizer` so
        // the ad-block whitelist and Focus Mode share it, and case folding is
        // locale-independent (`.lowercased()` maps I to a dotless ı in tr-TR).
        return passwords.filter { item in
            let itemHost = HostNormalizer.foldedASCII(URL(string: item.url)?.host ?? item.url)
            return HostNormalizer.hostsAreRelated(itemHost, host)
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
