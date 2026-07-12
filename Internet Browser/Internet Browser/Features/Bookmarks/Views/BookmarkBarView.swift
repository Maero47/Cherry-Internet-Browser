//
//  BookmarkBarView.swift
//  Cherry Browser
//

import SwiftUI

struct BookmarkBarView: View {
    @Bindable var repository: BookmarkRepository
    let onBookmarkClick: (Bookmark) -> Void
    var isPrivateMode: Bool = false

    /// Imported Firefox theme overrides. Both nil when no theme is active or
    /// this is a private window (private windows keep their stock look).
    private var themedToolbarBackground: Color? {
        isPrivateMode ? nil : FirefoxThemeManager.shared.toolbarBackground
    }
    private var themedToolbarText: Color? {
        isPrivateMode ? nil : FirefoxThemeManager.shared.toolbarText
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(repository.bookmarkBarItems) { bookmark in
                    BookmarkBarItemView(bookmark: bookmark) {
                        onBookmarkClick(bookmark)
                    }
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
    }
}

struct BookmarkBarItemView: View {
    let bookmark: Bookmark
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
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
        .contextMenu {
            Button("Open") { action() }
            Button("Open in New Tab") { /* TODO */ }
            Divider()
            Button("Edit...") { /* TODO */ }
            Button("Delete") { /* TODO */ }
        }
    }
}
