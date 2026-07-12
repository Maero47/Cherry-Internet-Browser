//
//  ExtensionsSettingsView.swift
//  Internet Browser
//

import SwiftUI
import AppKit

/// Management UI for installed WebExtensions: lists every extension
/// `ExtensionManager` knows about (enabled or disabled), with a toggle and a
/// Remove button per row, plus a "Load Extension…" button that calls the
/// same top-level `loadExtensionFromOpenPanel()` the File menu entry uses.
/// `ExtensionManager` is `@Observable`, so this view updates live as
/// extensions are loaded/toggled/removed from anywhere in the app.
struct ExtensionsSettingsView: View {
    @Bindable private var extensionManager = ExtensionManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Extensions")
                    .font(.headline)
                Spacer()
                Button("Load Extension…") {
                    loadExtensionFromOpenPanel()
                }
            }

            if extensionManager.installedExtensions.isEmpty {
                Text("No extensions installed. Load a WebExtension folder or a .xpi/.zip file to get started.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                VStack(spacing: 0) {
                    ForEach(extensionManager.installedExtensions) { installed in
                        ExtensionRow(installed: installed)
                        if installed.id != extensionManager.installedExtensions.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
            }
        }
        .padding()
    }
}

/// One row: icon, name + version, enable/disable toggle, Remove button.
private struct ExtensionRow: View {
    let installed: ExtensionManager.InstalledExtension

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let icon = installed.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: 16, weight: .medium))
                }
            }
            .frame(width: 28, height: 28)
            .opacity(installed.enabled ? 1.0 : 0.4)

            VStack(alignment: .leading, spacing: 2) {
                Text(installed.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(installed.enabled ? .primary : .secondary)
                if let version = installed.version {
                    Text("Version \(version)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { installed.enabled },
                set: { ExtensionManager.shared.setEnabled($0, forExtensionID: installed.id) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)

            Button("Remove") {
                ExtensionManager.shared.remove(extensionID: installed.id)
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
