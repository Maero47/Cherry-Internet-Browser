//
//  HomePageView.swift
//  Cherry Browser
//

import SwiftUI

// MARK: - Animated background

private struct HomepageBackground: View {
    /// Private windows are never themed, so an imported theme's
    /// `ntp_background` never reaches an incognito homepage. Keyed on the
    /// window, matching every other themed surface — see `HomePageView`.
    let isPrivateMode: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDrifting = false

    private var settings: SettingsManager { SettingsManager.shared }

    /// What is actually being painted. See `HomepageBackgroundResolver`.
    private var source: HomepageBackgroundSource {
        settings.homepageBackgroundSource(isPrivate: isPrivateMode)
    }

    private var themeBackgroundIsActive: Bool { source == .themeBackground }

    private var wallpaperName: String? {
        guard case .accentWallpaper(let assetName) = source else { return nil }
        return assetName
    }

    var body: some View {
        ZStack {
            if let wallpaperName {
                Image(wallpaperName)
                    .resizable()
                    .scaledToFill()
                    .id(wallpaperName)
                    .transition(.opacity)

                HomepageWallpaperScrim()
            } else {
                fallbackGradient
                    .transition(.opacity)
            }
        }
        .clipped()
        .animation(.easeInOut(duration: 0.4), value: wallpaperName)
        .ignoresSafeArea()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 12).repeatForever(autoreverses: true)) {
                isDrifting.toggle()
            }
        }
    }

    private var fallbackGradient: some View {
        MeshGradient(
            width: 3,
            height: 3,
            points: [
                [0.0, 0.0], [0.5, 0.0], [1.0, 0.0],
                [0.0, 0.5],
                [isDrifting ? 0.62 : 0.38, isDrifting ? 0.38 : 0.62],
                [1.0, 0.5],
                [0.0, 1.0], [0.5, 1.0], [1.0, 1.0]
            ],
            colors: settings.homepageGradientColors(isPrivate: isPrivateMode)
        )
        .overlay {
            // An imported Firefox theme's ntp_background is an absolute color
            // (not light/dark adaptive), so it gets no wash at all.
            if !themeBackgroundIsActive {
                HomepageGradientWash()
            }
        }
    }

}

/// The wash the homepage lays over a gradient background.
///
/// The curated themes and the accent-derived palette are intentionally deep;
/// this turns them into soft, legible pastels in light mode without changing a
/// hue. Shared with the Settings ▸ Homepage Background swatches, which preview
/// those same gradients — at 0.7 opacity in light mode it is the difference
/// between a swatch that matches the homepage and one that reads far more
/// saturated than anything the user will see.
struct HomepageGradientWash: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Color.white
            .opacity(colorScheme == .light ? 0.7 : 0.035)
            .allowsHitTesting(false)
    }
}

/// The wash the homepage lays over a wallpaper so text stays legible.
///
/// Shared with the Settings ▸ Homepage Background "Auto" thumbnail, which
/// previews the same wallpaper: without it the swatch reads noticeably more
/// saturated than what the homepage actually paints. One definition, so the
/// two can't drift apart.
struct HomepageWallpaperScrim: View {
    /// Radii of the centre highlight, in points. The homepage uses the
    /// defaults, sized for a window; the Settings thumbnail scales them down
    /// to its ~1/10-scale tile so the highlight falls off inside the tile
    /// instead of flooding it.
    var startRadius: CGFloat = 80
    var endRadius: CGFloat = 720

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            (colorScheme == .light ? Color.white : Color.black)
                .opacity(colorScheme == .light ? 0.32 : 0.28)

            RadialGradient(
                colors: [
                    (colorScheme == .light ? Color.white : Color.black).opacity(0.22),
                    .clear
                ],
                center: .center,
                startRadius: startRadius,
                endRadius: endRadius
            )
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Home page

struct HomePageView: View {
    @Bindable var repository: ShortcutRepository
    /// Private windows are never themed by an imported Firefox theme. Keyed on
    /// the WINDOW, like every other themed surface (`NavigationBarView`,
    /// `OmniboxView`, `BookmarkBarView`, both tab bars, both sidebars) — a tab's
    /// own `isPrivate` can diverge from its window's inside a private window,
    /// which would theme the homepage while the chrome around it stayed plain.
    var isPrivateMode: Bool = false
    let onShortcutClick: (URL) -> Void
    let onSearch: (String) -> Void
    /// The homepage's own way into the AI: what is in the search field is
    /// routed to the chat instead of to the search engine. Empty text opens a
    /// general chat, which is the same thing the panel does with a page it
    /// can't read.
    let onAskAI: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isSearchFocused: Bool
    @State private var searchText = ""
    @State private var showingAddShortcut = false
    @State private var editingShortcut: Shortcut?

    private var accent: Color { SettingsManager.shared.accentColor }
    private var foreground: Color {
        // An active Firefox theme's ntp_text keeps text legible against its
        // absolute ntp_background — but only while that background is the one
        // being painted. Against Cherry's own wallpaper it would be a colour
        // chosen for a surface that isn't there, so we stay scheme-adaptive.
        // In a private window the source is never `.themeBackground`, so this
        // is also the incognito gate.
        if SettingsManager.shared.homepageBackgroundSource(isPrivate: isPrivateMode) == .themeBackground,
           let themeText = FirefoxThemeManager.shared.homepageText {
            return themeText
        }
        return colorScheme == .dark ? .white : Color(red: 0.09, green: 0.08, blue: 0.11)
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 680
            let contentWidth = min(max(geometry.size.width - 56, 320), 760)

            ScrollView {
                VStack(spacing: compact ? 26 : 34) {
                    timeHeader
                    searchField
                    shortcutsSection
                }
                .frame(maxWidth: contentWidth)
                .frame(minHeight: max(geometry.size.height - 48, 540))
                .padding(.vertical, 24)
                .padding(.horizontal, 28)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .foregroundStyle(foreground)
        .background(HomepageBackground(isPrivateMode: isPrivateMode))
        .onAppear {
            DispatchQueue.main.async { isSearchFocused = true }
        }
        .sheet(isPresented: $showingAddShortcut) {
            AddShortcutSheet(repository: repository)
        }
        .sheet(item: $editingShortcut) { shortcut in
            EditShortcutSheet(shortcut: shortcut, repository: repository)
        }
    }

    private var timeHeader: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(spacing: 10) {
                Text(context.date, format: .dateTime.hour().minute())
                    .font(.system(size: 68, weight: .light, design: .rounded))
                    .tracking(-2)
                    .monospacedDigit()
                    .contentTransition(.numericText())

                Text(greeting(for: context.date))
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(foreground.opacity(0.62))
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 13) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(isSearchFocused ? accent : foreground.opacity(0.42))

            TextField("Search or enter a website", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 16, weight: .regular))
                .focused($isSearchFocused)
                .onSubmit(submitSearch)

            // Never more than two controls. The `return` chip that used to sit
            // here rendered ONLY while the field was empty — the one moment
            // Return does nothing (`submitSearch` guards on an empty query) —
            // so it hid itself exactly when it would have been true. What it
            // was trying to say now lives in these two tooltips.
            HStack(spacing: 4) {
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        isSearchFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(foreground.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                    .help("Clear what you typed. Return searches for it.")
                    .transition(.scale.combined(with: .opacity))
                }

                AskAIButton(
                    foreground: foreground,
                    accent: accent,
                    hasQuery: !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    action: askAI
                )
            }
        }
        // 19 leading, 13 trailing: the Ask control carries a 30pt hit target
        // around a 17pt glyph, so the extra 6pt of its own box is taken back
        // here. Both glyphs then sit ~28pt from their edge — the field stays
        // as symmetric as it looks today.
        .padding(.leading, 19)
        .padding(.trailing, 13)
        .frame(height: 58)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isSearchFocused ? accent.opacity(0.65) : foreground.opacity(0.1), lineWidth: isSearchFocused ? 1.5 : 1)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.22 : 0.1), radius: 24, y: 10)
        .animation(.easeOut(duration: 0.18), value: isSearchFocused)
        .animation(.easeOut(duration: 0.15), value: searchText.isEmpty)
        .onTapGesture { isSearchFocused = true }
        .accessibilityElement(children: .contain)
    }

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Favorites")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                    Text("Your corner of the web")
                        .font(.system(size: 12))
                        .foregroundStyle(foreground.opacity(0.48))
                }

                Spacer()

                Button {
                    showingAddShortcut = true
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(foreground.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Add favorite")
            }
            .padding(.horizontal, 4)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 104, maximum: 124), spacing: 12)],
                spacing: 12
            ) {
                ForEach(repository.shortcuts) { shortcut in
                    ShortcutItemView(
                        shortcut: shortcut,
                        foreground: foreground,
                        accent: accent,
                        onClick: { onShortcutClick(shortcut.url) },
                        onEdit: { editingShortcut = shortcut },
                        onDelete: { repository.deleteShortcut(shortcut) }
                    )
                }

                AddShortcutButton(foreground: foreground) {
                    showingAddShortcut = true
                }
            }
        }
    }

    private func greeting(for date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
    }

    private func submitSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        onSearch(query)
        searchText = ""
    }

    /// Sends the field to the AI instead of the search engine. Unguarded, in
    /// contrast to `submitSearch`: an empty field is a general chat, not a
    /// reason to do nothing.
    private func askAI() {
        onAskAI(searchText.trimmingCharacters(in: .whitespacesAndNewlines))
        searchText = ""
    }
}

// MARK: - Ask control

/// The search field's trailing control: take what is in the field to the AI.
///
/// Colour follows the rule the leading magnifier already sets — the accent is
/// a reply to the user (hover, press, keyboard focus) and never a resting
/// state. It rests one rung heavier than the magnifier at `0.62` rather than
/// `0.42`: the magnifier is decoration, this is a control, and `0.42`
/// composited on the field's material measures ~2.6:1 in light mode against a
/// 4.5:1 floor (`0.62` measures 4.5–5.1:1 light, 5.1–7.3:1 dark).
private struct AskAIButton: View {
    let foreground: Color
    let accent: Color
    /// Whether the field has something to ask about. Only changes the words:
    /// the control is in the first frame and stays there either way.
    let hasQuery: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    private var actionName: String {
        hasQuery ? "Ask Cherry AI about what you typed" : "Ask Cherry AI"
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "sparkles")
                .font(.system(size: 17, weight: .medium))
                .frame(width: 30, height: 30)
                .contentShape(Capsule())
        }
        .buttonStyle(
            AskAIButtonStyle(
                isEngaged: isHovering || isFocused,
                foreground: foreground,
                accent: accent,
                reduceMotion: reduceMotion
            )
        )
        // Tab-reachable, with a ring drawn in the accent and in the shape
        // family the page already uses. The system's own focus effect is
        // switched off so there is exactly one ring, and it is this one.
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .overlay {
            Capsule()
                .stroke(accent.opacity(0.65), lineWidth: 1.5)
                .opacity(isFocused ? 1 : 0)
        }
        .onHover { isHovering = $0 }
        .keyboardShortcut(.return, modifiers: .command)
        .help("\(actionName) (Cmd+Return)")
        .accessibilityLabel(actionName)
    }
}

/// The control's two authored moments, both replies to the user: colour
/// resolving to the accent, and the press. Nothing here runs on its own — the
/// homepage is redrawn on every new tab, and an idle animation on a surface
/// seen that often is noise by the end of the first day.
private struct AskAIButtonStyle: ButtonStyle {
    /// Hovered or holding keyboard focus. Pressed is folded in below, so a
    /// button activated from the keyboard colours too.
    let isEngaged: Bool
    let foreground: Color
    let accent: Color
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        let engaged = isEngaged || configuration.isPressed
        return configuration.label
            .foregroundStyle(engaged ? accent : foreground.opacity(0.62))
            // Ease-out both times: ease-in would hold back the first few
            // milliseconds, which is the part being watched.
            .animation(.easeOut(duration: 0.12), value: engaged)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Shortcut tiles

private struct ShortcutItemView: View {
    let shortcut: Shortcut
    let foreground: Color
    let accent: Color
    let onClick: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: onClick) {
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(foreground.opacity(isHovering ? 0.13 : 0.09))

                    if let favicon = shortcut.favicon {
                        Image(nsImage: favicon)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 30, height: 30)
                    } else {
                        Text(shortcut.title.prefix(1).uppercased())
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .foregroundStyle(accent)
                    }
                }
                .frame(width: 52, height: 52)

                Text(shortcut.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 104)
            .background(foreground.opacity(isHovering ? 0.09 : 0.045), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(foreground.opacity(isHovering ? 0.16 : 0.07))
            }
            .overlay(alignment: .topTrailing) {
                Menu {
                    Button("Edit", systemImage: "pencil", action: onEdit)
                    Divider()
                    Button("Remove", systemImage: "trash", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 27, height: 25)
                        .background(.regularMaterial, in: Capsule())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(7)
                .opacity(isHovering ? 1 : 0)
                .accessibilityLabel("Actions for \(shortcut.title)")
            }
            .scaleEffect(isHovering && !reduceMotion ? 1.025 : 1)
            .shadow(color: .black.opacity(isHovering ? 0.1 : 0), radius: 12, y: 6)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.16), value: isHovering)
        .contextMenu {
            Button("Edit", action: onEdit)
            Divider()
            Button("Remove", role: .destructive, action: onDelete)
        }
        .help(shortcut.url.host ?? shortcut.url.absoluteString)
        .accessibilityLabel(shortcut.title)
        .accessibilityHint("Opens \(shortcut.url.host ?? shortcut.url.absoluteString)")
    }
}

private struct AddShortcutButton: View {
    let foreground: Color
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 52, height: 52)
                    .background(foreground.opacity(isHovering ? 0.12 : 0.07), in: RoundedRectangle(cornerRadius: 15, style: .continuous))

                Text("Add favorite")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(foreground.opacity(isHovering ? 0.8 : 0.52))
            .padding(.horizontal, 10)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 104)
            .background(foreground.opacity(isHovering ? 0.07 : 0.025), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(foreground.opacity(0.09), style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.16), value: isHovering)
        .help("Add favorite")
    }
}

// MARK: - Shortcut editor

private struct ShortcutForm: View {
    let heading: String
    let actionTitle: String
    @Binding var title: String
    @Binding var urlString: String
    let onCancel: () -> Void
    let onCommit: () -> Void

    @FocusState private var focusedField: Field?
    private enum Field { case title, url }

    private var canCommit: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                Image(systemName: "star.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(SettingsManager.shared.accentColor)
                    .frame(width: 36, height: 36)
                    .background(SettingsManager.shared.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 2) {
                    Text(heading).font(.headline)
                    Text("Keep your favorite sites close at hand.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 14) {
                labeledField("Name", placeholder: "Website name", text: $title, field: .title)
                labeledField("Address", placeholder: "example.com", text: $urlString, field: .url)
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(actionTitle, action: onCommit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canCommit)
            }
        }
        .padding(26)
        .frame(width: 400)
        .onAppear { focusedField = .title }
    }

    private func labeledField(
        _ label: String,
        placeholder: String,
        text: Binding<String>,
        field: Field
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: field)
        }
    }
}

private struct AddShortcutSheet: View {
    @Bindable var repository: ShortcutRepository
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var urlString = ""

    var body: some View {
        ShortcutForm(
            heading: "Add a favorite",
            actionTitle: "Add Favorite",
            title: $title,
            urlString: $urlString,
            onCancel: { dismiss() },
            onCommit: addShortcut
        )
    }

    private func addShortcut() {
        guard let url = normalizedURL(from: urlString) else { return }
        repository.addShortcut(
            url: url,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        dismiss()
    }
}

private struct EditShortcutSheet: View {
    let shortcut: Shortcut
    @Bindable var repository: ShortcutRepository
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var urlString: String

    init(shortcut: Shortcut, repository: ShortcutRepository) {
        self.shortcut = shortcut
        self.repository = repository
        _title = State(initialValue: shortcut.title)
        _urlString = State(initialValue: shortcut.url.absoluteString)
    }

    var body: some View {
        ShortcutForm(
            heading: "Edit favorite",
            actionTitle: "Save Changes",
            title: $title,
            urlString: $urlString,
            onCancel: { dismiss() },
            onCommit: saveShortcut
        )
    }

    private func saveShortcut() {
        guard let url = normalizedURL(from: urlString) else { return }
        var updated = shortcut
        updated.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.url = url

        if url != shortcut.url {
            updated.favicon = nil
            repository.updateShortcut(updated)
            repository.fetchFavicon(for: updated)
        } else {
            repository.updateShortcut(updated)
        }
        dismiss()
    }
}

private func normalizedURL(from input: String) -> URL? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
    guard let url = URL(string: candidate), url.host != nil else { return nil }
    return url
}
