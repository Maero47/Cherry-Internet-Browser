//
//  GeneralSettingsView.swift
//  Cherry Browser
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct GeneralSettingsView: View {
    @Bindable private var settings = SettingsManager.shared
    private var themeManager: FirefoxThemeManager { .shared }
    private var modelManager: LLMModelManager { .shared }

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
                icon: "brain",
                title: "AI",
                subtitle: "Powers \"Ask This Page\" and \"All Tabs\" research."
            ) {
                SettingsLabeledRow(
                    title: "AI Engine",
                    subtitle: "Qwen runs entirely on this Mac and is much stronger than Apple's built-in model."
                ) {
                    Picker("", selection: $settings.aiEngine) {
                        ForEach(AIEngine.allCases) { engine in
                            Text(engine.rawValue).tag(engine)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }

                if settings.aiEngine == .qwen {
                    Divider()
                    qwenModelRow
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
                icon: "flame",
                title: "Firefox Theme",
                subtitle: "Imported themes override Cherry's colors everywhere while active."
            ) {
                if let theme = themeManager.activeTheme {
                    HStack(spacing: 12) {
                        HStack(spacing: 4) {
                            ForEach(Array(themeManager.previewColors.enumerated()), id: \.offset) { _, color in
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(color)
                                    .frame(width: 18, height: 18)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .strokeBorder(Color.primary.opacity(0.15))
                                    }
                            }
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(theme.name)
                                .font(.system(size: 13, weight: .medium))
                            Text("Active — theming toolbar, tabs, homepage, and sidebars.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("Use Cherry Default") {
                            themeManager.removeActiveTheme()
                        }
                        .controlSize(.small)
                    }

                    Divider()
                }

                HStack(spacing: 8) {
                    Button("Import Firefox Theme…") {
                        importFirefoxThemeFromOpenPanel()
                    }
                    .controlSize(.small)

                    Button("Browse Firefox Themes") {
                        openInNewCherryTab(URL(string: "https://addons.mozilla.org/firefox/themes/")!)
                    }
                    .controlSize(.small)

                    Spacer()
                }

                Text("Download a theme (.xpi) from Mozilla, then Import it here.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
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

    // MARK: - AI (Qwen model download)

    /// Shown only while `AIEngine.qwen` is selected: download/progress/cancel
    /// control for the local Qwen model, mirroring the conditional-row
    /// pattern used by the Tabs card above and the Downloads card's button.
    @ViewBuilder
    private var qwenModelRow: some View {
        if !LLMModelManager.isMLXImportable {
            SettingsLabeledRow(title: "Qwen Model") {
                Text("Not available in this build")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        } else if modelManager.isDownloaded {
            SettingsLabeledRow(title: "Qwen Model") {
                Label("Downloaded", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
            }
        } else if modelManager.isDownloading {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Downloading Qwen3-8B…")
                        .font(.system(size: 12))
                    Spacer()
                    Button("Cancel") {
                        modelManager.cancelDownload()
                    }
                    .controlSize(.small)
                }

                ProgressView(value: modelManager.downloadFraction)
                    .progressViewStyle(.linear)

                HStack(spacing: 6) {
                    Text(modelManager.formattedProgressPercent)
                    if let total = modelManager.formattedDownloadedTotal {
                        Text("· \(total)")
                    }
                    if let speed = modelManager.formattedSpeed {
                        Text("· \(speed)")
                    }
                    if let eta = modelManager.formattedETA {
                        Text("· \(eta)")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                SettingsLabeledRow(
                    title: "Qwen Model",
                    subtitle: "About 5GB, downloaded once — then Qwen runs fully offline."
                ) {
                    Button("Download Model") {
                        modelManager.download()
                    }
                    .controlSize(.small)
                }

                if let error = modelManager.errorMessage {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
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

    /// Mirrors `loadExtensionFromOpenPanel()`: pick a `.xpi`/`.zip` file or an
    /// unpacked theme directory, import it as the active Firefox theme, and
    /// report failures (wrong file, not a theme, …) in a plain alert.
    private func importFirefoxThemeFromOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose a Firefox theme .xpi/.zip file, or an unpacked theme folder"
        if let xpiType = UTType(filenameExtension: "xpi") {
            panel.allowedContentTypes = [xpiType, .zip]
        } else {
            panel.allowedContentTypes = [.zip]
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try themeManager.importTheme(from: url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't Import Theme"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
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
