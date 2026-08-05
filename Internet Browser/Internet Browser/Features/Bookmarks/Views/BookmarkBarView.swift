//
//  BookmarkBarView.swift
//  Cherry Browser
//

import SwiftUI

struct BookmarkBarView: View {
    @Bindable var repository: BookmarkRepository
    let onBookmarkClick: (Bookmark) -> Void
    /// ⌘-click, middle-click and "Open in New Tab" — opens in the background.
    var onOpenInNewTab: ((Bookmark) -> Void)? = nil
    var isPrivateMode: Bool = false

    /// The bookmark whose "Edit…" sheet is open. Lives here rather than on the
    /// item so the sheet survives the item view being rebuilt by the repository
    /// refresh that a rename triggers.
    @State private var editingBookmark: Bookmark? = nil

    /// Imported Firefox theme overrides. Both nil when no theme is active or
    /// this is a private window (private windows keep their stock look).
    private var themedToolbarBackground: Color? {
        isPrivateMode ? nil : FirefoxThemeManager.shared.toolbarBackground
    }
    /// Resolved the same way the navigation bar resolves it, and for the same
    /// reason: a theme names one `toolbar_text` for both appearances, so on the
    /// wrong side of the crossover it would put light labels on a pale bar.
    private var themedToolbarText: Color? {
        guard !isPrivateMode, FirefoxThemeManager.shared.activeTheme != nil else { return nil }
        return ThemeContrast.toolbarGlyph(
            themeText: FirefoxThemeManager.shared.toolbarText, appearance: colorScheme
        )
    }

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(repository.bookmarkBarItems) { bookmark in
                    BookmarkBarItemView(
                        bookmark: bookmark,
                        action: { onBookmarkClick(bookmark) },
                        onOpenInNewTab: onOpenInNewTab.map { open in { open(bookmark) } },
                        onEdit: { editingBookmark = bookmark },
                        onDelete: { repository.deleteBookmark(bookmark) }
                    )
                }

                if repository.bookmarkBarItems.isEmpty {
                    Text("Drag bookmarks here or right-click to add")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 28)
        // Hierarchical styles (.secondary) on the items resolve against this,
        // so bookmark titles/icons follow the theme's toolbar_text;
        // Color.primary is the stock look when unthemed.
        .foregroundStyle(themedToolbarText ?? Color.primary)
        .background {
            ZStack {
                if !isPrivateMode && FirefoxThemeManager.shared.hasHeaderBackdrop {
                    // Firefox compositing: the opaque frame color + header
                    // images back the bar, and the theme's own `toolbar`
                    // color (often semi- or fully transparent) is layered on
                    // top — so transparent-toolbar themes show frame/images
                    // through instead of the app's default material.
                    ThemeHeaderBackdropView()
                    if let toolbarOverlay = FirefoxThemeManager.shared.toolbarColor {
                        Rectangle().fill(toolbarOverlay)
                    }
                } else if let themedToolbarBackground {
                    Rectangle().fill(themedToolbarBackground)
                } else {
                    Rectangle().fill(.bar)
                    if isPrivateMode { Color.purple.opacity(0.12) }
                }
            }
        }
        .sheet(item: $editingBookmark) { bookmark in
            EditBookmarkView(bookmark: bookmark) { updated in
                repository.updateBookmark(updated)
            }
        }
    }
}

struct BookmarkBarItemView: View {
    let bookmark: Bookmark
    let action: () -> Void
    var onOpenInNewTab: (() -> Void)? = nil
    var onEdit: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    @State private var isHovering = false

    /// ⌘-click opens in a background tab, a plain click navigates here — the
    /// behavior every browser's bookmark bar has.
    private func open() {
        if NSEvent.isCommandClick, let onOpenInNewTab {
            onOpenInNewTab()
        } else {
            action()
        }
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 4) {
                if let favicon = bookmark.favicon {
                    Image(nsImage: favicon)
                        .resizable()
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "globe")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Text(bookmark.title)
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovering ? Color.gray.opacity(0.2) : Color.clear)
            )
            .animation(.easeInOut(duration: 0.12), value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
        .overlay {
            if let onOpenInNewTab {
                AuxClickCatcher(onMiddleClick: onOpenInNewTab)
            }
        }
        .cherryContextMenu {
            CherryMenuItem.action("Open") { action() }
            if let onOpenInNewTab {
                CherryMenuItem.action("Open in New Tab") { onOpenInNewTab() }
            }
            CherryMenuItem.separator
            CherryMenuItem.action("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(bookmark.url.absoluteString, forType: .string)
            }
            CherryMenuItem.separator
            if let onEdit {
                CherryMenuItem.action("Edit…") { onEdit() }
            }
            if let onDelete {
                CherryMenuItem.action("Delete", destructive: true) { onDelete() }
            }
        }
    }
}

/// Rename a bookmark / change its folder / move it in or out of the bookmark
/// bar. Reached from the bookmark bar's "Edit…" context-menu item, which had no
/// implementation and no alternative — the bar was the one surface where you
/// could not change or remove a bookmark you had saved.
struct EditBookmarkView: View {
    @Environment(\.dismiss) private var dismiss

    let bookmark: Bookmark
    let onSave: (Bookmark) -> Void

    @State private var title: String = ""
    @State private var urlString: String = ""
    @State private var selectedFolder: String? = nil
    @State private var isInBookmarkBar: Bool = false

    @Bindable private var repository = BookmarkRepository.shared

    /// Save is blocked on anything that wouldn't survive a round trip: an empty
    /// name, or a URL that doesn't parse.
    private var editedURL: URL? {
        URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                if let favicon = bookmark.favicon {
                    Image(nsImage: favicon)
                        .resizable()
                        .frame(width: 32, height: 32)
                } else {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(SettingsManager.shared.accentColor)
                }

                Text("Edit Bookmark")
                    .font(.headline)

                Spacer()
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("Bookmark name", text: $title)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Address")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("https://example.com", text: $urlString)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Folder")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    CherryPicker(
                        selection: $selectedFolder,
                        options: [.init(nil, "None")] + repository.folders.map { .init($0, $0) }
                    )
                }

                Toggle("Show in Bookmark Bar", isOn: $isInBookmarkBar)
                    .toggleStyle(.checkbox)
            }

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save") {
                    guard let url = editedURL else { return }
                    var updated = bookmark
                    updated.title = title
                    updated.url = url
                    updated.folder = selectedFolder
                    updated.isInBookmarkBar = isInBookmarkBar
                    onSave(updated)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(title.isEmpty || editedURL == nil)
            }
        }
        .padding(20)
        .frame(width: 350)
        .onAppear {
            title = bookmark.title
            urlString = bookmark.url.absoluteString
            selectedFolder = bookmark.folder
            isInBookmarkBar = bookmark.isInBookmarkBar
        }
    }
}
