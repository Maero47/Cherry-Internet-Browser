//
//  LibraryChrome.swift
//  Cherry Browser
//
//  The pieces History, Bookmarks and Downloads share: the scope rail, the
//  search field, the row grammar, the empty states.
//
//  These three screens are one screen with different rows. They used to prove
//  it by sharing a *shape* and nothing else — same icon, same title, same
//  subtitle, same single trailing control, whatever the row was about. This
//  file makes them share a *language* instead: the same column rhythm, the
//  same tones, the same scope rail, the same way of saying "this one is
//  bigger / older / more visited than that one". What differs between the
//  screens is what goes in the columns, which is the only thing that should.
//

import SwiftUI

// MARK: - Model

/// One entry in the scope rail: a saved cut through the list.
///
/// The rail is what the empty half of the window is for. It is also the answer
/// to "a way to move between groups without scrolling through everything" —
/// picking a scope narrows the list instead of scrolling to it.
struct LibraryScope: Identifiable, Hashable {
    let id: String
    let title: String
    let icon: String
    /// Shown beside the title. A scope with nothing in it still appears, so
    /// the rail's shape does not jump around as the data changes.
    let count: Int
}

/// A run of rows under one heading.
struct LibrarySection<Item: Identifiable & Hashable>: Identifiable {
    let id: String
    let title: String
    let items: [Item]
}

/// What to draw when there is nothing to draw. Every screen supplies two: one
/// for "you have none of these yet" and one for "your search matched nothing",
/// because they are different situations and telling the user the wrong one is
/// how a screen makes itself look broken.
struct LibraryEmptyState {
    let icon: String
    let headline: String
    let detail: String

    /// True for "you have none of these YET", false for "your search matched
    /// nothing". The two states already carried different words; this is the
    /// same distinction made available to the view, which spends it on Pearl.
    ///
    /// She sleeps on the untouched screens because nothing has happened on
    /// them yet and that is a warm fact, not a failure. She is deliberately
    /// absent from the no-results state: there the user is looking for
    /// something specific and has just been told it isn't here, and a curled
    /// up cat in the middle of that is the mascot being cute at somebody
    /// who is trying to work.
    var isUntouched: Bool = false
}

/// How much room a row has to work with.
///
/// Columns are shed from the least useful end as the window narrows, rather
/// than every column staying and squeezing the title until it truncates after
/// two words. The title is the thing a row is recognised by; it is the last
/// thing to give up space, not the first.
///
///   - `.full`     everything a row knows, in aligned columns
///   - `.regular`  the title, the domain and the two facts that matter most.
///                 The dropped columns are the ones a section heading already
///                 states (a bookmark's folder) or that the name itself says
///                 (a download's file type).
///   - `.compact`  the 300pt sidebar: two lines, title over domain
enum LibraryDensity {
    case full
    case regular
    case compact

    var rowHeight: CGFloat { self == .compact ? 40 : 30 }
    var iconSize: CGFloat { 16 }

    /// One line per row, with columns, as opposed to the two-line sidebar row.
    var isColumnar: Bool { self != .compact }

    /// Whether there is room for the columns that are nice rather than
    /// necessary.
    var showsSecondaryColumns: Bool { self == .full }

    /// How a list spends the width it is left with after the rail.
    ///
    /// The breakpoints come from the columns, not from a round number: below
    /// roughly 620pt the fixed meta columns leave the title under 200pt, which
    /// truncates a real page title after two words, so the row folds to two
    /// lines instead. Between there and 900pt the secondary columns go and the
    /// title gets their width back.
    static func forListWidth(_ width: CGFloat) -> LibraryDensity {
        if width < 620 { return .compact }
        if width < 900 { return .regular }
        return .full
    }
}

// MARK: - Row grammar

/// The one row shape all three screens draw.
///
/// A row is recognised, not read: an icon you know by its colour, a title, and
/// then columns that always sit in the same place so the eye can run down one
/// of them. `isEmphasised` is how a row earns weight — a large download, a page
/// visited forty times — so that scanning finds the notable ones first.
struct LibraryRow<Icon: View, Meta: View, Accessory: View>: View {
    let title: String
    /// The domain, or a source and a destination. Its own column in `.full`,
    /// a second line in `.compact`.
    let subtitle: String
    let density: LibraryDensity
    var isEmphasised: Bool = false
    /// Overrides the title tone. Used by a failed download and nothing else.
    var titleTone: Color? = nil
    /// Width of the subtitle column in `.full`. Ignored when compact.
    var subtitleWidth: CGFloat = 186
    /// Downloads draw a real Finder file icon, which carries more detail than
    /// a favicon and earns a few more points to draw it in.
    var iconWidth: CGFloat? = nil
    @ViewBuilder var icon: Icon
    @ViewBuilder var meta: Meta
    /// Drawn under the row, full width. The in-progress bar and the failure
    /// reason live here.
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if density.isColumnar {
                HStack(spacing: 10) {
                    icon.frame(
                        width: iconWidth ?? density.iconSize,
                        height: iconWidth ?? density.iconSize
                    )

                    Text(title)
                        .font(.system(size: 12.5, weight: isEmphasised ? .semibold : .regular))
                        .foregroundStyle(titleTone ?? .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(LibraryPalette.supporting)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(width: subtitleWidth, alignment: .leading)

                    meta
                }
            } else {
                HStack(spacing: 8) {
                    icon.frame(
                        width: iconWidth ?? density.iconSize,
                        height: iconWidth ?? density.iconSize
                    )

                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.system(size: 12, weight: isEmphasised ? .semibold : .regular))
                            .foregroundStyle(titleTone ?? .primary)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.system(size: 10.5))
                            .foregroundStyle(LibraryPalette.supporting)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    meta
                }
            }

            accessory
        }
        .frame(minHeight: density.rowHeight)
        .contentShape(Rectangle())
    }
}

/// A right-aligned column of one fact. Fixed width, because a column you can
/// run your eye down is worth more than a column that fits its content.
struct LibraryMeta: View {
    let text: String
    let width: CGFloat
    var tone: Color? = nil
    var weight: Font.Weight = .regular
    /// Sizes, counts and clock times line up digit-for-digit or they are not a
    /// column at all.
    var tabular: Bool = true
    var alignment: Alignment = .trailing

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: weight))
            .monospacedDigit()
            .foregroundStyle(tone ?? LibraryPalette.supporting)
            .lineLimit(1)
            .frame(width: width, alignment: alignment)
    }
}

/// A small label that carries a fact a column cannot: a folder name, a visit
/// count, "in the bookmark bar". Tinted with the user's accent only when it
/// means state.
struct LibraryPill: View {
    let text: String
    var icon: String? = nil
    var isAccent: Bool = false

    private var accent: Color { SettingsManager.shared.accentColor }

    var body: some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 8.5, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(isAccent ? accent : LibraryPalette.supporting)
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(
            LibraryShape.rowShape
                .fill(isAccent ? accent.opacity(0.14) : Color.primary.opacity(0.06))
        )
    }
}

// MARK: - Scope rail

/// The rail beside the list, and the reason the window is no longer half
/// empty. Deliberately the same idiom as the Settings sidebar — same width
/// band, same fill, same 7pt selected shape, same accent tint — so Cherry's
/// two full-page surfaces read as one app.
struct LibraryScopeRail: View {
    let title: String
    let scopes: [LibraryScope]
    @Binding var selection: String
    /// Sits at the foot of the rail. The destructive action is reachable and
    /// honest, and it is nowhere near the top of the reading order.
    var footer: AnyView?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 20, weight: .bold))
                .padding(.horizontal, 20)
                .padding(.top, 22)
                .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(scopes) { scope in
                        LibraryScopeItem(
                            scope: scope,
                            isSelected: selection == scope.id,
                            action: { selection = scope.id }
                        )
                    }
                }
                .padding(.bottom, 8)
            }
            .scrollIndicators(.automatic)

            if let footer {
                Divider().padding(.horizontal, 14)
                footer
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(LibraryPalette.railSurface(colorScheme))
    }
}

private struct LibraryScopeItem: View {
    let scope: LibraryScope
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false
    private var accent: Color { SettingsManager.shared.accentColor }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: scope.icon)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? accent : LibraryPalette.supporting)
                    .frame(width: 18)

                Text(scope.title)
                    .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? .primary : LibraryPalette.supporting)
                    .lineLimit(1)

                Spacer(minLength: 6)

                Text("\(scope.count)")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(LibraryPalette.supporting)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                LibraryShape.rowShape
                    .fill(isSelected
                          ? accent.opacity(0.14)
                          : (isHovering ? Color.primary.opacity(0.05) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        // Hover is instant on purpose. These screens are scanned, and a row
        // that fades in under the pointer lags the eye.
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(scope.title), \(scope.count) items")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The rail folded into one line, for a window too narrow to give it a column.
struct LibraryScopeStrip: View {
    let scopes: [LibraryScope]
    @Binding var selection: String

    private var accent: Color { SettingsManager.shared.accentColor }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(scopes) { scope in
                    let isSelected = selection == scope.id
                    Button { selection = scope.id } label: {
                        HStack(spacing: 4) {
                            Text(scope.title)
                                .font(.system(size: 11.5, weight: isSelected ? .medium : .regular))
                            Text("\(scope.count)")
                                .font(.system(size: 10.5))
                                .monospacedDigit()
                                .opacity(0.75)
                        }
                        .foregroundStyle(isSelected ? .primary : LibraryPalette.supporting)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            LibraryShape.rowShape
                                .fill(isSelected ? accent.opacity(0.14) : Color.primary.opacity(0.05))
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 14)
        }
    }
}

// MARK: - Search

/// A search field that looks like a field.
///
/// The old one was a magnifier and a placeholder floating on the panel with no
/// edge, which is why it read as a caption rather than as somewhere to type.
/// This has a surface, a border, a focus ring in the user's accent, and it says
/// which key gets you here.
struct LibrarySearchField: View {
    let prompt: String
    @Binding var text: String
    var showsShortcutHint: Bool = true
    @FocusState.Binding var isFocused: Bool

    private var accent: Color { SettingsManager.shared.accentColor }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(LibraryPalette.supporting)

            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($isFocused)

            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(LibraryPalette.supporting)
                }
                .buttonStyle(.plain)
                .help("Clear the search")
                .accessibilityLabel("Clear the search")
            } else if showsShortcutHint {
                Text("⌘F")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(LibraryPalette.supporting)
                    .opacity(isFocused ? 0 : 1)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: AppConstants.ToolbarSurface.height)
        .background(LibraryShape.fieldShape.fill(Color(nsColor: .textBackgroundColor)))
        .overlay(
            LibraryShape.fieldShape
                .strokeBorder(isFocused ? accent : Color.primary.opacity(0.12),
                              lineWidth: isFocused ? 2 : 1)
        )
    }
}

// MARK: - Empty

/// Nothing here, and a sentence saying what would put something here.
///
/// A full-page History, Bookmarks or Downloads screen with nothing in it is
/// the coldest surface in Cherry: a whole window, a 28pt outline glyph and two
/// grey sentences. On the three screens where "nothing" means "you haven't
/// started yet", Pearl sleeps there instead of the glyph. It costs nothing —
/// she replaces something rather than being added beside it — and it turns an
/// empty window into a quiet one.
///
/// She does NOT replace the glyph on a search that matched nothing; see
/// `LibraryEmptyState.isUntouched`.
struct LibraryEmptyView: View {
    let state: LibraryEmptyState

    var body: some View {
        VStack(spacing: state.isUntouched ? 12 : 7) {
            if state.isUntouched {
                // Hidden from VoiceOver: the two sentences under her already
                // say what this screen is and what would put something on it,
                // and this whole stack is combined into one element. She is
                // the warmth, not the message.
                PearlPortrait(
                    pose: .curled,
                    height: PearlMascot.restingHeight,
                    label: "Pearl, asleep"
                )
                .accessibilityHidden(true)
            } else {
                Image(systemName: state.icon)
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(LibraryPalette.supporting)
            }
            Text(state.headline)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
            Text(state.detail)
                .font(.system(size: 12))
                .foregroundStyle(LibraryPalette.supporting)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 330)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// A download in flight, drawn in the user's accent.
///
/// Hand-drawn rather than `ProgressView(.linear)` because the system bar keeps
/// the system control accent whatever it is tinted with, which meant a browser
/// themed in one colour showed its downloads progressing in another.
struct LibraryProgressBar: View {
    /// Clamped by the initialiser, so a server that reports more bytes than it
    /// promised cannot draw a bar past its own end.
    let fraction: Double

    private var accent: Color { SettingsManager.shared.accentColor }

    init(downloaded: Int64, total: Int64) {
        fraction = total > 0 ? min(max(Double(downloaded) / Double(total), 0), 1) : 0
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(accent).frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

/// The list is still being read off disk. Distinct from "you have none",
/// which is the state the old screens showed while loading.
struct LibraryLoadingView: View {
    let label: String

    var body: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(LibraryPalette.supporting)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
