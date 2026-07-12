//
//  GeneralSettingsView.swift
//  Cherry Browser
//

import SwiftUI

struct GeneralSettingsView: View {
    @Bindable private var settings = SettingsManager.shared

    var body: some View {
        SettingsStack {
            SettingsCard(icon: "magnifyingglass", title: "Search") {
                SettingsLabeledRow(
                    title: "Search Engine",
                    subtitle: "Used for searches from the address bar and homepage."
                ) {
                    Picker("", selection: $settings.searchEngine) {
                        ForEach(SearchEngine.allCases) { engine in
                            Text(engine.rawValue).tag(engine)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }

            SettingsCard(
                icon: "paintpalette",
                title: "Theme",
                subtitle: "The accent color tints controls and highlights across Cherry."
            ) {
                SettingsLabeledRow(title: "Appearance") {
                    Picker("", selection: $settings.appearanceMode) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Accent Color")
                            .font(.system(size: 13))
                        Spacer()
                        Text(currentAccentName)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 11) {
                        ForEach(AccentColorOption.options) { option in
                            AccentSwatch(
                                option: option,
                                isSelected: settings.accentColorHex == option.hex
                            ) {
                                settings.accentColorHex = option.hex
                            }
                        }
                    }
                }
            }

            SettingsCard(
                icon: "sparkles.rectangle.stack",
                title: "Homepage Background",
                subtitle: "Auto follows your accent color. Pick a theme to override it."
            ) {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 84, maximum: 120), spacing: 10)],
                    spacing: 12
                ) {
                    HomepageSwatch(
                        name: "Auto",
                        colors: autoPreviewColors,
                        isSelected: settings.homepageMatchesAccent,
                        icon: "wand.and.stars"
                    ) {
                        settings.homepageMatchesAccent = true
                    }

                    ForEach(HomepageTheme.allCases) { theme in
                        HomepageSwatch(
                            name: theme.rawValue,
                            colors: previewColors(for: theme),
                            isSelected: !settings.homepageMatchesAccent && settings.homepageTheme == theme
                        ) {
                            settings.homepageTheme = theme
                            settings.homepageMatchesAccent = false
                        }
                    }
                }
            }

            SettingsCard(icon: "arrow.down.circle", title: "Downloads") {
                SettingsLabeledRow(title: "Save files to") {
                    HStack(spacing: 8) {
                        Label(downloadDirectoryName, systemImage: "folder.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Button("Change…") {
                            chooseDownloadDirectory()
                        }
                        .controlSize(.small)
                    }
                }
            }

            SettingsCard(icon: "macwindow", title: "Window Layout") {
                SettingsToggleRow(title: "Show Bookmark Bar", isOn: $settings.showBookmarkBar)
                Divider()
                SettingsToggleRow(
                    title: "Use Vertical Tab Bar",
                    subtitle: "Docks tabs along the side of the window instead of the top.",
                    isOn: $settings.useVerticalTabs
                )
            }

            SettingsCard(icon: "square.on.square", title: "Tabs") {
                SettingsToggleRow(
                    title: "Auto-sleep Inactive Tabs",
                    subtitle: "Frees up memory from tabs you haven't used in a while.",
                    isOn: $settings.tabSleepEnabled
                )

                if settings.tabSleepEnabled {
                    SettingsLabeledRow(title: "Sleep After") {
                        Picker("", selection: $settings.tabSleepTimeout) {
                            Text("15 minutes").tag(15)
                            Text("30 minutes").tag(30)
                            Text("1 hour").tag(60)
                            Text("2 hours").tag(120)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                }

                Divider()

                SettingsToggleRow(
                    title: "Restore Previous Session on Launch",
                    isOn: $settings.restorePreviousSession
                )
            }
        }
    }

    // MARK: - Helpers

    private var currentAccentName: String {
        AccentColorOption.options.first { $0.hex == settings.accentColorHex }?.name ?? "Custom"
    }

    /// Three sample stops (light → mid → deep) for a swatch preview gradient.
    private var autoPreviewColors: [Color] {
        let colors = AccentDerivedPalette.gradientColors(fromHex: settings.accentColorHex)
        return [colors[1], colors[4], colors[8]]
    }

    private func previewColors(for theme: HomepageTheme) -> [Color] {
        let colors = theme.gradientColors
        return [colors[1], colors[4], colors[8]]
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
