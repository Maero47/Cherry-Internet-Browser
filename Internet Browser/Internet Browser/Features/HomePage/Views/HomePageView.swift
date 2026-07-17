//
//  HomePageView.swift
//  Cherry Browser
//

import SwiftUI

// MARK: - Animated background

private struct HomepageBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDrifting = false

    private var settings: SettingsManager { SettingsManager.shared }
    private var firefoxThemeHasHomepageBackground: Bool {
        FirefoxThemeManager.shared.homepageBackground != nil
    }

    private var wallpaperName: String? {
        guard settings.homepageMatchesAccent, !firefoxThemeHasHomepageBackground else {
            return nil
        }

        switch settings.accentColorHex.uppercased() {
        case "DB283C": return "HomepageWallpaperDB283C"
        case "2563EB": return "HomepageWallpaper2563EB"
        case "059669": return "HomepageWallpaper059669"
        case "7C3AED": return "HomepageWallpaper7C3AED"
        case "EA580C": return "HomepageWallpaperEA580C"
        case "DB2777": return "HomepageWallpaperDB2777"
        case "0D9488": return "HomepageWallpaper0D9488"
        case "6B7280": return "HomepageWallpaper6B7280"
        default: return nil
        }
    }

    var body: some View {
        ZStack {
            if let wallpaperName {
                Image(wallpaperName)
                    .resizable()
                    .scaledToFill()
                    .id(wallpaperName)
                    .transition(.opacity)

                wallpaperLegibilityScrim
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
            colors: settings.homepageGradientColors
        )
        .overlay {
            // The existing themes are intentionally deep. This wash turns them
            // into soft, legible pastels in light mode without changing a theme's hue.
            // An imported Firefox theme's ntp_background is an absolute color
            // (not light/dark adaptive), so it gets no wash at all.
            if !firefoxThemeHasHomepageBackground {
                Color.white.opacity(colorScheme == .light ? 0.7 : 0.035)
            }
        }
    }

    private var wallpaperLegibilityScrim: some View {
        ZStack {
            (colorScheme == .light ? Color.white : Color.black)
                .opacity(colorScheme == .light ? 0.32 : 0.28)

            RadialGradient(
                colors: [
                    (colorScheme == .light ? Color.white : Color.black).opacity(0.22),
                    .clear
                ],
                center: .center,
                startRadius: 80,
                endRadius: 720
            )
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Home page

struct HomePageView: View {
    @Bindable var repository: ShortcutRepository
    let onShortcutClick: (URL) -> Void
    let onSearch: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isSearchFocused: Bool
    @State private var searchText = ""
    @State private var showingAddShortcut = false
    @State private var editingShortcut: Shortcut?

    private var accent: Color { SettingsManager.shared.accentColor }
    private var foreground: Color {
        // An active Firefox theme's ntp_text keeps text legible against its
        // absolute ntp_background; otherwise stay scheme-adaptive as before.
        if let themeText = FirefoxThemeManager.shared.homepageText {
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
        .background(HomepageBackground())
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

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    isSearchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(foreground.opacity(0.35))
                }
                .buttonStyle(.plain)
                .help("Clear")
                .transition(.scale.combined(with: .opacity))
            } else {
                Text("return")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(foreground.opacity(0.32))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(foreground.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 19)
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
                    .tint(SettingsManager.shared.accentColor)
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
