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
        SettingsStack {
            SettingsCard(
                icon: "puzzlepiece.extension",
                title: "Installed Extensions",
                subtitle: "Load a WebExtension folder or a .xpi/.zip file."
            ) {
                HStack {
                    Text(installedSummary)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Load Extension…") {
                        loadExtensionFromOpenPanel()
                    }
                    .controlSize(.small)
                }

                HStack(spacing: 8) {
                    Button("Browse Firefox Add-ons") {
                        openInNewCherryTab(URL(string: "https://addons.mozilla.org/firefox/extensions/")!)
                    }
                    .controlSize(.small)

                    Text("Download an add-on (.xpi), then Load it above.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                if extensionManager.installedExtensions.isEmpty {
                    Text("No extensions installed yet.")
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
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.03))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.06))
                    )
                }
            }
        }
    }

    private var installedSummary: String {
        let count = extensionManager.installedExtensions.count
        switch count {
        case 0: return "No extensions installed"
        case 1: return "1 extension installed"
        default: return "\(count) extensions installed"
        }
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
        .padding(.vertical, 10)
    }
}
