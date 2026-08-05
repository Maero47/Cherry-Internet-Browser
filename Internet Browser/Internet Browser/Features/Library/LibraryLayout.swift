//
//  LibraryLayout.swift
//  Cherry Browser
//
//  The shell History, Bookmarks and Downloads are all poured into: a scope
//  rail, a header, a list that fills the window, selection, bulk actions and
//  the keyboard.
//
//  ## What this replaces
//
//  A 760pt column centred in a 1500pt window, with the list stopping partway
//  down and leaving a dead panel below it. The column was a 300pt sidebar view
//  that had been told to be wider; nothing in it knew what to do with the extra
//  room, and nothing at all knew what to do with the extra height.
//
//  ## How this uses the window
//
//  Width buys structure, not margin:
//
//      >= 700pt   scope rail + list with every column
//      >= 460pt   scope strip above the list, list with every column
//      <  460pt   scope strip + two-line rows (this is the 300pt sidebar)
//
//  Height is used by the list, always: it is the last thing in the stack and it
//  is greedy. There is no dead column under a short list, because the list is
//  the column.
//

import SwiftUI

/// Where a library screen is being shown, which decides two things width
/// cannot: whether there is a close button, and what a single click does.
///
/// A 300pt sidebar is a launcher — one click opens, the way it always has, and
/// its ✕ closes the sidebar it is actually inside. A full page is a manager —
/// one click selects, Return or a double click opens, and there is no ✕
/// because there is no modal to dismiss. That last part is deliberate: a ✕ in
/// the header of `cherry://history` claimed to be a sheet, was not one, and
/// never said where closing would take you.
enum LibraryPresentation {
    case page
    case sidebar
}

/// The action that throws things away. It has a home at the foot of the rail
/// rather than in the header, in ordinary text rather than in red, because it
/// is the thing on this screen the user wants least often.
struct LibraryDestructiveAction {
    let title: String
    let icon: String
    var isEnabled: Bool = true
    let action: () -> Void
}

struct LibraryLayout<Item: Identifiable & Hashable, Row: View>: View {
    let title: String
    let searchPrompt: String
    let presentation: LibraryPresentation

    let scopes: [LibraryScope]
    @Binding var scopeID: String
    @Binding var searchText: String
    let sections: [LibrarySection<Item>]
    @Binding var selection: Set<Item.ID>

    let emptyState: LibraryEmptyState
    let noResultsState: LibraryEmptyState
    var isLoading: Bool = false
    var loadingLabel: String = "Loading"

    var destructive: LibraryDestructiveAction?
    /// Shown only in `.sidebar`, where there is a sidebar to close.
    var onClose: (() -> Void)?

    let onOpen: ([Item]) -> Void
    let onRemove: ([Item]) -> Void
    let rowMenu: (Item) -> [CherryMenuItem]
    @ViewBuilder let row: (Item, LibraryDensity) -> Row

    @FocusState private var isSearchFocused: Bool
    @FocusState private var isListFocused: Bool
    /// Where ↑/↓ currently sits, and the anchor a shift-click extends from.
    @State private var cursor: Item.ID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasEntered = false

    private var accent: Color { SettingsManager.shared.accentColor }
    private var allItems: [Item] { sections.flatMap(\.items) }
    private var selectedItems: [Item] { allItems.filter { selection.contains($0.id) } }
    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let showsRail = presentation == .page && width >= 760
            let density = LibraryDensity.forListWidth(width - (showsRail ? 208 : 0))

            HStack(spacing: 0) {
                if showsRail {
                    LibraryScopeRail(
                        title: title,
                        scopes: scopes,
                        selection: $scopeID,
                        footer: destructive.map { AnyView(destructiveButton($0)) }
                    )
                    .frame(width: 208)

                    Divider()
                }

                VStack(spacing: 0) {
                    header(showsRail: showsRail, density: density)
                    Divider()
                    content(density: density)
                    selectionBar
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LibraryPalette.listSurface)
            }
            // A considered entrance, once, because these screens are opened
            // rather than lived in. It never fires on a selection change, a
            // scope change or a keystroke — only on the screen arriving — and
            // it does not fire at all under Reduce Motion.
            .opacity(hasEntered || reduceMotion ? 1 : 0)
            .offset(y: hasEntered || reduceMotion ? 0 : 6)
            .onAppear {
                guard !reduceMotion else { hasEntered = true; return }
                withAnimation(.easeOut(duration: 0.22)) { hasEntered = true }
            }
        }
        .background(LibraryPalette.listSurface)
        .tint(accent)
        // ⌘F and ⌘A are real commands, so they are real buttons with real key
        // equivalents rather than a key handler that only works when the right
        // thing happens to be focused.
        .background {
            ZStack {
                Button("Search") { isSearchFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
                Button("Select All") { selection = Set(allItems.map(\.id)) }
                    .keyboardShortcut("a", modifiers: .command)
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func header(showsRail: Bool, density: LibraryDensity) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                if !showsRail {
                    Text(title)
                        .font(.system(size: density == .compact ? 14 : 17, weight: .bold))
                        .lineLimit(1)
                }

                if showsRail {
                    Text(countSummary)
                        .font(.system(size: 12))
                        .foregroundStyle(LibraryPalette.supporting)
                }

                Spacer(minLength: 8)

                LibrarySearchField(
                    prompt: searchPrompt,
                    text: $searchText,
                    showsShortcutHint: density.isColumnar,
                    isFocused: $isSearchFocused
                )
                .frame(maxWidth: density == .compact ? .infinity : 260)

                // With no rail there is no foot to put it in, so the quiet
                // destructive button rides along here — still unaccented,
                // still last in the reading order.
                if !showsRail, let destructive {
                    compactDestructiveButton(destructive)
                }

                if presentation == .sidebar, let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(LibraryPalette.supporting)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Close the sidebar")
                    .accessibilityLabel("Close the sidebar")
                }
            }

            if !showsRail {
                LibraryScopeStrip(scopes: scopes, selection: $scopeID)
                    .padding(.horizontal, -14)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var countSummary: String {
        let total = allItems.count
        let scopeTitle = scopes.first { $0.id == scopeID }?.title ?? ""
        if isSearching {
            return total == 1 ? "1 match" : "\(total) matches"
        }
        return total == 1 ? "1 item in \(scopeTitle)" : "\(total) items in \(scopeTitle)"
    }

    @ViewBuilder
    private func destructiveButton(_ action: LibraryDestructiveAction) -> some View {
        Button(action: action.action) {
            HStack(spacing: 7) {
                Image(systemName: action.icon)
                    .font(.system(size: 11))
                Text(action.title)
                    .font(.system(size: 12))
                Spacer(minLength: 0)
            }
            .foregroundStyle(LibraryPalette.supporting)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!action.isEnabled)
        .opacity(action.isEnabled ? 1 : 0.5)
    }

    @ViewBuilder
    private func compactDestructiveButton(_ action: LibraryDestructiveAction) -> some View {
        Button(action: action.action) {
            Image(systemName: action.icon)
                .font(.system(size: 12))
                .foregroundStyle(LibraryPalette.supporting)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!action.isEnabled)
        .opacity(action.isEnabled ? 1 : 0.5)
        .help(action.title)
        .accessibilityLabel(action.title)
    }

    // MARK: - Content

    @ViewBuilder
    private func content(density: LibraryDensity) -> some View {
        if isLoading {
            LibraryLoadingView(label: loadingLabel)
        } else if allItems.isEmpty {
            LibraryEmptyView(state: isSearching ? noResultsState : emptyState)
        } else {
            list(density: density)
        }
    }

    /// Selection and the keyboard cursor are drawn here rather than handed to
    /// `List(selection:)`.
    ///
    /// AppKit's own list highlight follows the **system** accent
    /// (`selectedContentBackgroundColor`), not Cherry's. A browser the user has
    /// themed pink would highlight its history in the system's blue, which is
    /// exactly the "one accent, the user's own" rule these screens are meant to
    /// keep. Drawing the fill and the focus ring here costs the range and
    /// modifier handling below and buys a selection that is always the right
    /// colour.
    @ViewBuilder
    private func list(density: LibraryDensity) -> some View {
        ScrollViewReader { proxy in
            List {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.items) { item in
                            rowBody(item, density: density)
                        }
                    } header: {
                        sectionHeader(section)
                    }
                }
            }
            .listStyle(.inset)
            .environment(\.defaultMinListRowHeight, density.rowHeight)
            .focusable()
            .focused($isListFocused)
            .onKeyPress(.upArrow) { moveCursor(by: -1, proxy: proxy) }
            .onKeyPress(.downArrow) { moveCursor(by: 1, proxy: proxy) }
            .onKeyPress(.return) {
                let items = selectedItems
                guard !items.isEmpty else { return .ignored }
                onOpen(items)
                return .handled
            }
            .onDeleteCommand {
                let items = selectedItems
                guard !items.isEmpty else { return }
                onRemove(items)
                selection.removeAll()
                cursor = nil
            }
            .onExitCommand {
                // Escape unwinds one step at a time: the search first, because
                // that is what is filtering what you can see, then the
                // selection.
                if isSearching {
                    searchText = ""
                } else {
                    selection.removeAll()
                    cursor = nil
                }
            }
            // Type to search: any letter or digit typed at the list jumps to
            // the search field and starts the query, instead of being
            // swallowed.
            .onKeyPress(phases: .down) { press in
                guard !isSearchFocused,
                      press.modifiers.isDisjoint(with: [.command, .control, .option]),
                      press.characters.count == 1,
                      let scalar = press.characters.unicodeScalars.first,
                      CharacterSet.alphanumerics.contains(scalar)
                else { return .ignored }
                searchText.append(press.characters)
                isSearchFocused = true
                return .handled
            }
        }
    }

    // MARK: - Keyboard cursor

    /// Moves the ↑/↓ cursor, scrolling it into view.
    ///
    /// Shift extends the selection from where it was; without shift the cursor
    /// takes the selection with it, which is what every list on this platform
    /// does. Nothing here animates: an arrow key is held down and repeated, and
    /// an animated selection under a held key is a smear.
    private func moveCursor(by step: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
        let items = allItems
        guard !items.isEmpty else { return .ignored }

        let current = cursor.flatMap { id in items.firstIndex { $0.id == id } }
        let next = min(max((current ?? (step > 0 ? -1 : items.count)) + step, 0), items.count - 1)
        let item = items[next]
        cursor = item.id

        if NSEvent.modifierFlags.contains(.shift) {
            selection.insert(item.id)
        } else {
            selection = [item.id]
        }
        proxy.scrollTo(item.id, anchor: nil)
        return .handled
    }

    /// Applies a click to the selection, honouring ⌘ (toggle one) and
    /// ⇧ (extend a run), the way the rest of the platform does.
    private func selectOnClick(_ item: Item) {
        isListFocused = true
        let modifiers = NSEvent.modifierFlags
        let items = allItems

        if modifiers.contains(.command) {
            if selection.contains(item.id) {
                selection.remove(item.id)
            } else {
                selection.insert(item.id)
            }
        } else if modifiers.contains(.shift),
                  let anchorID = cursor,
                  let anchor = items.firstIndex(where: { $0.id == anchorID }),
                  let target = items.firstIndex(where: { $0.id == item.id }) {
            let range = anchor <= target ? anchor...target : target...anchor
            selection.formUnion(items[range].map(\.id))
        } else {
            selection = [item.id]
        }
        cursor = item.id
    }

    @ViewBuilder
    private func sectionHeader(_ section: LibrarySection<Item>) -> some View {
        HStack(spacing: 6) {
            Text(section.title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.primary)
            Text("\(section.items.count)")
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(LibraryPalette.supporting)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func rowBody(_ item: Item, density: LibraryDensity) -> some View {
        LibraryListRow(
            isSelected: selection.contains(item.id),
            isCursor: cursor == item.id,
            isListFocused: isListFocused,
            isSidebar: presentation == .sidebar,
            select: { selectOnClick(item) },
            open: { onOpen([item]) }
        ) {
            row(item, density)
        }
        .id(item.id)
        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
        .listRowSeparator(.visible)
        .listRowSeparatorTint(LibraryPalette.hairline)
        .cherryContextMenu { rowMenu(item) }
    }

    // MARK: - Selection

    /// The bulk-action bar. "Clear these five" is the task these screens exist
    /// for and there was previously no way to say it.
    ///
    /// It appears and disappears without animation, because it is driven by
    /// selection and a selection can change on every arrow keypress.
    @ViewBuilder
    private var selectionBar: some View {
        if !selection.isEmpty {
            Divider()
            HStack(spacing: 10) {
                Text(selection.count == 1 ? "1 selected" : "\(selection.count) selected")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()

                Spacer(minLength: 8)

                Button("Deselect") { selection.removeAll() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(LibraryPalette.supporting)

                // Only the constructive action takes the accent. "Remove" is
                // ordinary text sitting next to it: reachable, unmistakable,
                // and not the brightest thing in the bar.
                Button("Remove") {
                    onRemove(selectedItems)
                    selection.removeAll()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.primary)

                Button("Open") { onOpen(selectedItems) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(accent.opacity(0.10))
        }
    }
}

/// One row, with its own selection fill, keyboard cursor ring and hover.
///
/// A click means different things in the two presentations, and that is
/// deliberate. In the sidebar a single click opens, as it always has: it is a
/// launcher, 300pt wide, with no selection to protect. On the page a single
/// click selects and a double click opens, which is what makes "select these
/// five and remove them" possible at all, and is the bargain Finder and Mail
/// make for the same reason.
private struct LibraryListRow<Content: View>: View {
    let isSelected: Bool
    /// The ↑/↓ cursor. Distinct from selection: you can move the cursor
    /// through a list while a run stays selected behind it.
    let isCursor: Bool
    let isListFocused: Bool
    let isSidebar: Bool
    let select: () -> Void
    let open: () -> Void
    @ViewBuilder var content: Content

    @State private var isHovering = false
    private var accent: Color { SettingsManager.shared.accentColor }

    var body: some View {
        content
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                LibraryShape.rowShape
                    .fill(fill)
                    .overlay {
                        if isCursor && isListFocused {
                            LibraryShape.rowShape
                                .strokeBorder(accent, lineWidth: 1.5)
                        }
                    }
            }
            .contentShape(Rectangle())
            // No animation on any of this. Hover must keep up with the pointer,
            // and selection changes on every repeat of a held arrow key.
            .onHover { isHovering = $0 }
            .modifier(LibraryRowActivation(isSidebar: isSidebar, select: select, open: open))
    }

    private var fill: Color {
        if isSelected { return accent.opacity(0.18) }
        if isHovering { return Color.primary.opacity(0.05) }
        return .clear
    }
}

private struct LibraryRowActivation: ViewModifier {
    let isSidebar: Bool
    let select: () -> Void
    let open: () -> Void

    func body(content: Content) -> some View {
        if isSidebar {
            content.onTapGesture { open() }
        } else {
            content
                .onTapGesture(count: 2) { open() }
                .onTapGesture(count: 1) { select() }
        }
    }
}
