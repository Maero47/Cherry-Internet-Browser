//
//  TabStripUntouchedTests.swift
//  Internet BrowserTests
//
//  This branch ports the omnibox ranking and the reader-mode base URL out of
//  a commit that ALSO rewrote the tab strip. The tab strip part was rejected —
//  nothing in it, in either axis, may move here. These tests pin that:
//
//   * `TabStripMetrics.swift` — the rejected width model — must not exist,
//     anywhere under the app source tree.
//   * The three tab strip views the rejected work edited must be byte-for-byte
//     what `main` (d3d68e6) ships.
//
//  The pins are content hashes, so they hold whichever way the tab strip code
//  might be touched — an import, a constant, a whitespace change. Once this
//  branch is merged and the tab strip legitimately moves again, delete this
//  file with it; it pins THIS branch, not the future.
//

import CryptoKit
import XCTest

final class TabStripUntouchedTests: XCTestCase {

    /// `…/Internet Browser/Internet Browser` — the app source root, reached
    /// from this file's own location rather than from any bundle, because the
    /// claim is about the SOURCE tree.
    private var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)              // …/Internet BrowserTests/TabStripUntouchedTests.swift
            .deletingLastPathComponent()             // …/Internet BrowserTests
            .deletingLastPathComponent()             // …/Internet Browser (project dir)
            .appendingPathComponent("Internet Browser")
    }

    func testTheRejectedWidthModelDoesNotExist() throws {
        let enumerator = FileManager.default.enumerator(
            at: sourceRoot, includingPropertiesForKeys: nil
        )
        var found: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == "TabStripMetrics.swift" {
                found.append(url.path)
            }
        }
        XCTAssertEqual(found, [], "TabStripMetrics was rejected and must not be in this branch")
    }

    func testTabStripViewsAreByteForByteWhatMainShips() throws {
        // shasum -a 256 of each file at d3d68e6 (main) — except TabItemView,
        // which carries EXACTLY ONE departure from main: the resize-jank fix
        // gave `themeLegibilityPlate` a required `cluster:` identity and the
        // tab's call site names itself (`cluster: "tabStrip"`, one added
        // line). Its pin is the hash of main + that line, so anything ELSE
        // moving in the file — the rejected width model above all — still
        // fails here.
        let pins: [(path: String, sha256: String)] = [
            ("Features/Tabs/Views/TabBarView.swift",
             "4d014ff0bea66595c09bb85c0ecc4e46fdfb7170b7254c494a7d91b14fadadae"),
            ("Features/Tabs/Views/TabItemView.swift",
             "0fcbd0d307d30ae5b2841402d25d12b03daaa56596ae5552d58675210d926f17"),
            ("Features/Tabs/Views/VerticalTabBarView.swift",
             "b7be556ddc99c230b32b9a168d48e5ca87ec36c0230680daa4a24547a9d20816"),
        ]
        for pin in pins {
            let url = sourceRoot.appendingPathComponent(pin.path)
            let data = try Data(contentsOf: url)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(digest, pin.sha256, "\(pin.path) moved — the tab strip must not change on this branch")
        }
    }
}
