//
//  AppSourceTree.swift
//  Internet BrowserTests
//
//  Reading the app's own sources from a test, without parking the suite.
//
//  A few tests make claims about the SOURCE tree rather than about a value —
//  "the user agent is assigned in exactly one place", "the tab strip views are
//  byte-for-byte what main ships". They reach the tree through `#filePath`,
//  which is wherever the checkout happens to live.
//
//  When the checkout lives somewhere macOS protects — `~/Documents`,
//  `~/Desktop`, `~/Downloads`, iCloud Drive — that read is gated. The test
//  host is Cherry.app: a GUI app, ad-hoc signed with no team, so TCC knows it
//  by its cdhash and every fresh build is a client it has never seen. macOS
//  answers the first gated read by putting a Files-and-Folders dialog on
//  screen and holding `open(2)` until somebody clicks it. Under
//  `xcodebuild test` nobody clicks it, so `open(2)` never returns.
//
//  That is not a slow test or a failing one. The test does not finish, the
//  class does not finish, and the whole target sits behind it forever —
//  which is the worst thing a test can do, because it takes the verification
//  gate down with it and reports nothing at all. (Seen directly: every sample
//  of the hung test host in `__open` under `String(contentsOf:)`, and `tccd`
//  in `CFUserNotificationReceiveResponse` at the same moment, waiting for an
//  answer to a dialog nobody could see.)
//
//  So no test reads the source tree directly any more; they come through
//  here. The first read of a run is done on a thread this process is willing
//  to walk away from, with a deadline. If it comes back, the tree is
//  reachable and every later read is a plain synchronous one — the permission
//  is per-app, not per-file, so once it is answered it stays answered. If it
//  does not come back, the tree is marked unreachable, the tests that need it
//  skip with the reason, and the suite finishes.
//

import XCTest

/// The app's source tree, reached from this file rather than from any bundle,
/// for the tests whose claim is about the source itself.
enum AppSourceTree {

    /// `…/Internet Browser/Internet Browser` — the app source root.
    ///
    /// `CHERRY_APP_SOURCE_ROOT` overrides it, which is how these tests are run
    /// against a gated checkout without rebuilding or moving anything: copy
    /// the source directory somewhere unprotected and point this at the copy.
    ///
    /// The test host is launched by `testmanagerd` with a scrubbed
    /// environment, so neither exporting the variable nor passing
    /// `TEST_RUNNER_…` on the command line reaches it (both were tried, both
    /// were ignored). What does reach it is the `.xctestrun`, beside the built
    /// products:
    ///
    ///     rsync -a --delete "…/Internet Browser/Internet Browser/" /private/tmp/cherry-src/
    ///     plutil -insert "Internet BrowserTests.EnvironmentVariables.CHERRY_APP_SOURCE_ROOT" \
    ///         -string /private/tmp/cherry-src "<DerivedData>/Build/Products/<name>.xctestrun"
    ///     xcodebuild test-without-building -xctestrun "<same path>" -destination …
    static let root: URL = {
        if let override = ProcessInfo.processInfo.environment["CHERRY_APP_SOURCE_ROOT"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(fileURLWithPath: #filePath)  // …/Internet BrowserTests/AppSourceTree.swift
            .deletingLastPathComponent()        // …/Internet BrowserTests
            .deletingLastPathComponent()        // …/Internet Browser (project dir)
            .appendingPathComponent("Internet Browser")
    }()

    /// One source file, as text.
    static func read(_ relativePath: String) throws -> String {
        try reachable {
            try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
        }
    }

    /// One source file, as bytes — for the tests that hash it.
    static func bytes(of relativePath: String) throws -> Data {
        try reachable { try Data(contentsOf: root.appendingPathComponent(relativePath)) }
    }

    /// Every `.swift` file under the root, each with its path relative to the
    /// root and its contents.
    static func swiftFiles() throws -> [(path: String, contents: String)] {
        try reachable {
            var files: [(path: String, contents: String)] = []
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                guard url.pathExtension == "swift" else { continue }
                files.append((url.path.replacingOccurrences(of: root.path + "/", with: ""),
                              try String(contentsOf: url, encoding: .utf8)))
            }
            return files
        }
    }

    /// Every file under the root called `name`, as absolute paths — for the
    /// tests whose claim is that a file is *not* there.
    static func paths(named name: String) throws -> [String] {
        try reachable {
            var found: [String] = []
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                if url.lastPathComponent == name { found.append(url.path) }
            }
            return found
        }
    }

    // MARK: - The deadline

    /// How long the first read of a run may sit before the tree is called
    /// unreachable. A reachable tree answers in under a millisecond; an
    /// unreachable one never answers at all, so anything generous will do.
    private static let deadline: TimeInterval = 15

    private static let state = NSLock()
    private static var treeIsReachable: Bool?

    /// Runs `read` against the source tree, and guarantees it either returns
    /// or throws — never that it sits.
    private static func reachable<T>(_ read: @escaping () throws -> T) throws -> T {
        state.lock()
        let known = treeIsReachable
        state.unlock()

        if known == false { throw XCTSkip(unreachableExplanation) }
        if known == true { return try read() }

        // The first read of the run, on a thread we are willing to abandon.
        // If macOS is holding it inside `open(2)` behind a dialog, abandoning
        // it costs one parked thread for the life of the process — which is
        // the whole point, because the alternative is parking the suite.
        let outcome = Outcome<T>()
        let returned = DispatchSemaphore(value: 0)

        let reader = Thread {
            outcome.result = Result { try read() }
            returned.signal()
        }
        reader.name = "app-source-tree-first-read"
        reader.start()

        guard returned.wait(timeout: .now() + deadline) == .success,
              let result = outcome.result else {
            state.lock()
            treeIsReachable = false
            state.unlock()
            throw XCTSkip(unreachableExplanation)
        }

        state.lock()
        treeIsReachable = true
        state.unlock()
        return try result.get()
    }

    private static var unreachableExplanation: String {
        """
        The app source tree at \(root.path) did not answer a read within \
        \(Int(deadline))s, so this test could not be run — it asserts something \
        about the source, and the source could not be opened.

        macOS gates reads of ~/Documents, ~/Desktop, ~/Downloads and iCloud \
        Drive behind a Files-and-Folders permission. The test host is \
        Cherry.app, ad-hoc signed with no team, so TCC identifies it by cdhash \
        and every fresh build is a client it has never seen: the first read \
        puts a dialog on screen and holds open(2) until it is answered. Under \
        `xcodebuild test` there is nobody to answer it.

        To run it without rebuilding or moving the checkout, copy the source \
        directory somewhere unprotected and point CHERRY_APP_SOURCE_ROOT at \
        the copy through the .xctestrun (the test host is launched with a \
        scrubbed environment, so the shell's own exports do not reach it):

            rsync -a --delete "<checkout>/Internet Browser/Internet Browser/" /private/tmp/cherry-src/
            plutil -insert "Internet BrowserTests.EnvironmentVariables.CHERRY_APP_SOURCE_ROOT" \\
                -string /private/tmp/cherry-src "<DerivedData>/Build/Products/<name>.xctestrun"
            xcodebuild test-without-building -xctestrun "<same path>" -destination …

        Or build and test from a checkout outside those folders altogether, or \
        grant this build of Cherry.app access in System Settings › Privacy & \
        Security › Files and Folders.
        """
    }
}

/// What the abandonable reader thread hands back. A class, because the thread
/// and the waiter are different threads; the semaphore orders the two.
private final class Outcome<T> {
    var result: Result<T, any Error>?
}
