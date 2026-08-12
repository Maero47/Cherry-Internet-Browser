//
//  DownloadsSidebarView.swift
//  Cherry Browser
//

import SwiftUI
import Quartz
import UniformTypeIdentifiers

/// Scopes, headings and the per-row facts for the downloads screen. Pure, so
/// the arithmetic can be tested without a window.
///
/// The old row showed a generic page glyph, a filename and a size. Six items
/// and you could not tell what any of them were for: not the kind of file, not
/// where it came from, not when it arrived, not where on disk it went. Every
/// one of those was already on `DownloadItem`. They are all on the row now.
enum DownloadLibrary {

    static let allScopeID = "all"
    static let inProgressScopeID = "in-progress"
    static let completedScopeID = "completed"
    static let unfinishedScopeID = "unfinished"

    /// Anything this size or larger is worth spotting at a glance, so its size
    /// carries weight. Below it, sizes are still a right-aligned column of
    /// tabular digits, which is what makes 4.6 MB and 79 KB stop looking alike.
    static let largeDownloadBytes: Int64 = 10 * 1024 * 1024

    static func scopes(for downloads: [DownloadItem]) -> [LibraryScope] {
        [
            LibraryScope(id: allScopeID, title: "All Downloads", icon: "arrow.down.circle",
                         count: downloads.count),
            LibraryScope(id: inProgressScopeID, title: "In Progress", icon: "arrow.down.circle.dotted",
                         count: downloads.count { $0.isActive }),
            LibraryScope(id: completedScopeID, title: "Completed", icon: "checkmark.circle",
                         count: downloads.count { $0.status == .completed }),
            // "Unfinished" rather than "Failed or Cancelled": it covers both,
            // and the longer name was the one label in the rail wide enough to
            // truncate itself.
            LibraryScope(id: unfinishedScopeID, title: "Unfinished", icon: "exclamationmark.circle",
                         count: downloads.count { $0.status == .failed || $0.status == .cancelled }),
        ]
    }

    static func items(_ downloads: [DownloadItem], in scopeID: String) -> [DownloadItem] {
        switch scopeID {
        case inProgressScopeID: return downloads.filter(\.isActive)
        case completedScopeID: return downloads.filter { $0.status == .completed }
        case unfinishedScopeID:
            return downloads.filter { $0.status == .failed || $0.status == .cancelled }
        default: return downloads
        }
    }

    /// When a download is filed under. A finished one is filed by when it
    /// finished, an unfinished one by when it started, because that is the
    /// date the user remembers in each case.
    static func date(of item: DownloadItem) -> Date {
        item.completionDate ?? item.startDate
    }

    static func sections(
        _ downloads: [DownloadItem],
        scopeID: String,
        searchQuery: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [LibrarySection<DownloadItem>] {
        guard !downloads.isEmpty else { return [] }

        if !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            return [LibrarySection(id: "matches", title: "Matches", items: downloads)]
        }
        if scopeID == inProgressScopeID {
            return [LibrarySection(id: "active", title: "Downloading now", items: downloads)]
        }

        var order: [String] = []
        var buckets: [String: [DownloadItem]] = [:]
        for item in downloads.sorted(by: { date(of: $0) > date(of: $1) }) {
            let key = HistoryLibrary.dayHeading(for: date(of: item), now: now, calendar: calendar)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(item)
        }
        return order.map { LibrarySection(id: $0, title: $0, items: buckets[$0] ?? []) }
    }

    // MARK: - Row facts

    /// `XPI`, `PDF`, `ZIP`. The extension, upcased: short enough for a column,
    /// and it is what the user recognises. A localised type description
    /// ("Portable Document Format document") does not fit a column and does not
    /// scan.
    static func kindText(_ item: DownloadItem) -> String {
        let ext = (item.filename as NSString).pathExtension
        guard !ext.isEmpty else { return "File" }
        return ext.uppercased()
    }

    /// Where it came from, and where it went: `github.com · Downloads`.
    /// Both halves matter. The source is how you tell two files with the same
    /// name apart, and the destination is the answer to "where did it go".
    static func originText(_ item: DownloadItem) -> String {
        let source = item.url.host ?? item.url.absoluteString
        guard let path = item.filePath else { return source }
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
        return folder.isEmpty ? source : "\(source) · \(folder)"
    }

    static func sizeText(_ item: DownloadItem, downloaded: Int64?, total: Int64?) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let bytes = total ?? item.totalBytes
        if bytes > 0 { return formatter.string(fromByteCount: bytes) }
        let partial = downloaded ?? item.downloadedBytes
        return partial > 0 ? formatter.string(fromByteCount: partial) : "Unknown"
    }

    static func isLarge(_ item: DownloadItem) -> Bool {
        item.totalBytes >= largeDownloadBytes
    }

    static func whenText(_ item: DownloadItem, now: Date = Date(), calendar: Calendar = .current) -> String {
        let date = date(of: item)
        if calendar.isDate(date, inSameDayAs: now) {
            return HistoryLibrary.timeText(date, calendar: calendar)
        }
        return BookmarkLibrary.addedText(date, now: now, calendar: calendar)
    }

    /// The one line under a row that is not a column: what is happening, or
    /// what went wrong. `nil` for a completed download, which needs no caption.
    static func statusText(
        _ item: DownloadItem,
        downloaded: Int64?,
        total: Int64?,
        speed: String?,
        eta: String?
    ) -> String? {
        switch item.status {
        case .completed:
            return nil
        case .cancelled:
            return "Cancelled before it finished"
        case .failed:
            return item.errorMessage.map { "Failed: \($0)" } ?? "Failed to download"
        case .downloading, .pending:
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            let got = downloaded ?? item.downloadedBytes
            let want = total ?? item.totalBytes
            var parts: [String] = []
            if want > 0 {
                parts.append("\(formatter.string(fromByteCount: got)) of \(formatter.string(fromByteCount: want))")
            } else if got > 0 {
                parts.append("\(formatter.string(fromByteCount: got)) so far")
            } else {
                parts.append(item.status == .pending ? "Waiting to start" : "Starting")
            }
            if let speed { parts.append(speed) }
            if let eta { parts.append(eta) }
            return parts.joined(separator: " · ")
        }
    }
}

struct DownloadsSidebarView: View {
    @Bindable var repository: DownloadRepository
    let downloadManager: DownloadManager
    var presentation: LibraryPresentation = .sidebar
    var onClose: (() -> Void)? = nil
    /// Private windows are never themed by an imported Firefox theme.
    var isPrivateMode: Bool = false

    @State private var searchText: String = ""
    @State private var scopeID: String = DownloadLibrary.allScopeID
    @State private var selection: Set<UUID> = []
    @State private var showingClearAlert: Bool = false

    private var matchingDownloads: [DownloadItem] {
        let base = searchText.trimmingCharacters(in: .whitespaces).isEmpty
            ? repository.downloads
            : repository.searchDownloads(query: searchText)
        return DownloadLibrary.items(base, in: scopeID)
    }

    var body: some View {
        LibraryLayout(
            title: "Downloads",
            searchPrompt: "Search downloads",
            presentation: presentation,
            scopes: DownloadLibrary.scopes(for: repository.downloads),
            scopeID: $scopeID,
            searchText: $searchText,
            sections: DownloadLibrary.sections(
                matchingDownloads, scopeID: scopeID, searchQuery: searchText
            ),
            selection: $selection,
            emptyState: LibraryEmptyState(
                icon: "arrow.down.circle",
                headline: "Nothing downloaded yet",
                detail: "Files you download are listed here with where they came from and where Cherry put them.",
                isUntouched: true
            ),
            noResultsState: LibraryEmptyState(
                icon: "magnifyingglass",
                headline: "No downloads match that search",
                detail: "Search matches file names. Try a shorter word, or pick a different state on the left."
            ),
            destructive: LibraryDestructiveAction(
                title: "Clear Downloads",
                icon: "trash",
                isEnabled: !repository.downloads.isEmpty,
                action: { showingClearAlert = true }
            ),
            onClose: onClose,
            onOpen: open,
            onRemove: { items in items.forEach { downloadManager.removeDownload(id: $0.id) } },
            rowMenu: menu,
            row: { item, density in
                DownloadRow(
                    item: item,
                    density: density,
                    progress: downloadManager.progressMap[item.id],
                    speedText: downloadManager.formattedSpeed(for: item.id),
                    etaText: downloadManager.formattedETA(for: item.id),
                    isUnquarantined: item.status == .completed
                        && downloadManager.isUnquarantined(id: item.id),
                    onCancel: { downloadManager.cancelDownload(id: item.id) },
                    onRetry: { downloadManager.retryDownload(id: item.id) }
                )
            }
        )
        .modifier(DownloadSidebarTheming(
            isThemed: presentation == .sidebar && !isPrivateMode
        ))
        .alert("Clear Downloads", isPresented: $showingClearAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Clear List", role: .destructive) { downloadManager.clearAll() }
        } message: {
            Text("This cancels any download still running and empties this list. The files already on disk are kept.")
        }
    }

    /// Opening a download means opening the file. A download that did not
    /// finish has no file, so Return on it retries instead of failing silently.
    private func open(_ items: [DownloadItem]) {
        for item in items {
            switch item.status {
            case .completed: downloadManager.openFile(id: item.id)
            case .failed: downloadManager.retryDownload(id: item.id)
            case .cancelled, .downloading, .pending: break
            }
        }
    }

    @CherryMenuBuilder
    private func menu(for item: DownloadItem) -> [CherryMenuItem] {
        if item.status == .completed {
            CherryMenuItem.action("Open") { downloadManager.openFile(id: item.id) }
            CherryMenuItem.action("Quick Look") {
                if let path = item.filePath {
                    DownloadQuickLookHelper.shared.previewFile(at: path)
                }
            }
            CherryMenuItem.action("Reveal in Finder") { downloadManager.revealInFinder(id: item.id) }
            CherryMenuItem.separator
        }
        if item.status == .failed || item.status == .cancelled {
            CherryMenuItem.action("Download Again") { downloadManager.retryDownload(id: item.id) }
            CherryMenuItem.separator
        }
        if item.isActive {
            CherryMenuItem.action("Cancel Download") { downloadManager.cancelDownload(id: item.id) }
            CherryMenuItem.separator
        }
        CherryMenuItem.action("Copy Source Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.url.absoluteString, forType: .string)
        }
        CherryMenuItem.separator
        CherryMenuItem.action("Remove from List", destructive: true) {
            downloadManager.removeDownload(id: item.id)
        }
    }
}

/// An imported Firefox theme reaches the sidebar and stops at the page.
private struct DownloadSidebarTheming: ViewModifier {
    let isThemed: Bool

    func body(content: Content) -> some View {
        if isThemed {
            content
                .foregroundStyle(FirefoxThemeManager.shared.sidebarText ?? Color.primary)
                .background(
                    FirefoxThemeManager.shared.sidebarBackground
                        ?? Color(nsColor: .windowBackgroundColor)
                )
        } else {
            content
        }
    }
}

// MARK: - Row

/// What a download row encodes: the file's real Finder icon, its name, its
/// kind, where it came from, where it went, how big it is, when it arrived,
/// and, when it is not simply finished, what is happening to it.
struct DownloadRow: View {
    let item: DownloadItem
    let density: LibraryDensity
    /// Live bytes from the manager. Absent for a download that was in flight
    /// when the app last quit, which is why the row falls back to the bytes
    /// the item itself recorded rather than showing an empty bar.
    let progress: (downloaded: Int64, total: Int64)?
    let speedText: String?
    let etaText: String?
    let isUnquarantined: Bool
    let onCancel: () -> Void
    let onRetry: () -> Void

    private var accent: Color { SettingsManager.shared.accentColor }
    private var downloaded: Int64 { progress?.downloaded ?? item.downloadedBytes }
    private var total: Int64 { progress?.total ?? item.totalBytes }
    private var isFailed: Bool { item.status == .failed }

    private var statusText: String? {
        DownloadLibrary.statusText(
            item, downloaded: downloaded, total: total,
            speed: speedText, eta: etaText
        )
    }

    var body: some View {
        LibraryRow(
            title: item.filename,
            subtitle: DownloadLibrary.originText(item),
            density: density,
            titleTone: isFailed ? LibraryPalette.failure : nil,
            subtitleWidth: density.showsSecondaryColumns ? 196 : 152,
            iconWidth: density.isColumnar ? 20 : 18
        ) {
            DownloadFileIcon(item: item)
        } meta: {
            // The kind column goes first when the window narrows: the file
            // name ends in the extension, so it is the one column the row
            // already says out loud.
            if density.showsSecondaryColumns {
                LibraryMeta(text: DownloadLibrary.kindText(item), width: 48, alignment: .leading)
            }
            // Size survives all the way down to the 300pt sidebar. It is the
            // fact that stops a 4.6 MB download looking like a 79 KB one, and
            // a right-aligned column is what makes that legible at a glance.
            LibraryMeta(
                text: DownloadLibrary.sizeText(item, downloaded: downloaded, total: total),
                width: density.isColumnar ? 72 : 64,
                weight: DownloadLibrary.isLarge(item) ? .semibold : .regular
            )
            if density.isColumnar {
                LibraryMeta(text: DownloadLibrary.whenText(item), width: 66)
            }
            trailingControl
        } accessory: {
            if let statusText {
                HStack(spacing: 8) {
                    // Only when there is a length to be a fraction of. A
                    // server that never sent a Content-Length gets the words
                    // and no bar, rather than a bar frozen at zero that looks
                    // like a stall.
                    if item.isActive, total > 0 {
                        LibraryProgressBar(downloaded: downloaded, total: total)
                            .frame(maxWidth: density.isColumnar ? 180 : .infinity)
                    }
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(isFailed ? LibraryPalette.failure : LibraryPalette.supporting)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, density.isColumnar ? 30 : 24)
                .padding(.bottom, 2)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// One control, and only when there is something to do: stop a running
    /// download, try a failed one again, or warn that a file skipped
    /// Gatekeeper. A completed download needs no button, because the row
    /// itself opens it.
    @ViewBuilder
    private var trailingControl: some View {
        if item.isActive {
            Button(action: onCancel) {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(LibraryPalette.supporting)
                    .frame(width: 20, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Cancel this download")
            .accessibilityLabel("Cancel this download")
        } else if isFailed {
            Button(action: onRetry) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 20, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Download this file again")
            .accessibilityLabel("Download this file again")
        } else if isUnquarantined {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 11))
                .foregroundStyle(LibraryPalette.failure)
                .frame(width: 20, height: 18)
                .help("Not marked as downloaded from the internet, so this file will open without a Gatekeeper check.")
        } else {
            Color.clear.frame(width: 20, height: 18)
        }
    }

    private var accessibilityLabel: String {
        var parts = [item.filename, DownloadLibrary.kindText(item)]
        parts.append("from \(DownloadLibrary.originText(item))")
        parts.append(DownloadLibrary.sizeText(item, downloaded: downloaded, total: total))
        if let statusText { parts.append(statusText) }
        return parts.joined(separator: ", ")
    }
}

/// The file's real icon, the way Finder draws it.
///
/// The old screen mapped a handful of extensions onto grey SF Symbols and gave
/// everything else `doc`, so six extension files all looked like blank pages.
/// macOS already knows what every one of these is; asking it is both more
/// accurate and more recognisable than any hand-kept list.
struct DownloadFileIcon: View {
    let item: DownloadItem

    var body: some View {
        Image(nsImage: icon)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
    }

    private var icon: NSImage {
        // The file itself is the best source: it carries a custom icon, a
        // bundle icon, or a document icon that a bare extension cannot.
        if let path = item.filePath, FileManager.default.fileExists(atPath: path) {
            return NSWorkspace.shared.icon(forFile: path)
        }
        let ext = (item.filename as NSString).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
            return NSWorkspace.shared.icon(for: type)
        }
        return NSWorkspace.shared.icon(for: .data)
    }
}
