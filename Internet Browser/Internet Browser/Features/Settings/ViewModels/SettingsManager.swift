//
//  SettingsManager.swift
//  Cherry Browser
//

import SwiftUI
import Observation
import WebKit

enum CookieBlockingLevel: String, CaseIterable, Identifiable {
    case none = "Allow All"
    case thirdParty = "Block Third-Party"
    case all = "Block All"

    var id: String { rawValue }

    /// What the picker shows. Separate from `rawValue`, which is the
    /// persisted key and must not change.
    var displayName: String {
        switch self {
        case .none: "Allow All Cookies"
        case .thirdParty: "Block Third-Party Cookies"
        case .all: "Block All Cookies"
        }
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var id: String { rawValue }
}

enum AIEngine: String, CaseIterable, Identifiable {
    case apple = "Apple"
    case qwen = "Qwen (Local)"

    var id: String { rawValue }
}

struct AccentColorOption: Identifiable {
    let name: String
    let hex: String
    var id: String { hex }
    var color: Color { Color(hex: hex) }

    static let options: [AccentColorOption] = [
        .init(name: "Cherry Red", hex: "DB283C"),
        .init(name: "Ocean Blue", hex: "2563EB"),
        .init(name: "Emerald", hex: "059669"),
        .init(name: "Purple", hex: "7C3AED"),
        .init(name: "Orange", hex: "EA580C"),
        .init(name: "Pink", hex: "DB2777"),
        .init(name: "Teal", hex: "0D9488"),
        .init(name: "Graphite", hex: "6B7280"),
    ]
}

enum HomepageTheme: String, CaseIterable, Identifiable {
    case cherry = "Cherry"
    case ocean = "Ocean"
    case forest = "Forest"
    case sunset = "Sunset"
    case purple = "Purple"
    case midnight = "Midnight"
    case rose = "Rose"
    case slate = "Slate"

    var id: String { rawValue }

    /// Returns 9 MeshGradient colors (3x3 grid) for the homepage background
    var gradientColors: [Color] {
        switch self {
        case .cherry:
            return [
                Color(red: 0.5, green: 0.0, blue: 0.1),
                Color(red: 0.6, green: 0.0, blue: 0.15),
                Color(red: 0.4, green: 0.0, blue: 0.2),
                Color(red: 0.35, green: 0.0, blue: 0.12),
                Color(red: 0.45, green: 0.0, blue: 0.12),
                Color(red: 0.45, green: 0.0, blue: 0.15),
                Color(red: 0.15, green: 0.0, blue: 0.08),
                Color(red: 0.2, green: 0.0, blue: 0.1),
                Color(red: 0.1, green: 0.0, blue: 0.05),
            ]
        case .ocean:
            return [
                Color(red: 0.0, green: 0.05, blue: 0.18),
                Color(red: 0.0, green: 0.06, blue: 0.22),
                Color(red: 0.0, green: 0.04, blue: 0.16),
                Color(red: 0.0, green: 0.06, blue: 0.2),
                Color(red: 0.0, green: 0.08, blue: 0.28),
                Color(red: 0.0, green: 0.07, blue: 0.24),
                Color(red: 0.0, green: 0.03, blue: 0.12),
                Color(red: 0.0, green: 0.05, blue: 0.18),
                Color(red: 0.0, green: 0.02, blue: 0.1),
            ]
        case .forest:
            return [
                Color(red: 0.0, green: 0.12, blue: 0.06),
                Color(red: 0.0, green: 0.14, blue: 0.07),
                Color(red: 0.0, green: 0.1, blue: 0.05),
                Color(red: 0.0, green: 0.1, blue: 0.04),
                Color(red: 0.02, green: 0.16, blue: 0.07),
                Color(red: 0.0, green: 0.12, blue: 0.06),
                Color(red: 0.0, green: 0.06, blue: 0.03),
                Color(red: 0.0, green: 0.08, blue: 0.04),
                Color(red: 0.0, green: 0.04, blue: 0.02),
            ]
        case .sunset:
            return [
                Color(red: 0.6, green: 0.2, blue: 0.0),
                Color(red: 0.7, green: 0.15, blue: 0.0),
                Color(red: 0.5, green: 0.1, blue: 0.1),
                Color(red: 0.55, green: 0.08, blue: 0.15),
                Color(red: 0.65, green: 0.12, blue: 0.05),
                Color(red: 0.5, green: 0.15, blue: 0.1),
                Color(red: 0.25, green: 0.05, blue: 0.1),
                Color(red: 0.3, green: 0.05, blue: 0.15),
                Color(red: 0.2, green: 0.02, blue: 0.08),
            ]
        case .purple:
            return [
                Color(red: 0.3, green: 0.0, blue: 0.5),
                Color(red: 0.35, green: 0.0, blue: 0.55),
                Color(red: 0.25, green: 0.0, blue: 0.45),
                Color(red: 0.2, green: 0.0, blue: 0.4),
                Color(red: 0.35, green: 0.05, blue: 0.55),
                Color(red: 0.28, green: 0.0, blue: 0.48),
                Color(red: 0.1, green: 0.0, blue: 0.2),
                Color(red: 0.15, green: 0.0, blue: 0.25),
                Color(red: 0.08, green: 0.0, blue: 0.15),
            ]
        case .midnight:
            return [
                Color(red: 0.08, green: 0.08, blue: 0.2),
                Color(red: 0.1, green: 0.1, blue: 0.25),
                Color(red: 0.06, green: 0.06, blue: 0.18),
                Color(red: 0.05, green: 0.08, blue: 0.18),
                Color(red: 0.12, green: 0.12, blue: 0.3),
                Color(red: 0.08, green: 0.1, blue: 0.22),
                Color(red: 0.02, green: 0.02, blue: 0.08),
                Color(red: 0.04, green: 0.04, blue: 0.12),
                Color(red: 0.01, green: 0.01, blue: 0.06),
            ]
        case .rose:
            return [
                Color(red: 0.55, green: 0.1, blue: 0.3),
                Color(red: 0.6, green: 0.08, blue: 0.35),
                Color(red: 0.45, green: 0.05, blue: 0.25),
                Color(red: 0.4, green: 0.08, blue: 0.28),
                Color(red: 0.55, green: 0.12, blue: 0.35),
                Color(red: 0.48, green: 0.08, blue: 0.3),
                Color(red: 0.2, green: 0.02, blue: 0.12),
                Color(red: 0.25, green: 0.04, blue: 0.15),
                Color(red: 0.15, green: 0.01, blue: 0.08),
            ]
        case .slate:
            return [
                Color(red: 0.2, green: 0.22, blue: 0.25),
                Color(red: 0.25, green: 0.27, blue: 0.3),
                Color(red: 0.18, green: 0.2, blue: 0.22),
                Color(red: 0.15, green: 0.17, blue: 0.2),
                Color(red: 0.22, green: 0.25, blue: 0.28),
                Color(red: 0.18, green: 0.2, blue: 0.24),
                Color(red: 0.08, green: 0.09, blue: 0.1),
                Color(red: 0.1, green: 0.11, blue: 0.13),
                Color(red: 0.06, green: 0.07, blue: 0.08),
            ]
        }
    }
}

@Observable
final class SettingsManager {
    static let shared = SettingsManager()

    // MARK: - General

    var searchEngine: SearchEngine {
        didSet { UserDefaults.standard.set(searchEngine.rawValue, forKey: Keys.searchEngine) }
    }

    var homepage: String {
        didSet { UserDefaults.standard.set(homepage, forKey: Keys.homepage) }
    }

    /// Which on-device AI backend powers "Ask This Page" and "All Tabs"
    /// research: Apple's Foundation Models (system model) or the local Qwen
    /// engine (MLX). See `PageAIService` for the routing.
    var aiEngine: AIEngine {
        didSet { UserDefaults.standard.set(aiEngine.rawValue, forKey: Keys.aiEngine) }
    }

    var showBookmarkBar: Bool {
        didSet { UserDefaults.standard.set(showBookmarkBar, forKey: Keys.showBookmarkBar) }
    }

    var useVerticalTabs: Bool {
        didSet { UserDefaults.standard.set(useVerticalTabs, forKey: Keys.useVerticalTabs) }
    }

    var verticalTabBarCollapsed: Bool {
        didSet { UserDefaults.standard.set(verticalTabBarCollapsed, forKey: Keys.verticalTabBarCollapsed) }
    }

    // MARK: - Toolbar

    /// The customisable nav-bar buttons, as persisted ids in the user's order.
    /// Raw storage — read `toolbarLayout` instead, which repairs whatever an
    /// older or newer build left here.
    var toolbarItemOrder: [String] {
        didSet { UserDefaults.standard.set(toolbarItemOrder, forKey: Keys.toolbarItemOrder) }
    }

    /// Ids of the buttons the user has hidden from the nav bar. Hidden is a
    /// layout choice only: the nav bar keeps offering these in its `⋯` menu.
    var hiddenToolbarItems: Set<String> {
        didSet { UserDefaults.standard.set(Array(hiddenToolbarItems), forKey: Keys.hiddenToolbarItems) }
    }

    /// What the nav bar and Settings both render from. Computed on every read
    /// rather than cached so it stays a plain function of the two stored
    /// properties above — which is also what makes a change to either of them
    /// invalidate every SwiftUI view that read it.
    var toolbarLayout: (order: [ToolbarButtonID], hidden: Set<ToolbarButtonID>) {
        ToolbarLayout.resolve(savedOrder: toolbarItemOrder, hidden: hiddenToolbarItems)
    }

    func isToolbarItemHidden(_ item: ToolbarButtonID) -> Bool {
        toolbarLayout.hidden.contains(item)
    }

    func setToolbarItem(_ item: ToolbarButtonID, hidden: Bool) {
        // Write back the resolved set, not `hiddenToolbarItems` verbatim, so
        // stale ids get cleaned out the first time the user touches anything.
        var resolved = toolbarLayout.hidden
        if hidden { resolved.insert(item) } else { resolved.remove(item) }
        hiddenToolbarItems = Set(resolved.map(\.rawValue))
    }

    /// Moves `item` one slot towards the start (`offset` -1) or end (+1) of
    /// the toolbar. A move that would fall off either end is a no-op.
    func moveToolbarItem(_ item: ToolbarButtonID, by offset: Int) {
        var order = toolbarLayout.order
        guard let from = order.firstIndex(of: item) else { return }
        let to = from + offset
        guard order.indices.contains(to) else { return }
        order.swapAt(from, to)
        toolbarItemOrder = order.map(\.rawValue)
    }

    /// Back to the stock toolbar: default order, nothing hidden.
    func resetToolbarLayout() {
        toolbarItemOrder = ToolbarLayout.defaultOrder.map(\.rawValue)
        hiddenToolbarItems = []
    }

    /// True while the toolbar still looks exactly like a fresh install's.
    var toolbarIsDefault: Bool {
        let layout = toolbarLayout
        return layout.order == ToolbarLayout.defaultOrder && layout.hidden == ToolbarLayout.defaultHidden
    }

    // MARK: - Theme

    var appearanceMode: AppearanceMode {
        didSet { UserDefaults.standard.set(appearanceMode.rawValue, forKey: Keys.appearanceMode) }
    }

    var accentColorHex: String {
        didSet {
            UserDefaults.standard.set(accentColorHex, forKey: Keys.accentColorHex)
            applyAppIcon()
            // SwiftUI redraws everything `.tint` reaches on its own; the field
            // editor is an AppKit object outside that, so it needs telling.
            onMainActor { AccentTextSelection.refreshOpenWindows() }
        }
    }

    var homepageTheme: HomepageTheme {
        didSet { UserDefaults.standard.set(homepageTheme.rawValue, forKey: Keys.homepageTheme) }
    }

    /// When true (the default), the homepage background is derived live from
    /// the accent color; `homepageTheme` then acts as a manual override kept
    /// for when the user picks a curated theme.
    var homepageMatchesAccent: Bool {
        didSet { UserDefaults.standard.set(homepageMatchesAccent, forKey: Keys.homepageMatchesAccent) }
    }

    /// Whether an imported Firefox theme's `ntp_background` is allowed to take
    /// over the homepage. Set when a theme is imported (so a fresh theme shows
    /// its own new-tab background, as Firefox does) and cleared the moment the
    /// user picks a background swatch in Settings.
    ///
    /// This flag is the way out of the lock-out: the theme background used to
    /// outrank the user's "Auto" choice unconditionally, so once a theme with
    /// `ntp_background` was active the accent wallpaper could never be shown
    /// again short of deleting the theme — while Settings still drew "Auto" as
    /// the selected swatch.
    var homepageUsesThemeBackground: Bool {
        didSet { UserDefaults.standard.set(homepageUsesThemeBackground, forKey: Keys.homepageUsesThemeBackground) }
    }

    var accentColor: Color {
        Color(hex: accentColorHex)
    }

    // MARK: - Homepage appearance
    // Single source of truth for the homepage background: views read these
    // instead of `homepageTheme` directly, so the active source (imported
    // Firefox theme vs. accent wallpaper vs. accent-derived vs. curated theme)
    // stays an implementation detail — and Settings' selection state is
    // derived from the same value the homepage paints.

    /// - Parameter isPrivate: whether the asking window is a private one; see
    ///   `HomepageBackgroundResolver.resolve`.
    func homepageBackgroundSource(isPrivate: Bool) -> HomepageBackgroundSource {
        HomepageBackgroundResolver.resolve(
            matchesAccent: homepageMatchesAccent,
            prefersThemeBackground: homepageUsesThemeBackground,
            themeHasBackground: FirefoxThemeManager.shared.homepageBackground != nil,
            isPrivate: isPrivate,
            accentHex: accentColorHex,
            curatedTheme: homepageTheme
        )
    }

    func homepageGradientColors(isPrivate: Bool) -> [Color] {
        switch homepageBackgroundSource(isPrivate: isPrivate) {
        case .themeBackground:
            // Flat, matching how Firefox renders its new-tab page.
            let themeBackground = FirefoxThemeManager.shared.homepageBackground ?? .clear
            return Array(repeating: themeBackground, count: 9)
        case .accentWallpaper, .accentGradient:
            return AccentDerivedPalette.gradientColors(fromHex: accentColorHex)
        case .curatedTheme(let theme):
            return theme.gradientColors
        }
    }

    /// True while an imported theme's `ntp_background` is what an ordinary
    /// window's homepage shows — not merely that the active theme defines one.
    /// Settings reads this: it configures the app, not one window, so it
    /// deliberately reports the non-private answer even when opened in a
    /// private tab.
    var homepageThemeBackgroundIsActive: Bool {
        homepageBackgroundSource(isPrivate: false) == .themeBackground
    }

    var resolvedColorScheme: ColorScheme? {
        switch appearanceMode {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    // MARK: - Downloads

    var downloadDirectory: String {
        didSet { UserDefaults.standard.set(downloadDirectory, forKey: Keys.downloadDirectory) }
    }

    var downloadDirectoryURL: URL {
        URL(fileURLWithPath: downloadDirectory, isDirectory: true)
    }

    // MARK: - Privacy

    var adBlockEnabled: Bool {
        didSet { UserDefaults.standard.set(adBlockEnabled, forKey: Keys.adBlockEnabled) }
    }

    var adBlockWhitelistedDomains: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(adBlockWhitelistedDomains), forKey: Keys.adBlockWhitelistedDomains)
        }
    }

    /// What the persisted ad-block whitelist becomes on launch.
    ///
    /// Drops entries that are public suffixes: older builds derived the entry
    /// with "last two labels", so a user who paused the blocker on bbc.co.uk
    /// has `co.uk` stored, which silently disables blocking on every .co.uk
    /// site.
    ///
    /// Deliberately uses the strict TABLE (`isKnownPublicSuffix`) — registry
    /// suffixes and bare TLDs only. Not the `<generic>.<ccTLD>` heuristic
    /// (which reads real sites like `web.de` as suffixes) and not the
    /// shared-hosting table (`medium.com`, `wordpress.com` — sites people
    /// actually browse and pause). Deleting an entry the user deliberately
    /// created is worse than keeping a narrow one, and since this result is
    /// written back to disk, a wrong deletion is permanent.
    static func sanitizedWhitelist(_ saved: [String]) -> Set<String> {
        Set(
            saved
                .map(HostNormalizer.normalizedHost)
                .filter { !$0.isEmpty && !HostNormalizer.isKnownPublicSuffix($0) }
        )
    }

    /// One-time cleanup of whitelist data written by a pre-fix build.
    ///
    /// Those builds derived the stored entry with "last two labels", so a
    /// pause on `attacker.github.io` was stored as `github.io` and left
    /// ad-blocking off across every GitHub Pages site. The per-launch purge
    /// deliberately cannot remove that — it uses registry suffixes only,
    /// because running the wide table every launch would keep deleting pauses
    /// users legitimately set on sites that are themselves suffixes.
    ///
    /// So the wide table runs exactly once, keyed on a version flag.
    ///
    /// Known cost, accepted: a user who deliberately paused `medium.com` (a
    /// PSL private-section entry *and* an ordinary site) loses that one pause,
    /// once. Old data cannot be told apart from a deliberate pause — both are
    /// the bare string — and leaving the hole open is worse than one re-click.
    static func migratedWhitelist(_ saved: Set<String>) -> Set<String> {
        saved.filter { !HostNormalizer.isAnyKnownPublicSuffix($0) }
    }

    func isAdBlockPaused(for url: URL?) -> Bool {
        guard let rawHost = url?.host else { return false }
        let host = HostNormalizer.normalizedHost(rawHost)
        guard !host.isEmpty else { return false }
        // A whitelist entry covers itself and its subdomains, on a dot
        // boundary. Never a "last two labels" base domain — for hosts under a
        // multi-label public suffix that base is `co.uk`, which used to switch
        // the blocker off for every UK site at once.
        return adBlockWhitelistedDomains.contains { HostNormalizer.hostMatches(host, rule: $0) }
    }

    func toggleAdBlockPause(for url: URL?) {
        guard let rawHost = url?.host else { return }
        let host = HostNormalizer.normalizedHost(rawHost)
        guard !host.isEmpty else { return }

        let matching = adBlockWhitelistedDomains.filter { HostNormalizer.hostMatches(host, rule: $0) }
        if !matching.isEmpty {
            // Un-pausing drops every entry that covers this host, including a
            // too-broad one left behind by an older build.
            adBlockWhitelistedDomains.subtract(matching)
        } else {
            let base = HostNormalizer.baseDomain(host)
            adBlockWhitelistedDomains.insert(HostNormalizer.isRegistrable(base) ? base : host)
        }
    }

    var blockCookies: CookieBlockingLevel {
        didSet {
            UserDefaults.standard.set(blockCookies.rawValue, forKey: Keys.blockCookies)
            applyCookiePolicy()
        }
    }

    var httpsOnlyMode: Bool {
        didSet { UserDefaults.standard.set(httpsOnlyMode, forKey: Keys.httpsOnlyMode) }
    }

    /// Exposes `navigator.globalPrivacyControl` (and a truthful
    /// `navigator.doNotTrack`) to every page. Replaces a "Send Do Not Track
    /// Header" switch that nothing read — see `PrivacySignalScripts`.
    var sendGlobalPrivacyControl: Bool {
        didSet { UserDefaults.standard.set(sendGlobalPrivacyControl, forKey: Keys.sendGlobalPrivacyControl) }
    }

    var enableJavaScript: Bool {
        didSet { UserDefaults.standard.set(enableJavaScript, forKey: Keys.enableJavaScript) }
    }

    var blockPopups: Bool {
        didSet { UserDefaults.standard.set(blockPopups, forKey: Keys.blockPopups) }
    }

    // MARK: - Passwords

    let requireTouchIDForAutoFill: Bool = true
    let requireTouchIDForViewing: Bool = true

    var passwordGeneratorLength: Int {
        didSet { UserDefaults.standard.set(passwordGeneratorLength, forKey: Keys.passwordGeneratorLength) }
    }

    var passwordGeneratorIncludeSymbols: Bool {
        didSet { UserDefaults.standard.set(passwordGeneratorIncludeSymbols, forKey: Keys.passwordGeneratorIncludeSymbols) }
    }

    // MARK: - Tabs

    var tabSleepEnabled: Bool {
        didSet { UserDefaults.standard.set(tabSleepEnabled, forKey: Keys.tabSleepEnabled) }
    }

    var tabSleepTimeout: Int {
        didSet { UserDefaults.standard.set(tabSleepTimeout, forKey: Keys.tabSleepTimeout) }
    }

    var restorePreviousSession: Bool {
        didSet { UserDefaults.standard.set(restorePreviousSession, forKey: Keys.restorePreviousSession) }
    }

    // MARK: - Init

    private init() {
        let defaults = UserDefaults.standard

        // General
        if let engineRaw = defaults.string(forKey: Keys.searchEngine),
           let engine = SearchEngine(rawValue: engineRaw) {
            self.searchEngine = engine
        } else {
            self.searchEngine = .google
        }

        self.homepage = defaults.string(forKey: Keys.homepage) ?? AppConstants.defaultHomePage

        if let engineRaw = defaults.string(forKey: Keys.aiEngine),
           let engine = AIEngine(rawValue: engineRaw) {
            self.aiEngine = engine
        } else {
            self.aiEngine = .apple
        }
        self.showBookmarkBar = defaults.object(forKey: Keys.showBookmarkBar) as? Bool ?? true
        self.useVerticalTabs = defaults.bool(forKey: Keys.useVerticalTabs)
        self.verticalTabBarCollapsed = defaults.bool(forKey: Keys.verticalTabBarCollapsed)

        // Toolbar. Stored raw and left exactly as found — absent keys mean an
        // install that has never customised anything, and `ToolbarLayout`
        // turns both that and any stale contents into a real layout on read.
        self.toolbarItemOrder = defaults.stringArray(forKey: Keys.toolbarItemOrder) ?? []
        self.hiddenToolbarItems = Set(defaults.stringArray(forKey: Keys.hiddenToolbarItems) ?? [])

        // Theme
        if let modeRaw = defaults.string(forKey: Keys.appearanceMode),
           let mode = AppearanceMode(rawValue: modeRaw) {
            self.appearanceMode = mode
        } else {
            self.appearanceMode = .system
        }
        self.accentColorHex = defaults.string(forKey: Keys.accentColorHex) ?? "DB283C"

        if let themeRaw = defaults.string(forKey: Keys.homepageTheme),
           let theme = HomepageTheme(rawValue: themeRaw) {
            self.homepageTheme = theme
        } else {
            self.homepageTheme = .cherry
        }
        self.homepageMatchesAccent = defaults.object(forKey: Keys.homepageMatchesAccent) as? Bool ?? true
        // Defaults to true so an already-imported theme keeps the homepage
        // background it has been painting across the upgrade.
        self.homepageUsesThemeBackground = defaults.object(forKey: Keys.homepageUsesThemeBackground) as? Bool ?? true

        // Downloads
        let defaultDownloadsPath = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!.path
        self.downloadDirectory = defaults.string(forKey: Keys.downloadDirectory) ?? defaultDownloadsPath

        // Privacy
        self.adBlockEnabled = defaults.object(forKey: Keys.adBlockEnabled) as? Bool ?? true
        let savedDomains = defaults.stringArray(forKey: Keys.adBlockWhitelistedDomains) ?? []
        var cleaned = Self.sanitizedWhitelist(savedDomains)
        // One-time, wide-table cleanup of pre-fix data (see migratedWhitelist).
        if !defaults.bool(forKey: Keys.adBlockWhitelistMigratedV2) {
            cleaned = Self.migratedWhitelist(cleaned)
            defaults.set(true, forKey: Keys.adBlockWhitelistMigratedV2)
        }
        self.adBlockWhitelistedDomains = cleaned
        // `didSet` does not fire during `init`, so write the repaired set back
        // by hand — otherwise the stale entry is re-read on every launch and
        // the "purge" only ever lasts for one session.
        if cleaned != Set(savedDomains) {
            defaults.set(Array(cleaned), forKey: Keys.adBlockWhitelistedDomains)
        }

        if let cookieRaw = defaults.string(forKey: Keys.blockCookies),
           let level = CookieBlockingLevel(rawValue: cookieRaw) {
            self.blockCookies = level
        } else {
            self.blockCookies = .none
        }

        self.httpsOnlyMode = defaults.bool(forKey: Keys.httpsOnlyMode)
        // Carry over whatever the user chose for the old (inert) Do Not Track
        // switch rather than silently turning the replacement signal off.
        self.sendGlobalPrivacyControl = defaults.object(forKey: Keys.sendGlobalPrivacyControl) as? Bool
            ?? defaults.bool(forKey: Keys.legacySendDoNotTrack)
        self.enableJavaScript = defaults.object(forKey: Keys.enableJavaScript) as? Bool ?? true
        self.blockPopups = defaults.object(forKey: Keys.blockPopups) as? Bool ?? true

        // Passwords
        // requireTouchIDForAutoFill and requireTouchIDForViewing are always true
        self.passwordGeneratorLength = defaults.object(forKey: Keys.passwordGeneratorLength) as? Int ?? 20
        self.passwordGeneratorIncludeSymbols = defaults.object(forKey: Keys.passwordGeneratorIncludeSymbols) as? Bool ?? true

        // Tabs
        self.tabSleepEnabled = defaults.object(forKey: Keys.tabSleepEnabled) as? Bool ?? true
        self.tabSleepTimeout = defaults.object(forKey: Keys.tabSleepTimeout) as? Int ?? 30
        self.restorePreviousSession = defaults.object(forKey: Keys.restorePreviousSession) as? Bool ?? true

        // Re-apply the persisted cookie policy at launch. It used to run only
        // from `blockCookies.didSet`, so a policy chosen in an earlier session
        // was never in force again until the user re-picked it.
        applyCookiePolicy()
        // Same reason, for the Dock icon: `didSet` doesn't fire during `init`,
        // so without this the icon would only follow the accent from the first
        // time the user re-picked it in a session.
        applyAppIcon()
    }

    // MARK: - App Icon

    /// Points the running app's Dock/⌘-Tab icon at the artwork for the current
    /// accent. Called from `accentColorHex.didSet` and once from `init`, so
    /// this is the only place the icon is ever set. Falls back to the bundled
    /// icon when the accent has no artwork — see `AccentAppIcon`.
    func applyAppIcon() {
        let hex = accentColorHex
        onMainActor { AccentAppIcon.apply(accentHex: hex) }
    }

    /// Runs AppKit work synchronously when we're already on the main actor —
    /// which is every real call site — mirroring `applyCookiePolicy`'s reason
    /// for not always hopping through a `Task`.
    private func onMainActor(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(work)
        } else {
            Task { @MainActor in work() }
        }
    }

    // MARK: - Cookie Policy

    func applyCookiePolicy() {
        // The part that actually reaches page loads: a WKContentRuleList with
        // a block-cookies action. `HTTPCookieStorage` below is NOT that — it
        // governs the app's own URLSession traffic (favicon fetches, filter
        // list downloads, search suggestions) and is ignored by WKWebView.
        let level = blockCookies
        // Synchronously when we're already on the main actor — which is every
        // real call site. Hopping through a Task left a window in which a web
        // view could be built between the setting changing and the policy
        // being told about it, and that web view would carry the old list.
        if Thread.isMainThread {
            MainActor.assumeIsolated { CookiePolicyManager.shared.updatePolicy(level) }
        } else {
            Task { @MainActor in CookiePolicyManager.shared.updatePolicy(level) }
        }

        let policy: HTTPCookie.AcceptPolicy
        switch level {
        case .none: policy = .always
        case .thirdParty: policy = .onlyFromMainDocumentDomain
        case .all: policy = .never
        }
        HTTPCookieStorage.shared.cookieAcceptPolicy = policy
    }

    // MARK: - Clear Data

    func clearBrowsingData(history: Bool, cookies: Bool, cache: Bool, since: Date?) async {
        if history {
            await MainActor.run {
                if let date = since {
                    HistoryRepository.shared.clearHistory(since: date)
                } else {
                    HistoryRepository.shared.clearAllHistory()
                }
            }
        }

        // Split every type WebKit knows about between the two switches, rather
        // than naming a handful by hand. The old list left behind exactly the
        // stores that survive longest and identify a user best: IndexedDB,
        // Service Worker registrations, WebSQL and the fetch cache.
        let allTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        let cacheTypes: Set<String> = allTypes.intersection([
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeOfflineWebApplicationCache,
            WKWebsiteDataTypeFetchCache,
        ])

        var dataTypes: Set<String> = []
        if cookies {
            // Everything that isn't a cache is site data: cookies, local and
            // session storage, IndexedDB, WebSQL, service workers, and any
            // type a future WebKit adds.
            dataTypes.formUnion(allTypes.subtracting(cacheTypes))
        }
        if cache {
            dataTypes.formUnion(cacheTypes)
        }

        if !dataTypes.isEmpty {
            let date = since ?? Date.distantPast
            await WKWebsiteDataStore.default().removeData(
                ofTypes: dataTypes,
                modifiedSince: date
            )
        }
    }

    // MARK: - Keys

    private enum Keys {
        static let searchEngine = "searchEngine"
        static let homepage = "homepage"
        static let aiEngine = "aiEngine"
        static let showBookmarkBar = "showBookmarkBar"
        static let useVerticalTabs = "useVerticalTabs"
        static let verticalTabBarCollapsed = "verticalTabBarCollapsed"
        static let toolbarItemOrder = "toolbarItemOrder"
        static let hiddenToolbarItems = "hiddenToolbarItems"
        static let blockCookies = "blockCookies"
        static let httpsOnlyMode = "httpsOnlyMode"
        static let sendGlobalPrivacyControl = "sendGlobalPrivacyControl"
        /// The old, never-implemented Do Not Track switch; read once to seed
        /// `sendGlobalPrivacyControl`.
        static let legacySendDoNotTrack = "sendDoNotTrack"
        static let enableJavaScript = "enableJavaScript"
        static let blockPopups = "blockPopups"
        static let tabSleepEnabled = "tabSleepEnabled"
        static let tabSleepTimeout = "tabSleepTimeout"
        static let appearanceMode = "appearanceMode"
        static let accentColorHex = "accentColorHex"
        static let homepageTheme = "homepageTheme"
        static let homepageMatchesAccent = "homepageMatchesAccent"
        static let homepageUsesThemeBackground = "homepageUsesThemeBackground"
        static let downloadDirectory = "downloadDirectory"
        static let adBlockEnabled = "adBlockEnabled"
        static let adBlockWhitelistedDomains = "adBlockWhitelistedDomains"
        /// Marks the one-time cleanup of whitelist entries written by builds
        /// whose base-domain derivation produced public suffixes.
        static let adBlockWhitelistMigratedV2 = "adBlockWhitelistMigratedToRegistrableHosts_v2"
        static let requireTouchIDForAutoFill = "requireTouchIDForAutoFill"
        static let requireTouchIDForViewing = "requireTouchIDForViewing"
        static let passwordGeneratorLength = "passwordGeneratorLength"
        static let passwordGeneratorIncludeSymbols = "passwordGeneratorIncludeSymbols"
        static let restorePreviousSession = "restorePreviousSession"
    }
}
