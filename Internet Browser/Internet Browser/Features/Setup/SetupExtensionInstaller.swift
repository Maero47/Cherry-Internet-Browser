//
//  SetupExtensionInstaller.swift
//  Cherry Browser
//
//  What the wizard's extensions step actually DOES: fetch the exact verified
//  artifact each `ExtensionShortlistEntry` names, and hand it to the app's one
//  `ExtensionManager` — the same call the File ▸ Load Extension… menu item and
//  the Settings ▸ Extensions pane make. There is no wizard-only install path,
//  no wizard-only extension list and no wizard-only record of what is
//  installed; an extension added here is indistinguishable afterwards from one
//  the user loaded by hand, because it WAS loaded by hand's code.
//
//  Both outside edges are injectable — the download and the install — for one
//  reason: the tests. A test that exercised the defaults would reach the
//  network and write into the user's real Application Support extensions
//  directory. So the defaults are the real thing, the tests substitute local
//  fixtures, and separate tests pin that the defaults ARE the real thing (see
//  `SetupExtensionStepTests`).
//

import Foundation

/// The one thing the wizard needs an extension host to do. `ExtensionManager`
/// is the only conformer that ships; tests substitute a recorder.
@MainActor
protocol SetupExtensionInstalling: AnyObject {
    /// Installs the package at `url` and returns the name to show the user.
    func installShortlistPackage(at url: URL) async throws -> String
}

extension ExtensionManager: SetupExtensionInstalling {
    /// Straight through to the interactive load path — copy into the managed
    /// directory, parse, create the context, persist the record, announce
    /// open windows — so a wizard install is a normal install.
    func installShortlistPackage(at url: URL) async throws -> String {
        try await loadExtension(from: url).displayName
    }
}

/// Downloads one shortlist package and returns a local file URL whose LAST
/// PATH COMPONENT is the package's real filename. The filename is not
/// cosmetic: `ExtensionManager` copies the file under that name and WebKit
/// decides how to read a package from its extension, so a `CFNetworkDownload`
/// temp name would arrive as an unreadable extensionless blob.
typealias SetupExtensionPackageDownloader = @Sendable (URL) async throws -> URL

/// Drives the extensions step: what is ticked, what is being fetched, and
/// what happened to each one.
///
/// Holds NO settings. The extension list is `ExtensionShortlist.entries` and
/// the record of what is installed is `ExtensionManager`'s; this object owns
/// only the transient state of one visit to one wizard step.
@MainActor
@Observable
final class SetupExtensionInstaller {

    /// What happened to one chosen entry. `caveat` is carried through from the
    /// entry rather than re-worded here — the sentence the user reads after
    /// installing is the SAME sentence the row showed before, so the shortlist
    /// stays the only place uBO Lite's warm-up is described.
    struct Outcome: Identifiable, Equatable {
        let entryID: String
        let displayName: String
        /// nil when the install succeeded.
        let failure: String?
        let caveat: String?

        var id: String { entryID }
        var succeeded: Bool { failure == nil }
    }

    enum Phase: Equatable {
        case choosing
        /// Display name of the entry currently being fetched/installed.
        case installing(String)
        case finished
    }

    let entries: [ExtensionShortlistEntry]
    private(set) var selectedIDs: Set<String> = []
    private(set) var phase: Phase = .choosing
    private(set) var outcomes: [Outcome] = []

    private let download: SetupExtensionPackageDownloader

    /// Who actually installs. Internal, not private, for one test: that a
    /// default-constructed installer points at `ExtensionManager.shared` —
    /// the app's single extension host — and not at some wizard-local
    /// substitute. A wizard wired to anything else installs nothing the rest
    /// of Cherry can see.
    let host: any SetupExtensionInstalling

    /// The default host is the app-global `ExtensionManager` and the default
    /// download is a real one — both pinned by test, because a wizard wired to
    /// a stub is a wizard that installs nothing.
    init(
        entries: [ExtensionShortlistEntry] = ExtensionShortlist.entries,
        download: @escaping SetupExtensionPackageDownloader = SetupExtensionInstaller.downloadPackage,
        host: any SetupExtensionInstalling = ExtensionManager.shared
    ) {
        self.entries = entries
        self.download = download
        self.host = host
    }

    /// Nothing is ticked to begin with. A first-run wizard that arrives with
    /// three extensions pre-selected installs three extensions for a user who
    /// only pressed Continue — these reach the network and change how every
    /// page renders, so they are opted INTO, never out of.
    var hasSelection: Bool { !selectedIDs.isEmpty }

    var isInstalling: Bool {
        if case .installing = phase { return true }
        return false
    }

    func isSelected(_ entry: ExtensionShortlistEntry) -> Bool {
        selectedIDs.contains(entry.id)
    }

    func toggle(_ entry: ExtensionShortlistEntry) {
        guard !isInstalling else { return }
        if selectedIDs.contains(entry.id) {
            selectedIDs.remove(entry.id)
        } else {
            selectedIDs.insert(entry.id)
        }
    }

    /// Installs every ticked entry, in shortlist order, one at a time.
    ///
    /// Serially rather than concurrently: each install copies a package into
    /// the managed directory and rewrites the shared `index.json`, and this
    /// is first-run code where an interleaved write is a corrupt index on a
    /// browser that has not yet been used once.
    ///
    /// A failure does not stop the rest. Three independent choices were made;
    /// one bad download is not a reason to silently drop the other two, and
    /// every outcome — good and bad — is reported by name.
    func installSelected() async {
        guard !isInstalling, hasSelection else { return }
        outcomes = []
        for entry in entries where selectedIDs.contains(entry.id) {
            phase = .installing(entry.displayName)
            outcomes.append(await install(entry))
        }
        phase = .finished
    }

    private func install(_ entry: ExtensionShortlistEntry) async -> Outcome {
        do {
            let package = try await download(entry.sourceURL)
            defer { Self.discardDownload(at: package) }
            let installedName = try await host.installShortlistPackage(at: package)
            return Outcome(
                entryID: entry.id,
                // WebKit's own name for what it just loaded, falling back to
                // the shortlist's — the user should see what is now in their
                // browser, not what we hoped to put there.
                displayName: installedName.isEmpty ? entry.displayName : installedName,
                failure: nil,
                caveat: entry.caveat
            )
        } catch {
            return Outcome(
                entryID: entry.id,
                displayName: entry.displayName,
                failure: error.localizedDescription,
                caveat: nil
            )
        }
    }

    // MARK: - The real download

    enum DownloadFailure: LocalizedError {
        case http(Int)

        var errorDescription: String? {
            switch self {
            case let .http(status):
                "The download server answered \(status). Try again from Settings ▸ Extensions."
            }
        }
    }

    /// Where `downloadPackage` puts its per-download folders, and the ONLY
    /// directory `discardDownload` will ever remove.
    private static var downloadRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("CherrySetupExtensions", isDirectory: true)
    }

    /// Cleans up after one install. `ExtensionManager` has already copied the
    /// package into its own managed directory by this point, so the fetched
    /// copy is dead weight.
    ///
    /// Removes the FILE unconditionally, and its containing folder only when
    /// that folder is one of ours (a UUID directory under `downloadRoot`).
    /// A test — or any future caller — hands in a package that lives beside
    /// other files, and deleting "the directory the package was in" would
    /// take them with it.
    private static func discardDownload(at package: URL) {
        try? FileManager.default.removeItem(at: package)
        let directory = package.deletingLastPathComponent()
        guard directory.deletingLastPathComponent().standardizedFileURL == downloadRoot.standardizedFileURL
        else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    /// Fetches `url` into its own throwaway directory under the same real
    /// filename, so `discardDownload` can take the whole directory afterwards
    /// without guessing at what was written.
    static func downloadPackage(from url: URL) async throws -> URL {
        let (temporaryURL, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw DownloadFailure.http(http.statusCode)
        }
        let directory = downloadRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }
}
