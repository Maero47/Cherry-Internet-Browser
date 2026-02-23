//
//  GeneralSettingsView.swift
//  Cherry Browser
//

import SwiftUI

struct GeneralSettingsView: View {
    @Bindable private var settings = SettingsManager.shared

    var body: some View {
        Form {
            Section("Search") {
                Picker("Search Engine", selection: $settings.searchEngine) {
                    ForEach(SearchEngine.allCases) { engine in
                        Text(engine.rawValue).tag(engine)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("Theme") {
                Picker("Appearance", selection: $settings.appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Accent Color")
                        .font(.subheadline)

                    HStack(spacing: 10) {
                        ForEach(AccentColorOption.options) { option in
                            Button {
                                settings.accentColorHex = option.hex
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(option.color)
                                        .frame(width: 28, height: 28)

                                    if settings.accentColorHex == option.hex {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(.white)
                                    }

                                    Circle()
                                        .strokeBorder(
                                            settings.accentColorHex == option.hex
                                                ? option.color
                                                : Color.clear,
                                            lineWidth: 2
                                        )
                                        .frame(width: 34, height: 34)
                                }
                            }
                            .buttonStyle(.plain)
                            .help(option.name)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Homepage Background") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        ForEach(HomepageTheme.allCases) { theme in
                            Button {
                                settings.homepageTheme = theme
                            } label: {
                                VStack(spacing: 4) {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(theme.previewColor)
                                        .frame(width: 36, height: 24)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .strokeBorder(
                                                    settings.homepageTheme == theme
                                                        ? Color.white
                                                        : Color.clear,
                                                    lineWidth: 2
                                                )
                                        )
                                        .shadow(color: settings.homepageTheme == theme
                                                ? theme.previewColor.opacity(0.5)
                                                : .clear, radius: 4)

                                    Text(theme.rawValue)
                                        .font(.system(size: 9))
                                        .foregroundStyle(settings.homepageTheme == theme ? .primary : .secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Downloads") {
                HStack {
                    Text("Save files to")
                    Spacer()
                    Text(downloadDirectoryName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button("Change...") {
                        chooseDownloadDirectory()
                    }
                }
            }

            Section("Appearance") {
                Toggle("Show Bookmark Bar", isOn: $settings.showBookmarkBar)
                Toggle("Use Vertical Tab Bar", isOn: $settings.useVerticalTabs)
            }

            Section("Tabs") {
                Toggle("Auto-sleep Inactive Tabs", isOn: $settings.tabSleepEnabled)

                if settings.tabSleepEnabled {
                    Picker("Sleep After", selection: $settings.tabSleepTimeout) {
                        Text("15 minutes").tag(15)
                        Text("30 minutes").tag(30)
                        Text("1 hour").tag(60)
                        Text("2 hours").tag(120)
                    }
                    .pickerStyle(.menu)
                }

                Toggle("Restore previous session on launch", isOn: $settings.restorePreviousSession)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var downloadDirectoryName: String {
        let url = URL(fileURLWithPath: settings.downloadDirectory)
        return url.lastPathComponent
    }

    private func chooseDownloadDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: settings.downloadDirectory)
        panel.prompt = "Select"
        panel.message = "Choose where downloaded files will be saved"

        if panel.runModal() == .OK, let url = panel.url {
            settings.downloadDirectory = url.path
        }
    }
}
