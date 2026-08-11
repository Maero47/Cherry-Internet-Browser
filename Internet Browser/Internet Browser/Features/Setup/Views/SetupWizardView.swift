//
//  SetupWizardView.swift
//  Cherry Browser
//
//  The first-run setup wizard: a sheet over the launch window that hands the
//  user the five decisions that actually change how Cherry feels —
//  appearance, search & privacy, import, extensions, tab layout — and then
//  gets out of the way.
//
//  Every control here binds straight to `SettingsManager.shared` or calls its
//  selection methods — the SAME properties and methods the Settings pane
//  writes, applied the moment they're touched. There is no local copy and no
//  "apply" step, so the wizard can never disagree with Settings about what
//  was chosen, and Back/Skip never has anything to roll back. The extensions
//  step is the one that writes nothing to settings at all: it installs
//  through `ExtensionManager`, the same object the Settings ▸ Extensions pane
//  and File ▸ Load Extension… hand their packages to.
//
//  The surface is a sheet on purpose: it is presented after the browser
//  window is already on screen, lives in its own window AppKit manages, and
//  never touches the browser window's frame — so the `openBrowserWindow`
//  bring-up ordering (final frame → configure → show) is left completely
//  alone. Dismissing the sheet by ANY means — Finish, Skip Setup, Escape —
//  runs through `BrowserViewModel.showSetupWizard`, whose didSet writes the
//  first-run marker; quitting the app with the sheet still up writes nothing,
//  so the wizard is offered once more on the next launch.
//

import SwiftUI

struct SetupWizardView: View {
    @State private var model: SetupWizardModel

    init(onFinish: @escaping () -> Void) {
        _model = State(initialValue: SetupWizardModel(onFinish: onFinish))
    }

    private var accent: Color { SettingsManager.shared.accentColor }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                stepContent
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            footer
        }
        .frame(width: 620, height: 560)
    }

    /// Exhaustive over `SetupWizardStep` on purpose: adding a case breaks the
    /// build until it has a view here — which is how the extensions step got
    /// walked in without anyone having to remember a second list.
    @ViewBuilder
    private var stepContent: some View {
        switch model.step {
        case .welcome: SetupWelcomeStep()
        case .appearance: SetupAppearanceStep()
        case .searchPrivacy: SetupSearchPrivacyStep()
        case .importData: SetupImportStep()
        case .extensions: SetupExtensionsStep()
        case .tabLayout: SetupTabLayoutStep()
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 10) {
            // Lowers the stakes of every choice on screen — and it's true:
            // each step writes ordinary settings the Settings pane can undo.
            Text("Everything here can be changed later in Settings.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                if !model.isFirstStep {
                    Button("Back") { model.goBack() }
                        .controlSize(.large)
                }

                progressDots

                Spacer(minLength: 0)

                if !model.isLastStep {
                    Button("Skip Setup") { model.finish() }
                        .controlSize(.large)
                }

                Button(primaryButtonTitle) { model.advance() }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var primaryButtonTitle: String {
        if model.isFirstStep { return "Set Up Cherry" }
        if model.isLastStep { return "Start Browsing" }
        return "Continue"
    }

    private var progressDots: some View {
        HStack(spacing: 5) {
            ForEach(Array(SetupWizardModel.steps.enumerated()), id: \.element) { index, step in
                Circle()
                    .fill(index == model.stepIndex ? accent : Color.primary.opacity(0.15))
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                    .help(step.title)
            }
        }
        .padding(.leading, 8)
        .accessibilityElement()
        .accessibilityLabel("Step \(model.stepIndex + 1) of \(SetupWizardModel.steps.count): \(model.step.title)")
    }
}

// MARK: - Welcome

struct SetupWelcomeStep: View {
    var body: some View {
        VStack(spacing: 14) {
            pearl
                .padding(.top, 4)

            Text("Welcome to Cherry")
                .font(.system(size: 24, weight: .bold))

            Text("A minute of setup, five choices — how Cherry looks, how it searches, what it brings over, what you want added, and how your tabs sit. Skip any of it; nothing here is permanent.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
    }

    /// Pearl herself — the first thing on the first page, at
    /// `PearlMascot.heroHeight` so she is what the page is, not decoration
    /// beside a heading. She is a cut-out with her own alpha, so she stands on
    /// the sheet's material with no plate, no clip and no shadow of ours: the
    /// painting already carries its own cream outline.
    ///
    /// The stand-in that stood here while the artwork lived on another branch
    /// is GONE — no placeholder, no neutral pawprint, nothing drawn in her
    /// place. The empty branch below is not a fallback anyone should ever see:
    /// her imageset is compiled into this same bundle by this same build, so
    /// reaching it means the app shipped without its own asset catalog entry,
    /// and `SetupWizardPearlTests` fails on exactly that — it reads the image
    /// back out of this view's tree, so a wizard that renders no Pearl is a
    /// red test rather than a quietly emptier welcome.
    ///
    /// Resolved here (`heroImage`) rather than handed to `Image(_:)` as a
    /// name, so the resolution happens where the test can watch it: what this
    /// view carries is the decoded `NSImage`, not a string that SwiftUI might
    /// or might not find something for at render time.
    @ViewBuilder
    private var pearl: some View {
        if let hero = PearlMascot.heroImage {
            Image(nsImage: hero)
                .resizable()
                .scaledToFit()
                .frame(height: PearlMascot.heroHeight)
                .accessibilityLabel("Pearl, Cherry's cat")
        }
    }
}

// MARK: - Appearance & theme

private struct SetupAppearanceStep: View {
    @Bindable private var settings = SettingsManager.shared
    private var customImageStore: HomepageCustomImageStore { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SetupStepHeader(
                step: .appearance,
                title: "Make it yours",
                subtitle: "Appearance, accent colour and the homepage background."
            )

            SettingsCard(icon: "circle.lefthalf.filled", title: "Appearance") {
                SettingsLabeledRow(title: "Light, dark, or follow the Mac") {
                    Picker("", selection: $settings.appearanceMode) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                }
            }

            SettingsCard(
                icon: "paintpalette",
                title: "Accent Color",
                subtitle: "Tints controls and highlights across Cherry."
            ) {
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

            SettingsCard(
                icon: "sparkles.rectangle.stack",
                title: "Homepage Background",
                subtitle: "Auto follows your accent color. Pick a theme or your own picture instead."
            ) {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 84, maximum: 120), spacing: 10)],
                    spacing: 12
                ) {
                    if let customImage = customImageStore.image {
                        HomepageSwatch(
                            name: "Your Picture",
                            preview: .image(customImage),
                            isSelected: settings.homepageCustomImageIsActive
                        ) {
                            settings.selectCustomImageHomepageBackground()
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

                SettingsLabeledRow(
                    title: "Your Own Picture",
                    subtitle: "Cherry keeps its own copy, so the original can move or be deleted."
                ) {
                    Button(customImageStore.isAvailable ? "Change Picture…" : "Choose…") {
                        HomepagePictureChooser.chooseAndApply()
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    /// Same preview rule as the Settings pane: the accent's real wallpaper
    /// when one ships, the accent-derived gradient otherwise.
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
}

// MARK: - Search & privacy

private struct SetupSearchPrivacyStep: View {
    @Bindable private var settings = SettingsManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SetupStepHeader(
                step: .searchPrivacy,
                title: "Search and privacy",
                subtitle: "Who answers your searches, and what pages are allowed to do."
            )

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
            }

            SettingsCard(icon: "shield.lefthalf.filled", title: "Privacy") {
                SettingsToggleRow(
                    title: "Block Ads & Trackers",
                    subtitle: "You can pause blocking per site from the toolbar.",
                    isOn: $settings.adBlockEnabled
                )

                Divider()

                SettingsLabeledRow(
                    title: "Cookie Policy",
                    subtitle: "Blocking all cookies signs you out of most sites."
                ) {
                    CherryPicker(
                        selection: $settings.blockCookies,
                        options: CookieBlockingLevel.allCases.map { .init($0, $0.displayName) }
                    )
                }
            }
        }
    }
}

// MARK: - Tab layout

private struct SetupTabLayoutStep: View {
    @Bindable private var settings = SettingsManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SetupStepHeader(
                step: .tabLayout,
                title: "Arrange your tabs",
                subtitle: "Where tabs live, and whether the bookmark bar is out."
            )

            SettingsCard(icon: "macwindow", title: "Window Layout") {
                SettingsLabeledRow(
                    title: "Tab Bar",
                    subtitle: "Vertical docks tabs along the side of the window instead of the top."
                ) {
                    CherryPicker(
                        selection: $settings.useVerticalTabs,
                        options: [
                            .init(false, "Horizontal", systemImage: "rectangle.topthird.inset.filled"),
                            .init(true, "Vertical", systemImage: "rectangle.leadingthird.inset.filled"),
                        ]
                    )
                }

                Divider()

                SettingsToggleRow(title: "Show Bookmark Bar", isOn: $settings.showBookmarkBar)
            }
        }
    }
}

// MARK: - Shared header

/// Icon + title + subtitle at the top of each step, in the step's own words.
struct SetupStepHeader: View {
    let step: SetupWizardStep
    let title: String
    let subtitle: String

    private var accent: Color { SettingsManager.shared.accentColor }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: step.icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 38, height: 38)
                .background(accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 17, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 2)
    }
}
