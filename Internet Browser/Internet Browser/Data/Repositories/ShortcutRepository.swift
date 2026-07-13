//
//  ShortcutRepository.swift
//  Cherry Browser
//

import CoreData
import AppKit
import SwiftUI
import Observation

@Observable
final class ShortcutRepository {
    static let shared = ShortcutRepository()

    private let persistence = PersistenceController.shared
    private(set) var shortcuts: [Shortcut] = []

    init() {
        fetchShortcuts()
        addDefaultShortcutsIfNeeded()
        fetchMissingFavicons()
    }

    // MARK: - Fetch

    func fetchShortcuts() {
        let context = persistence.viewContext
        let request = NSFetchRequest<ShortcutEntity>(entityName: "ShortcutEntity")
        request.sortDescriptors = [NSSortDescriptor(key: "sortOrder", ascending: true)]

        do {
            let entities = try context.fetch(request)
            shortcuts = entities.map { Shortcut(entity: $0) }
        } catch {
            print("Failed to fetch shortcuts: \(error)")
        }
    }

    // MARK: - Add

    @discardableResult
    func addShortcut(url: URL, title: String, favicon: NSImage? = nil) -> Shortcut {
        let context = persistence.viewContext

        let entity = ShortcutEntity(context: context)
        entity.id = UUID()
        entity.url = url.absoluteString
        entity.title = title
        entity.favicon = favicon
        entity.sortOrder = Int32(shortcuts.count)

        persistence.save()
        fetchShortcuts()

        let shortcut = Shortcut(entity: entity)

        // Auto-fetch favicon if none provided
        if favicon == nil {
            fetchFavicon(for: shortcut)
        }

        return shortcut
    }

    /// Batch add for browser import (home-screen favorites from a source
    /// browser's bookmarks bar): skips URLs already present as shortcuts (or
    /// earlier in `entries`), saves and refetches once. `favicon` is the
    /// already-encoded icon bytes (PNG) from the source browser; entries
    /// without one fall back to the usual lazy favicon fetch. An already-
    /// present shortcut still gets its icon backfilled when it has none and
    /// the entry carries one. Returns how many were added vs skipped as
    /// duplicates.
    @discardableResult
    func importShortcuts(_ entries: [(url: URL, title: String, favicon: Data?)]) -> (added: Int, skipped: Int) {
        let context = persistence.viewContext

        var existingByURL: [String: ShortcutEntity] = [:]
        let request = NSFetchRequest<ShortcutEntity>(entityName: "ShortcutEntity")
        if let existing = try? context.fetch(request) {
            for entity in existing {
                existingByURL[entity.url] = entity
            }
        }

        var added = 0
        var backfilled = 0
        var sortOrder = Int32(shortcuts.count)

        for entry in entries {
            let urlString = entry.url.absoluteString
            if let existing = existingByURL[urlString] {
                if existing.faviconData == nil, let favicon = entry.favicon {
                    existing.faviconData = favicon
                    backfilled += 1
                }
                continue
            }

            let entity = ShortcutEntity(context: context)
            entity.id = UUID()
            entity.url = urlString
            entity.title = entry.title
            entity.faviconData = entry.favicon
            entity.sortOrder = sortOrder
            existingByURL[urlString] = entity
            sortOrder += 1
            added += 1
        }

        if added > 0 || backfilled > 0 {
            persistence.save()
            fetchShortcuts()
            fetchMissingFavicons()
        }
        return (added, entries.count - added)
    }

    // MARK: - Favicon Fetching

    func fetchFavicon(for shortcut: Shortcut) {
        guard let host = shortcut.url.host else { return }

        // Use Google's favicon service for reliable favicons
        let faviconURLString = "https://www.google.com/s2/favicons?domain=\(host)&sz=128"
        guard let faviconURL = URL(string: faviconURLString) else { return }

        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: faviconURL)
                if let image = NSImage(data: data), image.size.width > 1 {
                    await MainActor.run {
                        self.updateFavicon(for: shortcut, favicon: image)
                    }
                }
            } catch {
                // Try fallback to /favicon.ico
                if let fallbackURL = shortcut.url.faviconURL {
                    do {
                        let (data, _) = try await URLSession.shared.data(from: fallbackURL)
                        if let image = NSImage(data: data) {
                            await MainActor.run {
                                self.updateFavicon(for: shortcut, favicon: image)
                            }
                        }
                    } catch {}
                }
            }
        }
    }

    func fetchMissingFavicons() {
        for shortcut in shortcuts where shortcut.favicon == nil {
            fetchFavicon(for: shortcut)
        }
    }

    // MARK: - Update

    func updateShortcut(_ shortcut: Shortcut) {
        let context = persistence.viewContext
        let request = NSFetchRequest<ShortcutEntity>(entityName: "ShortcutEntity")
        request.predicate = NSPredicate(format: "id == %@", shortcut.id as CVarArg)

        do {
            if let entity = try context.fetch(request).first {
                entity.url = shortcut.url.absoluteString
                entity.title = shortcut.title
                entity.favicon = shortcut.favicon
                entity.sortOrder = Int32(shortcut.sortOrder)

                persistence.save()
                fetchShortcuts()
            }
        } catch {
            print("Failed to update shortcut: \(error)")
        }
    }

    func updateFavicon(for shortcut: Shortcut, favicon: NSImage) {
        var updated = shortcut
        updated.favicon = favicon
        updateShortcut(updated)
    }

    /// URL-keyed variant used when a page's real favicon arrives from
    /// navigation: updates every shortcut matching the page exactly or by
    /// normalized host (lowercased, leading "www." stripped). Shortcuts whose
    /// stored icon already equals the new bytes are left untouched.
    func updateFavicon(forURL pageURL: URL, image: NSImage) {
        guard let data = image.pngData else { return }
        let pageURLString = pageURL.absoluteString
        let hostKey = pageURL.faviconHostKey

        let matchIDs = shortcuts.filter { shortcut in
            shortcut.url.absoluteString == pageURLString ||
            (hostKey != nil && shortcut.url.faviconHostKey == hostKey)
        }.map { $0.id }
        guard !matchIDs.isEmpty else { return }

        let context = persistence.viewContext
        let request = NSFetchRequest<ShortcutEntity>(entityName: "ShortcutEntity")
        request.predicate = NSPredicate(format: "id IN %@", matchIDs)

        do {
            var changed = false
            for entity in try context.fetch(request) where entity.faviconData != data {
                entity.faviconData = data
                changed = true
            }
            if changed {
                persistence.save()
                fetchShortcuts()
            }
        } catch {
            print("Failed to update shortcut favicons: \(error)")
        }
    }

    // MARK: - Delete

    func deleteShortcut(_ shortcut: Shortcut) {
        let context = persistence.viewContext
        let request = NSFetchRequest<ShortcutEntity>(entityName: "ShortcutEntity")
        request.predicate = NSPredicate(format: "id == %@", shortcut.id as CVarArg)

        do {
            if let entity = try context.fetch(request).first {
                context.delete(entity)
                persistence.save()
                fetchShortcuts()
            }
        } catch {
            print("Failed to delete shortcut: \(error)")
        }
    }

    // MARK: - Reorder

    func moveShortcut(from source: IndexSet, to destination: Int) {
        var reorderedShortcuts = shortcuts
        reorderedShortcuts.move(fromOffsets: source, toOffset: destination)

        let context = persistence.viewContext
        for (index, shortcut) in reorderedShortcuts.enumerated() {
            let request = NSFetchRequest<ShortcutEntity>(entityName: "ShortcutEntity")
            request.predicate = NSPredicate(format: "id == %@", shortcut.id as CVarArg)

            do {
                if let entity = try context.fetch(request).first {
                    entity.sortOrder = Int32(index)
                }
            } catch {
                print("Failed to reorder shortcut: \(error)")
            }
        }

        persistence.save()
        fetchShortcuts()
    }

    // MARK: - Default Shortcuts

    private func addDefaultShortcutsIfNeeded() {
        guard shortcuts.isEmpty else { return }

        let defaults: [(String, String)] = [
            ("Google", "https://www.google.com"),
            ("YouTube", "https://www.youtube.com"),
            ("GitHub", "https://www.github.com"),
            ("Twitter", "https://www.twitter.com"),
            ("Reddit", "https://www.reddit.com"),
            ("Wikipedia", "https://www.wikipedia.org")
        ]

        for (title, urlString) in defaults {
            if let url = URL(string: urlString) {
                addShortcut(url: url, title: title)
            }
        }
    }
}
