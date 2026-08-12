//
//  TestOwnedState.swift
//  Internet BrowserTests
//
//  Stores a test owns outright, for the tests that must not read — or leave
//  anything in — the state of the machine they run on.
//
//  The test host IS the real `Cherry.app`: same bundle identifier, same
//  `UserDefaults` domain, same Application Support directory as the copy the
//  owner uses every day. Anything a test reads from those is whatever the
//  owner's machine happens to say, and anything it writes there outlives the
//  run. Both halves have cost rounds:
//
//  * A test that reads live state answers differently on a fresh machine and
//    on the owner's, so `main` is red for exactly the people who use the app.
//  * A test that writes live state and does not put it back leaves the owner
//    with the residue — enabled extensions, a system appearance stuck on
//    Dark, or, in the case this file was written for, 2,104 empty
//    `~/Library/Preferences/<test suite>.plist` files.
//
//  Two things live here: a first-run marker store that exists only in memory,
//  and the missing half of throwing a `UserDefaults` suite away.
//

import AppKit
import Foundation
import XCTest
@testable import Cherry

/// Puts back the two pieces of the owner's state that no individual test can
/// be asked to restore, because it is the APP — running as the test host —
/// that writes them.
///
/// * `cherryBrowserWindowFrame`: every non-private browser window saves its
///   frame as it moves and resizes (`BrowserWindowFrameStore`, from
///   `windowDidResize`). Dozens of tests open browser windows at fabricated
///   frames, so the last one of those wins and the owner's real window comes
///   back at the size of a test fixture. Measured: `{{40, 76}, {1250, 940}}`
///   went to `{{355, 298}, {1000, 700}}` across one run of the suite.
/// * `sessionRestoreTabs` / `sessionRestoreGroups` /
///   `sessionRestoreSelectedIndex`: the app saves the session on tab changes
///   and at termination, and saving a window that holds nothing restorable
///   CLEARS the keys — so a run ends with the owner's "reopen my tabs" set
///   emptied. `SessionRestoreGroupTests` clears them outright as well.
///
/// Installed as the test bundle's principal class
/// (`INFOPLIST_KEY_NSPrincipalClass`), which XCTest creates before the first
/// test runs: the values are read while they are still the owner's, and
/// written back when the bundle is done AND again after the host app's own
/// termination save, whichever comes last.
///
/// Deliberately NOT a blanket "restore the whole domain": tests that change a
/// setting are expected to put it back themselves, and a blanket restore
/// would hide the ones that do not.
@objc(CherryTestBundleStateGuard)
final class CherryTestBundleStateGuard: NSObject, XCTestObservation {

    private static let guardedKeys = [
        "cherryBrowserWindowFrame",
        "sessionRestoreTabs",
        "sessionRestoreGroups",
        "sessionRestoreSelectedIndex",
    ]

    private let entryValues: [String: Any]

    override init() {
        entryValues = Self.guardedKeys.reduce(into: [:]) { snapshot, key in
            snapshot[key] = UserDefaults.standard.object(forKey: key)
        }
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(restore),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }

    func testBundleDidFinish(_ testBundle: Bundle) { restore() }

    @objc private func restore() {
        ThrowawayDefaults.sweep()
        for key in Self.guardedKeys {
            if let value = entryValues[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
}

/// A first-run marker store the test owns outright: empty when it is made,
/// visible to nothing else, and gone when the test's reference to it is.
///
/// This is what "a machine that has never finished the setup wizard" means in
/// a test. `UserDefaults(suiteName:)` cannot say that: a suite is a real
/// preference domain in the owner's home, it is searched next to other
/// domains, and it leaves a file behind when the test is over. An empty
/// dictionary says it exactly, on any machine, in either state.
final class MemoryFirstRunStore: FirstRunMarkerStore {
    private var values: [String: Any] = [:]

    init() {}

    func object(forKey defaultName: String) -> Any? { values[defaultName] }

    func set(_ value: Any?, forKey defaultName: String) {
        if let value {
            values[defaultName] = value
        } else {
            values.removeValue(forKey: defaultName)
        }
    }
}

/// A `UserDefaults` suite that really is thrown away.
///
/// For the tests whose SUBJECT is the defaults store — persistence across a
/// relaunch, the exact keys that reach the disk — an in-memory double would
/// assert nothing, so they need a real suite. What they do not need is the
/// file: `removePersistentDomain(forName:)` empties a suite but does not
/// delete `~/Library/Preferences/<suite>.plist`, and since every suite name
/// carries a fresh `UUID`, every test method of every run left one more empty
/// plist in the owner's Preferences folder — 2,104 of them by the time this
/// was written, from nine test classes. `destroy` removes the contents and
/// then the file.
enum ThrowawayDefaults {

    /// Every suite name this run has handed out, so the file can be swept up
    /// at the end of the bundle even if `cfprefsd` wrote it back after
    /// `destroy` deleted it — which it does, for a few suites per run,
    /// whenever the flush lands after the unlink.
    private static let created = NSMutableArray()
    private static let lock = NSLock()

    /// A suite name that cannot collide with another test, another class, or
    /// another run.
    static func name(_ label: String) -> String {
        let name = "\(label)-\(UUID().uuidString)"
        lock.lock()
        created.add(name)
        lock.unlock()
        return name
    }

    /// Deletes the preference file of every suite this run created, whatever
    /// state it is in. Called once, after the last test.
    static func sweep() {
        lock.lock()
        let names = created.compactMap { $0 as? String }
        lock.unlock()
        for name in names { removeFile(named: name) }
    }

    private static func removeFile(named suiteName: String) {
        let plist = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Preferences")
            .appendingPathComponent("\(suiteName).plist")
        try? FileManager.default.removeItem(at: plist)
    }

    /// A suite under that name, or `nil` in the one case `UserDefaults`
    /// refuses (a name that is the app's own domain) — callers unwrap, so a
    /// refusal fails the test rather than silently using `.standard`.
    static func make(_ suiteName: String) -> UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    /// Empties the suite AND deletes the preference file it created. Safe to
    /// call twice, and safe to call for a suite that was never written to.
    static func destroy(_ defaults: UserDefaults?, named suiteName: String) {
        defaults?.removePersistentDomain(forName: suiteName)
        // Flush first: the contents are removed in `cfprefsd`, and a write
        // still in flight is what puts the file back after it is unlinked.
        defaults?.synchronize()
        defaults?.removeSuite(named: suiteName)
        removeFile(named: suiteName)
    }
}
