//
//  GeneralSettingsView.swift
//  Cherry Browser
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct GeneralSettingsView: View {
    @Bindable private var settings = SettingsManager.shared
    @Bindable private var suggestions = SearchSuggestionsPreference.shared
    @Bindable private var homepagePreference = HomepagePreference.shared
    private var themeManager: FirefoxThemeManager { .shared }
    private var modelManager: LLMModelManager { .shared }
    private var customImageStore: HomepageCustomImageStore { .shared }

    var body: some View {
        SettingsStack {
            SettingsCard(icon: "magnifyingglass", title: "Search") {
                SettingsLabeledRow(
                    title: "Search Engine",
                    subtitle: "Used for searches from the address bar and homepage."
                ) {
                    CherryPicker(
                        selection: $settings.searchEngine,
                        options: SearchEngine.allCases.map { .init($0, $0.rawValue) }
                    )
                }

                Divider()

                SettingsToggleRow(
                    title: "Send Search Suggestions",
                    subtitle: suggestionsSubtitle,
                    isOn: $suggestions.isEnabled
                )
            }

            homepageCard

            exportCard

            SettingsCard(
                icon: "brain",
                title: "AI",
                subtitle: "The model behind \(PearlVoice.name), in the panel and in \"All Tabs\" research."
            ) {
                SettingsLabeledRow(
                    title: "AI Engine",
                    subtitle: "Qwen runs entirely on this Mac and is much stronger than Apple's built-in model."
                ) {
                    CherryPicker(
                        selection: $settings.aiEngine,
                        options: AIEngine.allCases.map { .init($0, $0.rawValue) }
                    )
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

                    // Said plainly rather than left as a mystery — and every
                    // surface, because a caption that names four of five is
                    // worse than none: the user can't tell whether the one it
                    // omits is meant to follow the accent. See
                    // `SystemAccentSurfaces` for why none of them can.
                    Text(SystemAccentSurfaces.caption)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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

            homepageBackgroundCard

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

            toolbarCard

            SettingsCard(
                icon: "pawprint",
                title: PearlVoice.name,
                subtitle: "Cherry's cat. She has a game on the offline page and, if you like, "
                    + "a spot on the pages you browse."
            ) {
                SettingsToggleRow(
                    title: "Keep \(PearlVoice.name) on Web Pages",
                    subtitle: "She sits in the corner of the page — drag her anywhere on it, "
                        + "click her for hearts, right-click her to change her size, send her "
                        + "back to her corner, or ask her for a screenshot, a web search or a "
                        + "fish. Never in incognito windows.",
                    isOn: $settings.showPearlPet
                )
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
                        CherryPicker(
                            selection: $settings.tabSleepTimeout,
                            options: [
                                .init(15, "15 minutes"), .init(30, "30 minutes"),
                                .init(60, "1 hour"), .init(120, "2 hours"),
                            ]
                        )
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

    // MARK: - Search suggestions

    /// Names the engine that will receive keystrokes, so "on" is never vague
    /// about where the typing goes — and says plainly when the chosen engine
    /// offers no suggestions API rather than silently asking a different one.
    private var suggestionsSubtitle: String {
        guard suggestions.isEnabled else {
            return "Off — nothing you type is sent anywhere. Suggestions come from your history only."
        }
        if settings.searchEngine.suggestionsURL == nil {
            return "\(settings.searchEngine.rawValue) doesn't offer suggestions, so Cherry uses your history only."
        }
        return "Sends what you type to \(settings.searchEngine.rawValue) as you type it."
    }

    // MARK: - Homepage

    /// The Home button's destination. Off by default, because Cherry's own new
    /// tab page is Home — this is the opt-in for people who want a site there.
    @ViewBuilder
    private var homepageCard: some View {
        SettingsCard(
            icon: "house",
            title: "Homepage",
            subtitle: "Where the Home button goes."
        ) {
            SettingsToggleRow(
                title: "Use a Custom Homepage",
                subtitle: "Off: Home opens Cherry's new tab page.",
                isOn: $homepagePreference.useCustomHomepage
            )

            if homepagePreference.useCustomHomepage {
                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    TextField("https://example.com", text: $homepagePreference.homepage)
                        .textFieldStyle(.roundedBorder)

                    if HomepagePreference.resolve(homepagePreference.homepage) == nil {
                        Text("Enter a web address — Home falls back to the new tab page until you do.")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    // MARK: - Toolbar

    /// Which action buttons the navigation bar shows, and in what order.
    ///
    /// Reorder is ↑/↓ per row rather than drag-and-drop on purpose: this card
    /// sits inside `SettingsPageView`'s `ScrollView`, and SwiftUI's `onMove`
    /// needs a `List` — nesting one here fights the scroll view and the card's
    /// self-sizing height. Buttons reorder reliably with the keyboard and
    /// VoiceOver too, which drag never does.
    @ViewBuilder
    private var toolbarCard: some View {
        let layout = settings.toolbarLayout

        SettingsCard(
            icon: "slider.horizontal.3",
            title: "Toolbar",
            subtitle: "Choose which buttons appear in the navigation bar, and their order. Hidden buttons stay available in the ⋯ menu."
        ) {
            ForEach(Array(layout.order.enumerated()), id: \.element) { index, item in
                if index > 0 { Divider() }

                ToolbarButtonRow(
                    item: item,
                    isHidden: layout.hidden.contains(item),
                    canMoveUp: index > 0,
                    canMoveDown: index < layout.order.count - 1,
                    onToggleHidden: {
                        settings.setToolbarItem(item, hidden: !layout.hidden.contains(item))
                    },
                    onMoveUp: { settings.moveToolbarItem(item, by: -1) },
                    onMoveDown: { settings.moveToolbarItem(item, by: 1) }
                )
            }

            Divider()

            HStack {
                Text(layout.hidden.isEmpty
                     ? "All buttons are shown."
                     : "\(layout.hidden.count) hidden — still in the ⋯ menu.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Reset to Defaults") {
                    settings.resetToolbarLayout()
                }
                .controlSize(.small)
                .disabled(settings.toolbarIsDefault)
            }
        }
    }

    // MARK: - Homepage background

    /// The background picker. Every swatch previews the background it actually
    /// produces, and every swatch is reachable: picking one takes the homepage
    /// back from an imported theme's `ntp_background`, which used to outrank
    /// this choice permanently.
    @ViewBuilder
    private var homepageBackgroundCard: some View {
        SettingsCard(
            icon: "sparkles.rectangle.stack",
            title: "Homepage Background",
            subtitle: "Auto follows your accent color. Pick a theme or your own picture to override it."
        ) {
            if themeBackgroundIsAvailable {
                Text(
                    settings.homepageThemeBackgroundIsActive
                        ? "\(activeThemeName) is providing the homepage background. Pick Auto or a theme below to use Cherry's instead — the rest of the Firefox theme stays active."
                        : "\(activeThemeName) also has a homepage background. Pick \"Theme\" to use it."
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 84, maximum: 120), spacing: 10)],
                spacing: 12
            ) {
                // First, because it is what outranks everything else while
                // it is preferred (`HomepageBackgroundResolver`).
                if let customImage = customImageStore.image {
                    HomepageSwatch(
                        name: "Your Picture",
                        preview: .image(customImage),
                        isSelected: settings.homepageCustomImageIsActive
                    ) {
                        settings.selectCustomImageHomepageBackground()
                    }
                }

                if let themeBackground = themeManager.homepageBackground {
                    HomepageSwatch(
                        name: "Theme",
                        preview: .flat(themeBackground),
                        isSelected: settings.homepageThemeBackgroundIsActive,
                        icon: "flame.fill"
                    ) {
                        settings.selectThemeHomepageBackground()
                    }
                }

                HomepageSwatch(
                    name: "Auto",
                    preview: autoPreview,
                    isSelected: settings.homepageMatchesAccent
                        && !settings.homepageThemeBackgroundIsActive
                        && !settings.homepageCustomImageIsActive,
                    icon: "wand.and.stars"
                ) {
                    settings.selectAutoHomepageBackground()
                }

                ForEach(HomepageTheme.allCases) { theme in
                    HomepageSwatch(
                        name: theme.rawValue,
                        preview: .gradient(previewColors(for: theme)),
                        isSelected: !settings.homepageMatchesAccent
                            && !settings.homepageThemeBackgroundIsActive
                            && !settings.homepageCustomImageIsActive
                            && settings.homepageTheme == theme
                    ) {
                        settings.selectCuratedHomepageTheme(theme)
                    }
                }
            }

            if customImageStore.isAvailable {
                HStack(spacing: 8) {
                    Button("Change Picture…") { chooseHomepagePicture() }
                    Button("Remove Picture") {
                        // Going back deletes Cherry's copy, not just the
                        // preference — the file was copied in, so removal
                        // must not leave it behind.
                        customImageStore.removeImage()
                        settings.homepageUsesCustomImage = false
                    }
                }
                .controlSize(.small)
            } else {
                SettingsLabeledRow(
                    title: "Your Own Picture",
                    subtitle: "Cherry keeps its own copy, so the original can move or be deleted."
                ) {
                    Button("Choose…") { chooseHomepagePicture() }
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Export

    @ViewBuilder
    private var exportCard: some View {
        SettingsCard(
            icon: "square.and.arrow.up",
            title: "Export Your Data",
            subtitle: "Your data is yours. Take it to any other browser, any time."
        ) {
            SettingsLabeledRow(
                title: "Bookmarks",
                subtitle: "Netscape HTML — importable by Chrome, Firefox, Safari and Edge."
            ) {
                Button("Export…") {
                    DataExportService.exportBookmarks()
                }
                .controlSize(.small)
            }

            Divider()

            SettingsLabeledRow(
                title: "History",
                subtitle: "JSON: address, title, time and visit count for every entry."
            ) {
                Button("Export…") {
                    DataExportService.exportHistory()
                }
                .controlSize(.small)
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

    private var themeBackgroundIsAvailable: Bool { themeManager.homepageBackground != nil }

    private var activeThemeName: String { themeManager.activeTheme?.name ?? "This Firefox theme" }

    /// What "Auto" actually paints: the accent's wallpaper image, or — for an
    /// accent outside the palette, which ships no wallpaper — the accent-derived
    /// mesh gradient. It used to always preview the mesh gradient, showing
    /// something the user would never see for any of the eight palette accents.
    private var autoPreview: HomepageSwatchPreview {
        if let assetName = HomepageBackgroundResolver.wallpaperAssetName(forAccentHex: settings.accentColorHex) {
            return .wallpaper(assetName: assetName)
        }
        let colors = AccentDerivedPalette.gradientColors(fromHex: settings.accentColorHex)
        return .gradient([colors[1], colors[4], colors[8]])
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

    /// Pick a picture for the homepage background — the shared flow the setup
    /// wizard also uses (see `HomepagePictureChooser`).
    private func chooseHomepagePicture() {
        HomepagePictureChooser.chooseAndApply()
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
