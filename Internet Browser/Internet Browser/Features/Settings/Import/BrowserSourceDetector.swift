//
//  BrowserSourceDetector.swift
//  Cherry Browser
//
//  Scans the known on-disk locations of other browsers and reports which
//  ones are actually installed, with their profiles and which data files
//  each profile has. Pure file-system inspection — nothing is opened.
//

import Foundation

struct BrowserSourceDetector: Sendable {

    /// Detects installed source browsers. Only browsers with at least one
    /// usable profile are returned (Safari is returned whenever
    /// ~/Library/Safari exists, even if TCC hides its contents — the import
    /// itself then surfaces the Full Disk Access guidance).
    func detectSources() -> [DetectedSource] {
        var sources: [DetectedSource] = []
        for browser in SourceBrowser.allCases {
            let profiles: [SourceProfile] = switch browser {
            case .chrome: chromiumProfiles(base: "Google/Chrome")
            case .brave: chromiumProfiles(base: "BraveSoftware/Brave-Browser")
            case .edge: chromiumProfiles(base: "Microsoft Edge")
            case .firefox: firefoxProfiles()
            case .safari: safariProfiles()
            }
            if !profiles.isEmpty {
                sources.append(DetectedSource(browser: browser, profiles: profiles))
            }
        }
        return sources
    }

    private var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    }

    // MARK: - Chromium (Chrome / Brave / Edge)

    private func chromiumProfiles(base: String) -> [SourceProfile] {
        let fileManager = FileManager.default
        let baseURL = applicationSupport.appendingPathComponent(base, isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(atPath: baseURL.path) else { return [] }

        let displayNames = chromiumProfileDisplayNames(baseURL: baseURL)

        var profiles: [SourceProfile] = []
        for entry in entries where entry == "Default" || entry.hasPrefix("Profile ") {
            let directory = baseURL.appendingPathComponent(entry, isDirectory: true)
            var types: Set<ImportableDataType> = []
            if fileManager.fileExists(atPath: directory.appendingPathComponent("Bookmarks").path) {
                types.insert(.bookmarks)
            }
            if fileManager.fileExists(atPath: directory.appendingPathComponent("History").path) {
                types.insert(.history)
            }
            guard !types.isEmpty else { continue }

            var name = entry
            if let personal = displayNames[entry], !personal.isEmpty {
                name = "\(personal) (\(entry))"
            }
            profiles.append(SourceProfile(id: entry, displayName: name, directory: directory, availableTypes: types))
        }
        // "Default" first, then "Profile 1", "Profile 2", … in natural order.
        return profiles.sorted { a, b in
            if a.id == "Default" { return true }
            if b.id == "Default" { return false }
            return a.id.localizedStandardCompare(b.id) == .orderedAscending
        }
    }

    /// Best-effort read of the profile display names from `Local State`
    /// (JSON: profile.info_cache.<dir>.name).
    private func chromiumProfileDisplayNames(baseURL: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: baseURL.appendingPathComponent("Local State")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let infoCache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: Any] else {
            return [:]
        }
        var names: [String: String] = [:]
        for (directory, info) in infoCache {
            if let name = (info as? [String: Any])?["name"] as? String {
                names[directory] = name
            }
        }
        return names
    }

    // MARK: - Firefox

    private func firefoxProfiles() -> [SourceProfile] {
        let fileManager = FileManager.default
        let baseURL = applicationSupport.appendingPathComponent("Firefox", isDirectory: true)

        var candidates: [(name: String, directory: URL)] = []

        // profiles.ini sections: [ProfileN] with Name=, IsRelative=, Path=.
        if let ini = try? String(contentsOf: baseURL.appendingPathComponent("profiles.ini"), encoding: .utf8) {
            var current: [String: String] = [:]
            var inProfileSection = false
            func flush() {
                guard inProfileSection, let path = current["Path"] else { return }
                let directory = current["IsRelative"] == "0"
                    ? URL(fileURLWithPath: path, isDirectory: true)
                    : baseURL.appendingPathComponent(path, isDirectory: true)
                candidates.append((current["Name"] ?? directory.lastPathComponent, directory))
            }
            for rawLine in ini.split(separator: "\n", omittingEmptySubsequences: true) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("[") {
                    flush()
                    current = [:]
                    inProfileSection = line.hasPrefix("[Profile")
                } else if let equals = line.firstIndex(of: "=") {
                    current[String(line[..<equals])] = String(line[line.index(after: equals)...])
                }
            }
            flush()
        }

        // Fallback: scan Profiles/* directly.
        if candidates.isEmpty {
            let profilesDir = baseURL.appendingPathComponent("Profiles", isDirectory: true)
            for entry in (try? fileManager.contentsOfDirectory(atPath: profilesDir.path)) ?? [] {
                candidates.append((entry, profilesDir.appendingPathComponent(entry, isDirectory: true)))
            }
        }

        var seen = Set<String>()
        var profiles: [SourceProfile] = []
        for candidate in candidates where seen.insert(candidate.directory.path).inserted {
            guard fileManager.fileExists(atPath: candidate.directory.appendingPathComponent("places.sqlite").path) else { continue }
            profiles.append(SourceProfile(
                id: candidate.directory.lastPathComponent,
                displayName: candidate.name,
                directory: candidate.directory,
                availableTypes: [.bookmarks, .history]
            ))
        }
        return profiles
    }

    // MARK: - Safari

    private func safariProfiles() -> [SourceProfile] {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let directory = home.appendingPathComponent("Library/Safari", isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else { return [] }

        // Without Full Disk Access the contents can't be enumerated, so the
        // individual files may be invisible even though they exist. In that
        // case still offer both types; the import reports the FDA guidance.
        var types: Set<ImportableDataType> = []
        if fileManager.fileExists(atPath: directory.appendingPathComponent("Bookmarks.plist").path) {
            types.insert(.bookmarks)
        }
        if fileManager.fileExists(atPath: directory.appendingPathComponent("History.db").path) {
            types.insert(.history)
        }
        if types.isEmpty {
            types = [.bookmarks, .history]
        }

        return [SourceProfile(id: "Safari", displayName: "Safari", directory: directory, availableTypes: types)]
    }
}
