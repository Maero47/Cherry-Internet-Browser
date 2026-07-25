//
//  HomepagePreference.swift
//  Cherry Browser
//

import Foundation
import Observation

/// What the Home button and `BrowserViewModel.goHome(for:)` navigate to.
///
/// Cherry's default home is its own new-tab page, so this is opt-in: turning
/// `useCustomHomepage` on switches Home to `SettingsManager.homepage` (the
/// property that shipped with a default of `AppConstants.defaultHomePage` and,
/// until now, no readers and no UI). Existing users see no change until they
/// set a homepage themselves.
@Observable
final class HomepagePreference {
    static let shared = HomepagePreference()

    private enum Keys {
        static let useCustomHomepage = "useCustomHomepage"
    }

    /// Whether Home goes to `homepage` instead of Cherry's new-tab page.
    var useCustomHomepage: Bool {
        didSet { UserDefaults.standard.set(useCustomHomepage, forKey: Keys.useCustomHomepage) }
    }

    /// The custom homepage as typed by the user. Stored in
    /// `SettingsManager.homepage` so there's still one persisted homepage
    /// value, not a second competing one.
    var homepage: String {
        get { SettingsManager.shared.homepage }
        set { SettingsManager.shared.homepage = newValue }
    }

    private init() {
        useCustomHomepage = UserDefaults.standard.bool(forKey: Keys.useCustomHomepage)
    }

    /// The URL Home should load, or `nil` for "show Cherry's new-tab page" —
    /// which is also what an enabled-but-unusable homepage falls back to, so a
    /// half-typed address can never leave Home broken.
    var homepageURL: URL? {
        guard useCustomHomepage else { return nil }
        return Self.resolve(homepage)
    }

    /// Turns typed text into a loadable http(s) URL, or `nil` if it can't be
    /// one. Bare hosts get `https://`; `cherry://` pages are rejected because
    /// Home is already Cherry's new-tab page.
    static func resolve(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate: String
        if trimmed.contains("://") {
            candidate = trimmed
        } else {
            candidate = "https://\(trimmed)"
        }

        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}
