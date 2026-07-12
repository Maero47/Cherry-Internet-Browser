//
//  FirefoxThemeManager.swift
//  Internet Browser
//

import SwiftUI
import Observation

/// The persisted record of the active Firefox theme
/// (`FirefoxThemes/activeTheme.json`). Colors are stored as the manifest's
/// raw CSS strings (arrays normalized to `rgb()` at import), so relaunch
/// only needs this record — the copied package is kept for provenance, not
/// re-parsed.
struct PersistedFirefoxThemeRecord: Codable {
    let id: String
    var displayName: String
    var packageFileName: String
    var colors: [String: String]
}

enum FirefoxThemeError: LocalizedError {
    case unreadablePackage
    case missingManifest
    case notATheme

    var errorDescription: String? {
        switch self {
        case .unreadablePackage: return "The file could not be opened as a .xpi/.zip package."
        case .missingManifest: return "No manifest.json was found in the package."
        case .notATheme: return "This package is not a Firefox theme (its manifest has no \"theme\" colors). Extensions are loaded from Settings → Extensions instead."
        }
    }
}

/// Owns the single active imported Firefox theme and exposes one optional
/// override color per themed chrome surface. Every property is `nil` when no
/// theme is active or the theme doesn't define the backing key(s), so views
/// fall back to their stock materials/colors. Mirrors `ExtensionManager`'s
/// persistence pattern: the picked package is copied into an app-managed
/// Application Support directory and a record persisted beside it, then
/// reloaded on the next launch (from `init`, so the first view render already
/// sees the theme).
///
/// Firefox themes are absolute colors — deliberately NOT light/dark adaptive.
/// Private windows are never themed: every surface gates its override on the
/// window/tab not being private, keeping the purple-tinted incognito look.
@Observable
final class FirefoxThemeManager {
    static let shared = FirefoxThemeManager()

    /// A parsed, ready-to-apply theme: the manifest's `theme.colors` map
    /// plus a display name.
    struct FirefoxTheme {
        let id: String
        let name: String
        let colors: [String: String]

        /// The first of `keys` that is present AND parses as a CSS color.
        /// Firefox theme keys are frequently absent — every mapped surface
        /// names its fallback keys explicitly.
        func color(_ keys: String...) -> Color? {
            for key in keys {
                if let raw = colors[key], let color = Color(css: raw) {
                    return color
                }
            }
            return nil
        }
    }

    private(set) var activeTheme: FirefoxTheme?

    private init() {
        loadPersistedTheme()
    }

    // MARK: - Surface overrides (Firefox color key → Cherry surface)

    /// Navigation toolbar background — `toolbar`, else the window `frame`.
    var toolbarBackground: Color? { activeTheme?.color("toolbar", "frame") }

    /// Toolbar icon/text color — `toolbar_text` (alias `bookmark_text`), else `icons`.
    var toolbarText: Color? { activeTheme?.color("toolbar_text", "bookmark_text", "icons") }

    /// Tab strip (area behind the tabs) — the window `frame`, else `toolbar`.
    var tabStripBackground: Color? { activeTheme?.color("frame", "toolbar") }

    /// Text of unselected tabs — `tab_background_text`.
    var tabStripText: Color? { activeTheme?.color("tab_background_text", "toolbar_text") }

    /// Selected tab background — `tab_selected`, else `toolbar` (Firefox's own fallback).
    var selectedTabBackground: Color? { activeTheme?.color("tab_selected", "toolbar") }

    /// Selected tab text — `tab_text`, else `toolbar_text`.
    var tabText: Color? { activeTheme?.color("tab_text", "toolbar_text") }

    /// URL field background — `toolbar_field`.
    var fieldBackground: Color? { activeTheme?.color("toolbar_field") }

    /// URL field text — `toolbar_field_text`.
    var fieldText: Color? { activeTheme?.color("toolbar_field_text") }

    /// URL field background while focused — `toolbar_field_focus`, else the unfocused field color.
    var fieldFocusBackground: Color? { activeTheme?.color("toolbar_field_focus", "toolbar_field") }

    /// URL field focus ring — `toolbar_field_border_focus`.
    var fieldFocusBorder: Color? { activeTheme?.color("toolbar_field_border_focus") }

    /// Homepage (new-tab page) background — `ntp_background`. Takes precedence
    /// over the accent-derived/curated homepage via `SettingsManager.homepageGradientColors`.
    var homepageBackground: Color? { activeTheme?.color("ntp_background") }

    /// Homepage text — `ntp_text`.
    var homepageText: Color? { activeTheme?.color("ntp_text") }

    /// Bookmarks/Downloads sidebar background — `sidebar`.
    var sidebarBackground: Color? { activeTheme?.color("sidebar") }

    /// Sidebar text — `sidebar_text`.
    var sidebarText: Color? { activeTheme?.color("sidebar_text") }

    /// A few representative colors for the Settings swatch preview, in a
    /// stable order, skipping keys the theme doesn't define.
    var previewColors: [Color] {
        guard let theme = activeTheme else { return [] }
        return ["frame", "toolbar", "toolbar_field", "tab_selected", "ntp_background"]
            .compactMap { theme.colors[$0].flatMap { Color(css: $0) } }
    }

    // MARK: - Import / Remove

    /// Imports a Firefox theme from a `.xpi`/`.zip` file or an unpacked
    /// directory: parses `manifest.json`'s `theme.colors`, copies the package
    /// into the managed themes directory, persists the record, and makes the
    /// theme active (replacing any previous one). Throws `FirefoxThemeError`
    /// for non-theme packages so the Settings UI can explain the failure.
    func importTheme(from fileURL: URL) throws {
        let parsed = try Self.parseThemePackage(at: fileURL)

        let id = UUID().uuidString
        let packageURL = try Self.copyIntoManagedDirectory(from: fileURL, id: id)

        let record = PersistedFirefoxThemeRecord(
            id: id,
            displayName: parsed.name,
            packageFileName: packageURL.lastPathComponent,
            colors: parsed.colors
        )
        let previousID = activeTheme?.id
        Self.persist(record)
        activeTheme = FirefoxTheme(id: id, name: parsed.name, colors: parsed.colors)

        if let previousID {
            try? FileManager.default.removeItem(
                at: Self.themesDirectory.appendingPathComponent(previousID, isDirectory: true))
        }
    }

    /// Reverts to Cherry's default look: clears the active theme, its managed
    /// package copy, and the persisted record.
    func removeActiveTheme() {
        guard let theme = activeTheme else { return }
        activeTheme = nil
        try? FileManager.default.removeItem(at: Self.recordFileURL)
        try? FileManager.default.removeItem(
            at: Self.themesDirectory.appendingPathComponent(theme.id, isDirectory: true))
    }

    private func loadPersistedTheme() {
        guard let data = try? Data(contentsOf: Self.recordFileURL),
              let record = try? JSONDecoder().decode(PersistedFirefoxThemeRecord.self, from: data) else { return }
        activeTheme = FirefoxTheme(id: record.id, name: record.displayName, colors: record.colors)
    }

    // MARK: - Persistence locations

    /// `Application Support/<bundle id, or "Cherry">/FirefoxThemes/` —
    /// same layout as `ExtensionManager.extensionsDirectory`: one `<id>/`
    /// subfolder per imported package plus the record JSON.
    private static let themesDirectory: URL = {
        let fileManager = FileManager.default
        let base = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fileManager.temporaryDirectory
        let appDirectoryName = Bundle.main.bundleIdentifier ?? "Cherry"
        let directory = base
            .appendingPathComponent(appDirectoryName, isDirectory: true)
            .appendingPathComponent("FirefoxThemes", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    private static var recordFileURL: URL { themesDirectory.appendingPathComponent("activeTheme.json") }

    private static func persist(_ record: PersistedFirefoxThemeRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: recordFileURL, options: .atomic)
    }

    private static func copyIntoManagedDirectory(from sourceURL: URL, id: String) throws -> URL {
        let fileManager = FileManager.default
        let themeDirectory = themesDirectory.appendingPathComponent(id, isDirectory: true)
        try fileManager.createDirectory(at: themeDirectory, withIntermediateDirectories: true)
        let destination = themeDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: sourceURL, to: destination)
        return destination
    }

    // MARK: - Package parsing

    /// Reads the theme name + colors out of a theme package: a directory is
    /// read in place; a `.xpi`/`.zip` file is unpacked to a temporary
    /// directory first (a .xpi IS a zip).
    private static func parseThemePackage(at fileURL: URL) throws -> (name: String, colors: [String: String]) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
            throw FirefoxThemeError.unreadablePackage
        }

        let fallbackName = fileURL.deletingPathExtension().lastPathComponent
        if isDirectory.boolValue {
            return try parseTheme(inDirectory: fileURL, fallbackName: fallbackName)
        }

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CherryThemeImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        // ditto -x -k unpacks zip archives regardless of the .xpi extension.
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", fileURL.path, tempDirectory.path]
        unzip.standardOutput = FileHandle.nullDevice
        unzip.standardError = FileHandle.nullDevice
        do {
            try unzip.run()
        } catch {
            throw FirefoxThemeError.unreadablePackage
        }
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw FirefoxThemeError.unreadablePackage }

        return try parseTheme(inDirectory: tempDirectory, fallbackName: fallbackName)
    }

    private static func parseTheme(inDirectory directory: URL, fallbackName: String) throws -> (name: String, colors: [String: String]) {
        guard let manifestURL = findManifest(in: directory) else { throw FirefoxThemeError.missingManifest }
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw FirefoxThemeError.missingManifest
        }
        guard let theme = manifest["theme"] as? [String: Any],
              let rawColors = theme["colors"] as? [String: Any], !rawColors.isEmpty else {
            throw FirefoxThemeError.notATheme
        }

        var colors: [String: String] = [:]
        for (key, value) in rawColors {
            if let string = value as? String {
                colors[key] = string
            } else if let array = value as? [NSNumber] {
                // Manifests may also give colors as [r, g, b] / [r, g, b, a] arrays.
                if array.count == 3 {
                    colors[key] = "rgb(\(array[0]), \(array[1]), \(array[2]))"
                } else if array.count == 4 {
                    colors[key] = "rgba(\(array[0]), \(array[1]), \(array[2]), \(array[3]))"
                }
            }
        }
        guard !colors.isEmpty else { throw FirefoxThemeError.notATheme }

        let name = displayName(fromManifest: manifest, packageDirectory: manifestURL.deletingLastPathComponent())
            ?? fallbackName
        return (name, colors)
    }

    /// `manifest.json` at the package root, or one directory level down
    /// (zips are sometimes packed with a single top-level folder).
    private static func findManifest(in directory: URL) -> URL? {
        let fileManager = FileManager.default
        let direct = directory.appendingPathComponent("manifest.json")
        if fileManager.fileExists(atPath: direct.path) { return direct }

        let entries = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for entry in entries {
            let nested = entry.appendingPathComponent("manifest.json")
            if fileManager.fileExists(atPath: nested.path) { return nested }
        }
        return nil
    }

    /// The manifest `name`, resolving the WebExtension `__MSG_key__` localization
    /// indirection against `_locales/<default_locale>/messages.json` when used.
    private static func displayName(fromManifest manifest: [String: Any], packageDirectory: URL) -> String? {
        guard let name = manifest["name"] as? String, !name.isEmpty else { return nil }
        guard name.hasPrefix("__MSG_"), name.hasSuffix("__") else { return name }

        let key = String(name.dropFirst("__MSG_".count).dropLast(2))
        guard let locale = manifest["default_locale"] as? String else { return nil }
        let messagesURL = packageDirectory
            .appendingPathComponent("_locales", isDirectory: true)
            .appendingPathComponent(locale, isDirectory: true)
            .appendingPathComponent("messages.json")
        guard let data = try? Data(contentsOf: messagesURL),
              let messages = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entry = messages[key] as? [String: Any],
              let message = entry["message"] as? String, !message.isEmpty else { return nil }
        return message
    }
}
