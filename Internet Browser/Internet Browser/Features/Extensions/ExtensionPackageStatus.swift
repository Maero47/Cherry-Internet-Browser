//
//  ExtensionPackageStatus.swift
//  Internet Browser
//

import Foundation

/// What Cherry can honestly say about one installed extension's PACKAGE —
/// separately from whether the user has the extension switched on.
///
/// The distinction this type exists for: WebKit's manifest parser drops
/// individual entries it cannot use and loads the rest of the extension
/// anyway. `WKWebExtension.errors` is where those drops are reported, and a
/// non-empty `errors` array is NOT a failed load. Vimium is the standing
/// example — its second `content_scripts` entry matches only `file:///`,
/// which the content-script parser discards, leaving that entry with no
/// matches and one error on the extension; its other entry injects, its
/// scripts run, and the extension works. Reporting that as "failed to load"
/// tells the user something untrue about software that is running.
///
/// So: dropped entries are a WARNING against a loaded extension
/// (`partiallyDropped`), and only a package WebKit refused outright is a
/// `failed` one.
enum ExtensionPackageStatus: Equatable {
    /// WebKit parsed the whole manifest — nothing to say.
    case intact

    /// WebKit loaded the extension and is running it, but skipped these
    /// parts of its manifest. Each string is WebKit's own account of WHAT it
    /// skipped, never a generic "something went wrong" — an unexplained
    /// warning is not worth showing.
    case partiallyDropped([String])

    /// WebKit could not load the package at all; the extension is not
    /// running. Carries the reason.
    case failed(String)

    /// Not resolved yet — a persisted record whose `WKWebExtension` is still
    /// loading during launch-time reload.
    case pending

    /// The status of an installed extension, from the three things Cherry
    /// knows about its package. Kept as a function of plain values (rather
    /// than reading `WKWebExtension` itself) so every branch is checkable
    /// without a real package on disk.
    ///
    /// - Parameters:
    ///   - hasPackage: whether the `WKWebExtension` resolved at all.
    ///   - droppedEntries: `WKWebExtension.errors`, already described.
    ///   - loadFailure: why the package could not be loaded, if it could not.
    static func of(hasPackage: Bool, droppedEntries: [String], loadFailure: String?) -> ExtensionPackageStatus {
        // A failure outranks anything the parser managed to say on the way
        // down: if the package never loaded, there is no running extension
        // for a warning to be "against".
        if let loadFailure { return .failed(loadFailure) }
        guard hasPackage else { return .pending }
        return droppedEntries.isEmpty ? .intact : .partiallyDropped(droppedEntries)
    }

    /// The one-line headline for this status, or `nil` when there is nothing
    /// to report. Says out loud that a partially-dropped extension IS loaded,
    /// so the detail lines below it can't be read as a load failure.
    var summary: String? {
        switch self {
        case .intact, .pending:
            return nil
        case .partiallyDropped(let entries):
            let part = entries.count == 1 ? "One part" : "\(entries.count) parts"
            return "Loaded and running. \(part) of this extension's manifest could not be used:"
        case .failed:
            return "This extension could not be loaded:"
        }
    }

    /// The specifics behind `summary` — what was dropped, or why the load
    /// failed, in WebKit's own words.
    var details: [String] {
        switch self {
        case .intact, .pending: return []
        case .partiallyDropped(let entries): return entries
        case .failed(let reason): return [reason]
        }
    }

    /// Whether this status is about a running extension. A dropped entry is
    /// a warning; only `failed` says the extension is not there.
    var isWarningAgainstALoadedExtension: Bool {
        if case .partiallyDropped = self { return true }
        return false
    }
}
