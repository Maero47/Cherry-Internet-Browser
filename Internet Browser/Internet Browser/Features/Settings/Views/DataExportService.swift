//
//  DataExportService.swift
//  Cherry Browser
//

import AppKit
import UniformTypeIdentifiers

/// Save-panel export for the user's own data. The counterpart to
/// `Features/Settings/Import` — Cherry could read other browsers' data but had
/// no way to hand yours back, which is the one thing that makes a browser hard
/// to leave.
@MainActor
enum DataExportService {

    /// Netscape bookmark HTML, importable by Chrome, Firefox, Safari and Edge.
    static func exportBookmarks() {
        let html = BookmarkRepository.shared.exportToHTML()
        save(
            data: Data(html.utf8),
            suggestedName: "cherry-bookmarks.html",
            contentType: .html,
            message: "Export your bookmarks as a Netscape HTML file"
        )
    }

    /// One JSON array of `{url, title, visitDate, visitCount}`. There's no
    /// cross-browser history interchange format, so this is the archival one.
    ///
    /// Encoding runs off the main actor: a long history takes real time to
    /// serialize, and doing it inline froze the window before the save panel
    /// even appeared. Only the snapshot read and the panel stay on the main
    /// actor.
    static func exportHistory() {
        let snapshot = HistoryRepository.shared.exportSnapshot()
        Task {
            let data = await Task.detached(priority: .userInitiated) {
                HistoryRepository.encodeToJSON(snapshot)
            }.value

            guard let data else {
                presentAlert(
                    title: "Couldn't Export History",
                    message: "Your history couldn't be encoded.",
                    style: .warning
                )
                return
            }
            save(
                data: data,
                suggestedName: "cherry-history.json",
                contentType: .json,
                message: "Export your browsing history as JSON"
            )
        }
    }

    private static func save(
        data: Data,
        suggestedName: String,
        contentType: UTType,
        message: String
    ) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [contentType]
        panel.canCreateDirectories = true
        panel.message = message
        panel.prompt = "Export"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            presentAlert(
                title: "Couldn't Export",
                message: error.localizedDescription,
                style: .warning
            )
        }
    }

    private static func presentAlert(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.runModal()
    }
}
