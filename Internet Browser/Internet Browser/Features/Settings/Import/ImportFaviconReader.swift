//
//  ImportFaviconReader.swift
//  Cherry Browser
//
//  Reads the favicon store of a source browser into an in-memory lookup so
//  imported bookmarks/history/favorites can carry their site icons. Formats:
//   - Chromium: <profile>/Favicons — SQLite, icon_mapping(page_url, icon_id) +
//     favicon_bitmaps(icon_id, image_data, width); image_data is PNG.
//   - Firefox:  <profile>/favicons.sqlite — SQLite, moz_pages_w_icons(id,
//     page_url) + moz_icons_to_pages(page_id, icon_id) + moz_icons(id, data,
//     width); data is PNG (occasionally SVG, skipped when it doesn't decode).
//   - Safari's favicon cache is undocumented and version-dependent, so it is
//     deliberately not read — Safari imports fall back to Cherry's own
//     favicon fetching (home-screen shortcuts lazy-fetch; pages get an icon
//     on first visit).
//
//  Everything is best-effort: any failure yields an empty store, and icons
//  whose blobs don't decode as images are skipped, never fatal. Source files
//  are only ever opened via `ImportSQLiteDatabase`'s read-only temp copy.
//

import AppKit
import Foundation

/// An in-memory favicon lookup built from a source browser's favicon store.
/// Icons are kept as their original encoded bytes (PNG), not decoded images,
/// so holding thousands of them stays cheap; each blob was decode-validated
/// once while building the store.
struct ImportedFaviconStore: Sendable {
    static let empty = ImportedFaviconStore(byPageURL: [:], byHost: [:])

    /// Best (largest) icon per exact page URL, as stored by the browser.
    let byPageURL: [String: Data]
    /// Largest icon per normalized host, for the common case where the
    /// imported URL doesn't exactly match a stored page URL.
    let byHost: [String: Data]

    var isEmpty: Bool { byPageURL.isEmpty && byHost.isEmpty }

    /// Exact page-URL match first, then the host-level fallback.
    func icon(for url: URL) -> Data? {
        if let exact = byPageURL[url.absoluteString] { return exact }
        guard let host = Self.normalizedHost(url) else { return nil }
        return byHost[host]
    }

    /// Lowercased host without a leading "www." — "www.github.com" and
    /// "github.com" should share one icon.
    static func normalizedHost(_ url: URL) -> String? {
        guard var host = url.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host.isEmpty ? nil : host
    }
}

enum ImportFaviconReader {

    // MARK: - Per-browser stores

    /// Reads <profile>/Favicons (Chrome / Brave / Edge). Empty on any failure.
    static func chromiumStore(profileDirectory: URL) -> ImportedFaviconStore {
        readStore(
            databaseFile: profileDirectory.appendingPathComponent("Favicons"),
            sql: """
                SELECT m.page_url, b.image_data, b.width
                FROM icon_mapping m JOIN favicon_bitmaps b ON b.icon_id = m.icon_id
                """
        )
    }

    /// Reads <profile>/favicons.sqlite (Firefox 55+). Empty on any failure.
    static func firefoxStore(profileDirectory: URL) -> ImportedFaviconStore {
        readStore(
            databaseFile: profileDirectory.appendingPathComponent("favicons.sqlite"),
            sql: """
                SELECT p.page_url, i.data, i.width
                FROM moz_pages_w_icons p
                JOIN moz_icons_to_pages ip ON ip.page_id = p.id
                JOIN moz_icons i ON i.id = ip.icon_id
                """
        )
    }

    // MARK: - Store building

    private struct Candidate {
        let data: Data
        /// Bitmap width used to pick "the largest"; width 0 means "any size"
        /// in Chromium, ranked below every real size.
        let score: Int64
    }

    /// Both schemas reduce to (page_url, image blob, width) rows; keep the
    /// widest decodable blob per page URL and per host.
    private static func readStore(databaseFile: URL, sql: String) -> ImportedFaviconStore {
        var bestByPage: [String: Candidate] = [:]
        do {
            let database = try ImportSQLiteDatabase(copying: databaseFile)
            defer { database.close() }
            try database.forEachRow(sql) { row in
                guard let pageURL = row.text(0), !pageURL.isEmpty,
                      let data = row.blob(1) else { return }
                let width = row.int64(2)
                let score = width > 0 ? width : 1
                if let current = bestByPage[pageURL], current.score >= score { return }
                bestByPage[pageURL] = Candidate(data: data, score: score)
            }
        } catch {
            return .empty
        }

        var byPageURL: [String: Data] = [:]
        var hostBest: [String: Candidate] = [:]
        // Many pages share one icon blob; remember each blob's verdict so it
        // is only decoded once.
        var decodable: [Data: Bool] = [:]

        for (pageURL, candidate) in bestByPage {
            let decodes: Bool
            if let known = decodable[candidate.data] {
                decodes = known
            } else {
                // Non-nil isn't enough: NSImage accepts malformed SVG and
                // yields an empty 0x0 image, which would show as a blank icon.
                if let image = NSImage(data: candidate.data) {
                    decodes = image.size.width >= 1 && image.size.height >= 1
                } else {
                    decodes = false
                }
                decodable[candidate.data] = decodes
            }
            guard decodes else { continue }

            byPageURL[pageURL] = candidate.data
            if let url = URL(string: pageURL), let host = ImportedFaviconStore.normalizedHost(url) {
                if let current = hostBest[host], current.score >= candidate.score { continue }
                hostBest[host] = candidate
            }
        }

        return ImportedFaviconStore(
            byPageURL: byPageURL,
            byHost: hostBest.mapValues(\.data)
        )
    }
}
