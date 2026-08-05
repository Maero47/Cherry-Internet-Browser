//
//  Fix1ShotTests.swift
//  Internet BrowserTests
//
//  Renders the two surfaces fix round 1 changed, in both appearances, straight
//  out of the real views.
//
//  This exists because `screencapture` cannot be used right now: the machine's
//  screen is locked (`CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"]`
//  is 1), which makes every screen capture come back black and makes the
//  accessibility API report zero windows for every application on the system.
//  Offscreen rendering does not go through either of those, so it works
//  regardless — and for the homepage it is the better evidence anyway, because
//  the same pixels can be measured rather than just looked at.
//
//  Skipped unless `CHERRY_SHOT_DIR` is set:
//
//      TEST_RUNNER_CHERRY_SHOT_DIR=/tmp/shots xcodebuild test \
//        -scheme "Internet Browser" -destination 'platform=macOS' \
//        -only-testing:"Internet BrowserTests/Fix1ShotTests"
//

import AppKit
import SwiftUI
import XCTest
@testable import Cherry

@MainActor
final class Fix1ShotTests: XCTestCase {

    private var outputDirectory: URL!

    override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        let path = environment["CHERRY_SHOT_DIR"] ?? environment["TEST_RUNNER_CHERRY_SHOT_DIR"]
        try XCTSkipIf(path == nil, "screenshot rendering is opt-in")
        outputDirectory = URL(fileURLWithPath: path!)
        try FileManager.default.createDirectory(
            at: outputDirectory, withIntermediateDirectories: true
        )
    }

    /// The homepage, drawn by the real `HomePageView` over the real wallpaper
    /// asset, with no wash of any kind.
    func testRenderHomepage() throws {
        for (label, appearance) in [("light", NSAppearance.Name.aqua),
                                    ("dark", NSAppearance.Name.darkAqua)] {
            let view = HomePageView(
                repository: ShortcutRepository.shared,
                onShortcutClick: { _ in },
                onSearch: { _ in },
                onAskAI: { _ in false }
            )
            try shoot(view, size: CGSize(width: 1000, height: 720),
                      to: "after-homepage-\(label).png", appearance: appearance)
        }
    }

    /// The toolbar's glyph-and-plate pair, for a theme whose `toolbar_text` is
    /// light — the case that produced the dark island in a pale bar.
    ///
    /// Rendered rather than screenshotted for the reason in the file comment,
    /// and drawn from the real decision: the tone comes out of
    /// `ThemeContrast.toolbarGlyph`, and the plate under it is the polarity
    /// `scrimIsDark` picks from that tone. Left half is what shipped, right
    /// half is what ships now.
    func testRenderToolbarGlyphAndPlate() throws {
        for (label, scheme, appearance) in [
            ("light", ColorScheme.light, NSAppearance.Name.aqua),
            ("dark", ColorScheme.dark, NSAppearance.Name.darkAqua),
        ] {
            let themeText = Color(red: 0.98, green: 0.98, blue: 0.96)  // a dark-chrome theme
            let bar = label == "light"
                ? Color(red: 0.62, green: 0.78, blue: 0.93)             // the pale tiled bar
                : Color(red: 0.13, green: 0.16, blue: 0.22)

            let before = ToolbarPairSample(
                caption: "was: theme tone, whatever the appearance",
                bar: bar, glyph: themeText
            )
            let after = ToolbarPairSample(
                caption: "now: the tone the appearance calls for",
                bar: bar,
                glyph: ThemeContrast.toolbarGlyph(themeText: themeText, appearance: scheme)
            )

            try shoot(
                VStack(spacing: 0) { before; after },
                size: CGSize(width: 720, height: 240),
                to: "toolbar-pair-\(label).png",
                appearance: appearance
            )
        }
    }

    private func shoot(
        _ view: some View, size: CGSize, to name: String, appearance: NSAppearance.Name
    ) throws {
        let hosting = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)))
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.appearance = NSAppearance(named: appearance)
        hosting.layoutSubtreeIfNeeded()
        // The wallpaper decode and the entrance animation both need a turn.
        for _ in 0..<8 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        hosting.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: outputDirectory.appendingPathComponent(name))
    }
}

/// One toolbar row: the bar colour, the plate the guard would put under this
/// glyph, and the glyph itself.
private struct ToolbarPairSample: View {
    let caption: String
    let bar: Color
    let glyph: Color

    private var plateIsDark: Bool {
        ThemeContrast.scrimIsDark(for: ThemeContrast.resolve(glyph))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            ZStack {
                bar
                HStack(spacing: 14) {
                    ForEach(["house", "star", "shield", "book", "eye.slash", "ellipsis"], id: \.self) {
                        Image(systemName: $0)
                            .font(.system(size: 15))
                            .foregroundStyle(glyph)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    (plateIsDark ? Color.black : Color.white).opacity(0.34),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            }
            .frame(height: 64)
        }
        .padding(12)
    }
}
