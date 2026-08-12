//
//  SetupWizardView.swift
//  Cherry Browser
//
//  The first-run setup wizard: a sheet over the launch window that asks the
//  user five questions that actually change how Cherry feels — appearance,
//  search & privacy, import, extensions, tab layout — and then gets out of
//  the way.
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
//  ## Pearl's arc through the sheet
//
//  She is not scattered across it; she ARRIVES at each part of it, and where
//  she is tells you where you are:
//
//    welcome     she IS the page — waving, introducing herself, no cards, no
//                counter, no question.
//    questions   she comes up at the top of each one, 120pt, with a speech
//                bubble that says what that question is for — then one click
//                and she is gone for the rest of it.
//    last step   the same arrival, delighted, and her bubble is the goodbye.
//
//  `SetupPearlIntro.swift` owns all of that, including the reason she is no
//  longer a small permanent tenant of the footer.
//
//  Nothing about her delays anything. "Start Browsing" dismisses the sheet on
//  the same runloop turn it always did — the celebration is a step you are
//  standing on, not a curtain call you have to sit through.
//

import SwiftUI

struct SetupWizardView: View {
    /// Internal rather than private so `PearlReactionTests` can drive the real
    /// wizard — press its Continue, press its Back — and read what actually
    /// happened. Both are reference types created in `init`, so a test holding
    /// this struct holds the same objects the rendered view would.
    @State var model: SetupWizardModel
    @State var reactions = PearlReactions()
    /// Which steps Pearl has already had her one appearance on. Internal for
    /// the same reason `reactions` is: `PearlIntroTests` drives the real
    /// wizard's Continue and Back and reads what happened to her.
    @State var intro = PearlIntroDirector()
    /// Which way the last move went, so the incoming step can arrive from the
    /// side it came from. It lives on the VIEW and not on the model: the model
    /// is pinned by reflection to hold navigation state and nothing else, and
    /// the direction of a transition is a fact about an animation, not about
    /// where the user is in the flow.
    @State private var movingForward = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(onFinish: @escaping () -> Void) {
        _model = State(initialValue: SetupWizardModel(onFinish: onFinish))
    }

    private var accent: Color { SettingsManager.shared.accentColor }

    var body: some View {
        VStack(spacing: 0) {
            SetupProgressRule(fraction: model.progressFraction, reduceMotion: reduceMotion)

            ScrollView {
                stepContent
                    .padding(.top, SetupMetrics.contentTop)
                    .padding(.horizontal, SetupMetrics.contentSides)
                    .padding(.bottom, SetupMetrics.contentBottom)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // A step change is a moment, so it gets one: the outgoing
                    // step fades, the incoming one arrives from the side it
                    // came from — right if you pressed Continue, left if you
                    // pressed Back. Under Reduce Motion the swap is instant
                    // and there is no transition at all.
                    .id(model.stepIndex)
                    .transition(stepTransition)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.26), value: model.stepIndex)

            Divider()

            footer
        }
        .frame(width: 620, height: 560)
        .accessibilityLabel("Set up Cherry, step \(model.stepIndex + 1) of \(SetupWizardModel.steps.count): \(model.step.title)")
    }

    private var stepTransition: AnyTransition {
        guard !reduceMotion else { return .identity }
        let distance: CGFloat = movingForward ? 22 : -22
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: distance)),
            removal: .opacity
        )
    }

    /// Her arrival, then the step itself.
    ///
    /// The intro is assembled HERE and not inside each step view, so there is
    /// one place that decides she appears, one place that decides she is above
    /// the question rather than over it, and no step that can quietly forget
    /// her. It is in the layout flow — nothing is covered, nothing is blocked,
    /// and every control below is complete on the frame she lands on.
    @ViewBuilder
    private var stepContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let arrival = PearlIntroScript.arrival(on: model.step),
               intro.isPresent(on: model.step) {
                PearlIntro(
                    arrival: arrival,
                    pulse: reactions.pulse,
                    reduceMotion: reduceMotion,
                    onSkip: { skipPearl() }
                )
                .padding(.bottom, SetupMetrics.mastheadToControls)
            }

            stepBody
        }
    }

    /// Exhaustive over `SetupWizardStep` on purpose: adding a case breaks the
    /// build until it has a view here — which is how the extensions step got
    /// walked in without anyone having to remember a second list.
    @ViewBuilder
    private var stepBody: some View {
        switch model.step {
        case .welcome: SetupWelcomeStep()
        case .appearance: SetupAppearanceStep(reactions: reactions)
        case .searchPrivacy: SetupSearchPrivacyStep(reactions: reactions)
        case .importData: SetupImportStep(reactions: reactions)
        case .extensions: SetupExtensionsStep(reactions: reactions)
        case .tabLayout: SetupTabLayoutStep(reactions: reactions)
        }
    }

    // MARK: - Moving

    /// Advancing, with the reaction that goes with it, in ONE place.
    ///
    /// Internal rather than inlined into the button so the wiring is
    /// testable: `PearlReactionTests` calls this and reads the pulse, which
    /// is the difference between pinning "a reaction object exists and obeys
    /// Reduce Motion" and pinning "pressing Continue actually reaches it".
    ///
    /// Arriving at the last step is a bigger moment than finishing a middle
    /// one, so it gets its own reason. Finishing writes nothing here at all —
    /// the sheet is going away, and hearts on a view that is being torn down
    /// are hearts nobody sees.
    func advance(reduceMotion: Bool) {
        guard !model.isLastStep else {
            model.finish()
            return
        }
        movingForward = true
        intro.spend(model.step)
        model.advance()
        reactions.fire(model.isLastStep ? .arrived : .stepDone, reduceMotion: reduceMotion)
    }

    /// Back is not a celebration. Pinned by a test, because the tempting
    /// symmetry — fire on every navigation — turns the hearts into a scroll
    /// indicator.
    ///
    /// It spends Pearl's appearance on the step being left for the same
    /// reason `advance` does: she gets one arrival per step, and walking back
    /// and forth is not four arrivals.
    func goBack() {
        movingForward = false
        intro.spend(model.step)
        model.goBack()
    }

    /// "Got it". One click, and she is done on this step — for good, not until
    /// the next re-render.
    ///
    /// Internal so `PearlIntroTests` presses the real button's own action
    /// rather than poking the director: a bubble that cannot be dismissed
    /// through the control the user actually sees is not skippable.
    func skipPearl() {
        withAnimation(PearlArrival.animation(reduceMotion: reduceMotion)) {
            intro.spend(model.step)
        }
    }

    // MARK: - Footer

    /// One row, not two stacked ones. The quiet line holds the left, the
    /// buttons hold the right, and the gap between them is the only alignment
    /// the footer needs.
    ///
    /// Pearl is NOT in here any more. She sat at 34pt on the left of this row
    /// for four consecutive steps, which made her furniture — and it is also
    /// where her hearts went to die: a burst anchored above her head from
    /// inside a 60pt footer paints its whole ascent into the rectangle the
    /// scroll view owns, and the scroll view is a real AppKit subview stacked
    /// over everything this row draws. `PearlHeartBurst` has the measurements.
    private var footer: some View {
        HStack(spacing: 12) {
            if !model.isFirstStep {
                // Lowers the stakes of every choice on screen — and it's true:
                // each step writes ordinary settings the Settings pane can
                // undo. Absent on the welcome, where the paragraph already
                // says it and saying it twice is what a form does.
                Text("Everything here is in Settings too.")
                    .font(SetupType.aside)
                    .foregroundStyle(SetupPalette.supporting)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if !model.isFirstStep {
                Button("Back") { goBack() }
                    .controlSize(.large)
            }

            if !model.isLastStep {
                Button("Skip Setup") { model.finish() }
                    .controlSize(.large)
            }

            Button(primaryButtonTitle) { advance(reduceMotion: reduceMotion) }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
    }

    private var primaryButtonTitle: String {
        // "First question" rather than "Set Up Cherry": the welcome has just
        // promised five questions, and a button that says which one comes
        // next is the rare place where being specific is also being warmer.
        if model.isFirstStep { return "First question" }
        if model.isLastStep { return "Start Browsing" }
        return "Continue"
    }
}

// MARK: - Welcome

/// Pearl introduces herself. No counter, no question, no cards — this page is
/// one picture, one line she says, one paragraph, and the button.
struct SetupWelcomeStep: View {
    var body: some View {
        VStack(spacing: 0) {
            pearl

            // Her name is the biggest thing on the page and the only 30pt type
            // in the wizard. "Hi, I'm Pearl" was the brief's own example; this
            // is shorter than that and says more — she is not an assistant
            // being introduced to you, she is the cat who was already here.
            //
            // Short on purpose in a second sense as well: at 30pt semibold this
            // is about 360pt of a 556pt column, so it cannot wrap on to a
            // second line and leave one orphaned word under her.
            Text("I'm Pearl. I live here.")
                .font(SetupType.welcome)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)

            Text("Nothing here is set up yet. Five questions and Cherry starts feeling like yours — skip any you don't care about, they're all in Settings too, and I'll be around either way.")
                .font(SetupType.body)
                .foregroundStyle(SetupPalette.supporting)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 410)
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity)
    }

    /// Pearl herself — the first thing on the first page, at
    /// `PearlMascot.heroHeight` so she is what the page is, not decoration
    /// beside a heading. She is a cut-out with her own alpha, so she stands on
    /// the sheet's material with no plate, no clip and no shadow of ours: the
    /// painting already carries its own cream outline.
    ///
    /// The pose is `.waving` and not the original `.gazing` hero for one
    /// reason: the hero looks up and away, and a cat who is not looking at you
    /// cannot be the one introducing herself. Nothing else on the page moved
    /// to accommodate it — she is the same height in the same place.
    ///
    /// The stand-in that stood here while the artwork lived on another branch
    /// is GONE — no placeholder, no neutral pawprint, nothing drawn in her
    /// place. `PearlPortrait`'s empty branch is not a fallback anyone should
    /// ever see: her imageset is compiled into this same bundle by this same
    /// build, so reaching it means the app shipped without its own asset
    /// catalog entry, and `SetupWizardPearlTests` fails on exactly that — it
    /// reads the image back out of this view's tree, so a wizard that renders
    /// no Pearl is a red test rather than a quietly emptier welcome.
    private var pearl: some View {
        PearlPortrait(
            pose: .waving,
            height: PearlMascot.heroHeight,
            label: "Pearl, Cherry's cat, waving hello"
        )
    }
}

// MARK: - Appearance & theme

/// Internal rather than private so `PearlReactionTests` can reach the accent
/// swatches' own actions and prove that the tap which writes the setting is
/// the same tap that sends the hearts up.
struct SetupAppearanceStep: View {
    let reactions: PearlReactions

    @Bindable private var settings = SettingsManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var customImageStore: HomepageCustomImageStore { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: SetupMetrics.betweenCards) {
            SetupStepMasthead(
                number: 1, total: SetupWizardModel.questionCount,
                question: "How should Cherry look?"
            )
            .padding(.bottom, SetupMetrics.mastheadToControls - SetupMetrics.betweenCards)

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
                    .onChange(of: settings.appearanceMode) { _, _ in
                        reactions.fire(.choice, reduceMotion: reduceMotion)
                    }
                }
            }

            SettingsCard(
                icon: "paintpalette",
                title: "Accent Color",
                subtitle: "Tints controls and highlights across Cherry."
            ) {
                HStack(spacing: 11) {
                    ForEach(accentSwatches, id: \.option.id) { swatch in swatch }
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
                            reactions.fire(.choice, reduceMotion: reduceMotion)
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
                        reactions.fire(.choice, reduceMotion: reduceMotion)
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
                            reactions.fire(.choice, reduceMotion: reduceMotion)
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

    /// The accent swatches, MATERIALIZED as values rather than produced inside
    /// the `ForEach` builder closure — the same move `SetupExtensionsStep`
    /// makes with its rows, and for the same reason: a closure is opaque to
    /// `Mirror`, an array of values is not.
    ///
    /// What that buys here is the one test worth having about the hearts —
    /// `PearlReactionTests` reaches into this step, takes a swatch's own
    /// action and calls it, and asserts that the tap which writes the accent
    /// is the same tap that makes Pearl react. Wire the reaction to some other
    /// code path and that test goes red.
    private var accentSwatches: [AccentSwatch] {
        AccentColorOption.options.map { option in
            AccentSwatch(
                option: option,
                isSelected: settings.accentColorHex == option.hex
            ) {
                settings.accentColorHex = option.hex
                reactions.fire(.choice, reduceMotion: reduceMotion)
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

/// One subject leads: who answers your searches. Privacy is the second card
/// rather than a co-headline, because a step whose title names two things has
/// no most-important thing on it.
///
/// Internal rather than private for the same reason `SetupAppearanceStep` is:
/// a `Mirror` walk stops at a child view's boundary, so a test that wants to
/// read this step's own masthead has to be able to name the step.
struct SetupSearchPrivacyStep: View {
    let reactions: PearlReactions

    @Bindable private var settings = SettingsManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: SetupMetrics.betweenCards) {
            SetupStepMasthead(
                number: 2, total: SetupWizardModel.questionCount,
                question: "Who answers your searches?"
            )
            .padding(.bottom, SetupMetrics.mastheadToControls - SetupMetrics.betweenCards)

            SettingsCard(icon: "magnifyingglass", title: "Search") {
                SettingsLabeledRow(
                    title: "Search Engine",
                    subtitle: "Used for searches from the address bar and homepage."
                ) {
                    CherryPicker(
                        selection: $settings.searchEngine,
                        options: SearchEngine.allCases.map { .init($0, $0.rawValue) }
                    )
                    .onChange(of: settings.searchEngine) { _, _ in
                        reactions.fire(.choice, reduceMotion: reduceMotion)
                    }
                }
            }

            SettingsCard(icon: "shield.lefthalf.filled", title: "Privacy") {
                SettingsToggleRow(
                    title: "Block Ads & Trackers",
                    subtitle: "You can pause blocking per site from the toolbar.",
                    isOn: $settings.adBlockEnabled
                )
                .onChange(of: settings.adBlockEnabled) { _, _ in
                    reactions.fire(.choice, reduceMotion: reduceMotion)
                }

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

/// The last question. It is the shortest step in the wizard — one card, two
/// rows — which is why her arrival at the top of it carries the ending: her
/// bubble on this step is the goodbye (`PearlIntroScript`), delivered
/// delighted, at the same size she said hello at.
///
/// She used to sign off in a block at the BOTTOM of this step, under the card.
/// That is gone: it put two of her on one screen the moment she also started
/// arriving at the top, and of the two the arrival is the one the user reads —
/// the bottom block sat below the fold on a step that already scrolled.
///
/// The sheet still dismisses the instant Start Browsing is pressed. There is
/// no celebration animation between the press and the dismissal, deliberately:
/// making somebody watch a cat for three quarters of a second before their
/// browser appears is exactly the "in the way" this design is not allowed to
/// be.
///
/// Internal rather than private for the same reason `SetupAppearanceStep` is:
/// a test cannot walk into a step's body without being able to name the step.
struct SetupTabLayoutStep: View {
    let reactions: PearlReactions

    @Bindable private var settings = SettingsManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: SetupMetrics.betweenCards) {
            SetupStepMasthead(
                number: 5, total: SetupWizardModel.questionCount,
                question: "Where do your tabs go?"
            )
            .padding(.bottom, SetupMetrics.mastheadToControls - SetupMetrics.betweenCards)

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
                    .onChange(of: settings.useVerticalTabs) { _, _ in
                        reactions.fire(.choice, reduceMotion: reduceMotion)
                    }
                }

                Divider()

                SettingsToggleRow(title: "Show Bookmark Bar", isOn: $settings.showBookmarkBar)
                    .onChange(of: settings.showBookmarkBar) { _, _ in
                        reactions.fire(.choice, reduceMotion: reduceMotion)
                    }
            }
        }
    }
}
