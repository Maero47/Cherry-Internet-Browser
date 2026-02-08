//
//  HomePageView.swift
//  Cherry Browser
//

import SwiftUI

// MARK: - Animated Gradient Background

struct AnimatedGradientBackground: View {
    @State private var animateGradient = false

    var body: some View {
        MeshGradient(
            width: 3, height: 3,
            points: [
                [0.0, 0.0], [0.5, 0.0], [1.0, 0.0],
                [0.0, 0.5], [animateGradient ? 0.6 : 0.4, animateGradient ? 0.4 : 0.6], [1.0, 0.5],
                [0.0, 1.0], [0.5, 1.0], [1.0, 1.0]
            ],
            colors: [
                Color(red: 0.5, green: 0.0, blue: 0.1),
                Color(red: 0.6, green: 0.0, blue: 0.15),
                Color(red: 0.4, green: 0.0, blue: 0.2),

                Color(red: 0.35, green: 0.0, blue: 0.12),
                Color(red: animateGradient ? 0.55 : 0.3, green: 0.0, blue: animateGradient ? 0.08 : 0.18),
                Color(red: 0.45, green: 0.0, blue: 0.15),

                Color(red: 0.15, green: 0.0, blue: 0.08),
                Color(red: 0.2, green: 0.0, blue: 0.1),
                Color(red: 0.1, green: 0.0, blue: 0.05)
            ]
        )
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 6).repeatForever(autoreverses: true)) {
                animateGradient.toggle()
            }
        }
    }
}

// MARK: - Home Page

struct HomePageView: View {
    @Bindable var repository: ShortcutRepository
    let onShortcutClick: (URL) -> Void
    let onSearch: (String) -> Void

    @State private var searchText: String = ""
    @State private var showingAddShortcut: Bool = false
    @State private var editingShortcut: Shortcut? = nil

    private let columns = [
        GridItem(.adaptive(minimum: 100, maximum: 120), spacing: 16)
    ]

    var body: some View {
        GeometryReader { geo in
            let isCompact = geo.size.width < 700
            let logoSize = min(geo.size.width * 0.25, geo.size.height * 0.35)
            let titleSize = min(max(logoSize * 0.22, 28), 72)
            let searchMaxWidth = min(geo.size.width * 0.7, 600.0)
            let shortcutsMaxWidth = min(geo.size.width * 0.7, 600.0)

            ScrollView {
                VStack(spacing: isCompact ? 24 : 40) {
                    Spacer()
                        .frame(height: isCompact ? 20 : 40)

                    // Logo + Title
                    if isCompact {
                        VStack(spacing: -4) {
                            Image("CherryLogo")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: logoSize, height: logoSize)

                            Text("Cherry")
                                .font(.system(size: titleSize, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                        }
                    } else {
                        HStack(spacing: -8) {
                            Image("CherryLogo")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: logoSize, height: logoSize)

                            Text("Cherry")
                                .font(.system(size: titleSize, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                        }
                    }

                    // Search bar
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 16))
                            .foregroundStyle(.white.opacity(0.5))

                        TextField("Search or enter URL", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 16))
                            .foregroundStyle(.white)
                            .onSubmit {
                                if !searchText.isEmpty {
                                    onSearch(searchText)
                                    searchText = ""
                                }
                            }

                        if !searchText.isEmpty {
                            Button(action: { searchText = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .background(Color.white.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                    )
                    .frame(maxWidth: searchMaxWidth)

                    // Shortcuts grid
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Shortcuts")
                                .font(.headline)
                                .foregroundStyle(.white.opacity(0.7))

                            Spacer()

                            Button(action: { showingAddShortcut = true }) {
                                Image(systemName: "plus")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                            .help("Add shortcut")
                        }
                        .padding(.horizontal, 8)

                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(repository.shortcuts) { shortcut in
                                ShortcutItemView(
                                    shortcut: shortcut,
                                    onClick: { onShortcutClick(shortcut.url) },
                                    onEdit: { editingShortcut = shortcut },
                                    onDelete: { repository.deleteShortcut(shortcut) }
                                )
                            }

                            AddShortcutButton {
                                showingAddShortcut = true
                            }
                        }
                    }
                    .frame(maxWidth: shortcutsMaxWidth)
                    .padding(.horizontal)

                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding()
            }
        }
        .background(AnimatedGradientBackground())
        .sheet(isPresented: $showingAddShortcut) {
            AddShortcutSheet(repository: repository)
        }
        .sheet(item: $editingShortcut) { shortcut in
            EditShortcutSheet(shortcut: shortcut, repository: repository)
        }
    }
}

// MARK: - Shortcut Item

struct ShortcutItemView: View {
    let shortcut: Shortcut
    let onClick: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovering: Bool = false

    var body: some View {
        Button(action: onClick) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.1))
                        .frame(width: 56, height: 56)

                    if let favicon = shortcut.favicon {
                        Image(nsImage: favicon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 28, height: 28)
                    } else {
                        Text(shortcut.title.prefix(1).uppercased())
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(.white)
                    }
                }

                Text(shortcut.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(0.9))
            }
            .frame(width: 100, height: 90)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isHovering ? Color.white.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
        .contextMenu {
            Button("Edit") { onEdit() }
            Divider()
            Button("Delete", role: .destructive) { onDelete() }
        }
    }
}

// MARK: - Add Shortcut Button

struct AddShortcutButton: View {
    let action: () -> Void

    @State private var isHovering: Bool = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.1))
                        .frame(width: 56, height: 56)

                    Image(systemName: "plus")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(.white.opacity(0.5))
                }

                Text("Add shortcut")
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(0.5))
            }
            .frame(width: 100, height: 90)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isHovering ? Color.white.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

// MARK: - Add Shortcut Sheet

struct AddShortcutSheet: View {
    @Bindable var repository: ShortcutRepository
    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var urlString: String = ""

    var body: some View {
        VStack(spacing: 20) {
            Text("Add Shortcut")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("Shortcut name", text: $title)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("URL")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("https://example.com", text: $urlString)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Add") {
                    addShortcut()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.isEmpty || urlString.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 340)
    }

    private func addShortcut() {
        var finalURL = urlString
        if !finalURL.hasPrefix("http://") && !finalURL.hasPrefix("https://") {
            finalURL = "https://\(finalURL)"
        }

        guard let url = URL(string: finalURL) else { return }

        // Repository auto-fetches favicon
        repository.addShortcut(url: url, title: title)
        dismiss()
    }
}

// MARK: - Edit Shortcut Sheet

struct EditShortcutSheet: View {
    let shortcut: Shortcut
    @Bindable var repository: ShortcutRepository
    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var urlString: String = ""

    var body: some View {
        VStack(spacing: 20) {
            Text("Edit Shortcut")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("Shortcut name", text: $title)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("URL")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("https://example.com", text: $urlString)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save") {
                    saveShortcut()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.isEmpty || urlString.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 340)
        .onAppear {
            title = shortcut.title
            urlString = shortcut.url.absoluteString
        }
    }

    private func saveShortcut() {
        var finalURL = urlString
        if !finalURL.hasPrefix("http://") && !finalURL.hasPrefix("https://") {
            finalURL = "https://\(finalURL)"
        }

        guard let url = URL(string: finalURL) else { return }

        var updated = shortcut
        updated.title = title
        updated.url = url

        // If URL changed, clear favicon and let repository auto-fetch
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
