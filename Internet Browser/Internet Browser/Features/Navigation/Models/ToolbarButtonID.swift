//
//  ToolbarButtonID.swift
//  Cherry Browser
//
//  The catalogue of navigation-bar buttons the user is allowed to reorder or
//  hide, plus the pure resolver that turns whatever is on disk into a layout
//  the nav bar can render.
//

import Foundation

/// One customisable action button in the navigation bar.
///
/// The raw value is the persisted id. It is written to `UserDefaults` the
/// moment a user reorders or hides anything, so **never rename one** — a
/// renamed case reads back as an unknown id and the button silently returns
/// to its default slot.
///
/// Deliberately covers the action buttons only. Back / Forward /
/// Reload-Stop, the omnibox, the per-extension buttons and the `⋯` menu are
/// structural: nothing here can move or remove them.
///
/// Named `…ButtonID`, not `ToolbarItem`, because that would shadow
/// `SwiftUI.ToolbarItem` for every unqualified use in this target — the first
/// `.toolbar { ToolbarItem { … } }` anyone wrote would fail with a misleading
/// "extra argument 'placement' in call". The type name is free to change; the
/// raw values above are not.
enum ToolbarButtonID: String, CaseIterable, Identifiable, Sendable {
    case askThisPage
    case home
    case bookmark
    case savePDF
    case autoFill
    case adBlock
    case focusMode
    case readerMode
    case privateMode

    var id: String { rawValue }

    /// What Settings calls this button.
    var title: String {
        switch self {
        // Named for the action, not the surface: the panel answers about the
        // page when there is one and chats generally when there isn't, so
        // "Ask This Page" was a promise it broke on the home page.
        case .askThisPage: "Ask Cherry AI"
        case .home: "Home"
        case .bookmark: "Bookmark"
        case .savePDF: "Save PDF"
        case .autoFill: "Auto-fill Password"
        case .adBlock: "Ad Blocker"
        case .focusMode: "Focus Mode"
        case .readerMode: "Reader Mode"
        case .privateMode: "Incognito Mode"
        }
    }

    /// The icon Settings and the overflow menu show for this button. The nav
    /// bar itself keeps drawing its own state-dependent symbol (filled star,
    /// paused shield, …); this is the neutral, resting icon.
    var systemImage: String {
        switch self {
        case .askThisPage: "sparkles"
        case .home: "house"
        case .bookmark: "star"
        case .savePDF: "arrow.down.doc"
        case .autoFill: "key.fill"
        case .adBlock: "shield.checkered"
        case .focusMode: "brain.head.profile"
        case .readerMode: "book"
        case .privateMode: "eye.slash"
        }
    }
}

/// Pure layout maths for the customisable part of the toolbar.
///
/// Lives on the model rather than in `SettingsManager` or the nav bar so the
/// awkward part — surviving whatever an older or newer build left in
/// `UserDefaults` — is testable without a view or a singleton.
enum ToolbarLayout {

    /// `ToolbarButtonID.allCases`, in the order a fresh install draws them. This
    /// is the order the nav bar has always used, so an install that has never
    /// touched Settings looks exactly as it did before customisation existed.
    static var defaultOrder: [ToolbarButtonID] { ToolbarButtonID.allCases }

    /// Nothing is hidden by default.
    static let defaultHidden: Set<ToolbarButtonID> = []

    /// Turns persisted ids into a usable layout.
    ///
    /// Stored data outlives the build that wrote it, so every case here is a
    /// real one rather than defensive decoration:
    ///
    /// - **unknown id** — a button this build no longer has (or a hand-edited
    ///   defaults file): dropped.
    /// - **duplicate id** — collapsed to its first occurrence, so a button
    ///   can never be drawn twice.
    /// - **missing id** — a button added in a LATER build than the one that
    ///   wrote this order, or simply never reordered. It is inserted at its
    ///   default-order position rather than dropped or appended: immediately
    ///   after the last item already in the layout that precedes it in
    ///   `defaultOrder`, or at the very front when none does. With an
    ///   untouched order that reproduces `defaultOrder` exactly; with a
    ///   reordered one the newcomer still lands next to the neighbour it was
    ///   designed to sit beside.
    /// - **empty / absent** — every item is "missing", so the rule above
    ///   rebuilds `defaultOrder`.
    ///
    /// Hidden ids get the same treatment: anything outside the catalogue is
    /// dropped, so a stale id can't hide a button that no longer answers to it.
    static func resolve(
        savedOrder: [String],
        hidden: Set<String>
    ) -> (order: [ToolbarButtonID], hidden: Set<ToolbarButtonID>) {
        var order: [ToolbarButtonID] = []
        var seen: Set<ToolbarButtonID> = []
        for id in savedOrder {
            guard let item = ToolbarButtonID(rawValue: id), seen.insert(item).inserted else { continue }
            order.append(item)
        }

        let defaultIndex = Dictionary(
            uniqueKeysWithValues: defaultOrder.enumerated().map { ($0.element, $0.offset) }
        )

        for item in defaultOrder where !seen.contains(item) {
            let position = defaultIndex[item] ?? 0
            // The slot just past the last item this one outranks by default.
            var insertionIndex = 0
            for (index, existing) in order.enumerated()
            where (defaultIndex[existing] ?? 0) < position {
                insertionIndex = index + 1
            }
            order.insert(item, at: insertionIndex)
        }

        return (order, Set(hidden.compactMap(ToolbarButtonID.init(rawValue:))))
    }

    /// Whether the Ask Cherry AI button exists right now: only whether the
    /// window wired an action to it.
    ///
    /// It used to carry the page-shaped condition `tab.url != nil &&
    /// tab.internalPage == nil && !tab.showHomePage`, which removed the button
    /// from the home page and from every `cherry://` page — the surfaces where
    /// there is nothing on screen to read, and so exactly the ones the panel's
    /// general chat is for. (Note a `cherry://` page still HAS a web view:
    /// `Tab.openInternalPage` keeps the covered site's one alive. Nothing here
    /// or in `BrowserViewModel.toggleAskThisPage` may reason from a web view's
    /// existence to what is on screen.) The panel now opens everywhere, so
    /// those conditions are gone rather than restated.
    static func askThisPageIsAvailable(hasAction: Bool) -> Bool {
        hasAction
    }

    /// The hidden buttons that should appear at the top of the `⋯` menu right
    /// now, in the user's own order.
    ///
    /// Hiding a button is a layout choice, never a loss of function — but a
    /// hidden button whose own availability condition doesn't hold (no PDF
    /// open, no login form detected) has nothing to invoke, so it stays out of
    /// the menu too. `isAvailable` is supplied by the nav bar, which computes
    /// it from the exact same conditions it uses to decide whether to draw the
    /// button, so the two can't drift apart.
    static func overflowItems(
        order: [ToolbarButtonID],
        hidden: Set<ToolbarButtonID>,
        isAvailable: (ToolbarButtonID) -> Bool
    ) -> [ToolbarButtonID] {
        order.filter { hidden.contains($0) && isAvailable($0) }
    }
}
