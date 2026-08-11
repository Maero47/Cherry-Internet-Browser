//
//  PearlHighScoreStore.swift
//  Cherry Browser
//
//  One integer that must survive relaunch and must not be able to crash the
//  browser. `UserDefaults` is world-writable by anything with the app's
//  sandbox, migration tools mangle plists, and `defaults write` takes
//  strings; so the load path treats the stored value as untrusted input:
//  wrong type reads as 0, a negative reads as 0, and an absurd value is
//  clamped rather than believed. The worst corruption can do is cost a high
//  score.
//

import Foundation

nonisolated struct PearlHighScoreStore {

    static let key = "pearlRunnerHighScore"
    /// Far beyond any survivable run (13pt/frame tops out near 20 points a
    /// second; a million is over 13 hours of perfect play). Anything bigger
    /// is corruption, not achievement.
    static let ceiling = 1_000_000

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The saved high score, or 0 when there isn't one or it cannot be
    /// trusted. Never throws, never crashes: `as? Int` rejects strings,
    /// dictionaries, and doubles with no exact integer value.
    func load() -> Int {
        guard let stored = defaults.object(forKey: Self.key) as? Int, stored > 0 else {
            return 0
        }
        return min(stored, Self.ceiling)
    }

    /// Saves clamped to the same bounds `load` enforces, so a bad value can
    /// not round-trip into existence.
    func save(_ score: Int) {
        defaults.set(min(max(score, 0), Self.ceiling), forKey: Self.key)
    }
}
