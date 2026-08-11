//
//  HomepagePictureChooser.swift
//  Cherry Browser
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The one "use my own picture" path: open the panel, import the file into
/// `HomepageCustomImageStore` (Cherry keeps its own copy), and make it the
/// homepage background via `SettingsManager`. Shared by the Settings pane and
/// the setup wizard so both offer literally the same flow — same panel, same
/// store, same preference write, same failure alert.
///
/// A file that cannot be read as an image (or cannot be copied in) changes
/// nothing and says so in a plain alert, matching the failed-theme-import
/// style.
@MainActor
enum HomepagePictureChooser {
    static func chooseAndApply() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "Choose"
        panel.message = "Choose a picture for your homepage background"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try HomepageCustomImageStore.shared.importImage(from: url)
            SettingsManager.shared.selectCustomImageHomepageBackground()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't Use That Picture"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
}
