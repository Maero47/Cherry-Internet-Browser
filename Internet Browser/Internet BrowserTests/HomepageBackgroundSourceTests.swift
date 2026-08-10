//
//  HomepageBackgroundSourceTests.swift
//  Internet BrowserTests
//
//  The homepage-background decision: accent wallpaper vs. imported Firefox
//  theme background vs. curated theme vs. the accent-derived gradient used for
//  accents that ship no wallpaper. This is where the "I can't switch the
//  homepage wallpaper back to the accent one" lock-out lived.
//

import XCTest
@testable import Cherry

final class HomepageBackgroundSourceTests: XCTestCase {

    // MARK: - Wallpaper lookup

    func testEveryPaletteAccentHasAWallpaper() {
        let expected: [(hex: String, asset: String)] = [
            ("DB283C", "HomepageWallpaperDB283C"),
            ("2563EB", "HomepageWallpaper2563EB"),
            ("059669", "HomepageWallpaper059669"),
            ("7C3AED", "HomepageWallpaper7C3AED"),
            ("EA580C", "HomepageWallpaperEA580C"),
            ("DB2777", "HomepageWallpaperDB2777"),
            ("0D9488", "HomepageWallpaper0D9488"),
            ("6B7280", "HomepageWallpaper6B7280"),
        ]
        for (hex, asset) in expected {
            XCTAssertEqual(
                HomepageBackgroundResolver.wallpaperAssetName(forAccentHex: hex),
                asset,
                "accent \(hex)"
            )
        }
        // The picker's options and the shipped wallpapers must not drift apart.
        XCTAssertEqual(Set(expected.map(\.hex)), Set(AccentColorOption.options.map(\.hex)))
    }

    func testWallpaperLookupNormalizesTheHex() {
        for spelling in ["db283c", "#DB283C", "#db283c", " DB283C "] {
            XCTAssertEqual(
                HomepageBackgroundResolver.wallpaperAssetName(forAccentHex: spelling),
                "HomepageWallpaperDB283C",
                "spelling \(spelling)"
            )
        }
    }

    func testNoWallpaperForAnAccentOutsideThePalette() {
        XCTAssertNil(HomepageBackgroundResolver.wallpaperAssetName(forAccentHex: "123456"))
        XCTAssertNil(HomepageBackgroundResolver.wallpaperAssetName(forAccentHex: ""))
    }

    // MARK: - Resolution table

    private func resolve(
        matchesAccent: Bool,
        prefersCustomImage: Bool = false,
        customImageIsAvailable: Bool = false,
        prefersThemeBackground: Bool,
        themeHasBackground: Bool,
        isPrivate: Bool = false,
        accentHex: String = "2563EB",
        curatedTheme: HomepageTheme = .midnight
    ) -> HomepageBackgroundSource {
        HomepageBackgroundResolver.resolve(
            matchesAccent: matchesAccent,
            prefersCustomImage: prefersCustomImage,
            customImageIsAvailable: customImageIsAvailable,
            prefersThemeBackground: prefersThemeBackground,
            themeHasBackground: themeHasBackground,
            isPrivate: isPrivate,
            accentHex: accentHex,
            curatedTheme: curatedTheme
        )
    }

    func testAutoShowsTheAccentWallpaperWhenNoThemeIsInvolved() {
        XCTAssertEqual(
            resolve(matchesAccent: true, prefersThemeBackground: false, themeHasBackground: false),
            .accentWallpaper(assetName: "HomepageWallpaper2563EB")
        )
    }

    func testAnUnknownAccentFallsBackToTheAccentDerivedGradientNotACuratedTheme() {
        XCTAssertEqual(
            resolve(
                matchesAccent: true,
                prefersThemeBackground: false,
                themeHasBackground: false,
                accentHex: "123456"
            ),
            .accentGradient
        )
    }

    func testAnExplicitThemeWinsOverAuto() {
        XCTAssertEqual(
            resolve(
                matchesAccent: false,
                prefersThemeBackground: false,
                themeHasBackground: false,
                curatedTheme: .forest
            ),
            .curatedTheme(.forest)
        )
    }

    func testAFreshlyImportedThemeBackgroundTakesOver() {
        // prefersThemeBackground is set on import, so the theme's ntp_background
        // shows regardless of what the homepage was set to before.
        XCTAssertEqual(
            resolve(matchesAccent: true, prefersThemeBackground: true, themeHasBackground: true),
            .themeBackground
        )
        XCTAssertEqual(
            resolve(matchesAccent: false, prefersThemeBackground: true, themeHasBackground: true),
            .themeBackground
        )
    }

    func testTheAccentWallpaperIsReachableAgainWithTheThemeStillActive() {
        // The lock-out: this case used to be .themeBackground forever.
        XCTAssertEqual(
            resolve(matchesAccent: true, prefersThemeBackground: false, themeHasBackground: true),
            .accentWallpaper(assetName: "HomepageWallpaper2563EB")
        )
    }

    func testACuratedThemeIsReachableAgainWithTheThemeStillActive() {
        XCTAssertEqual(
            resolve(
                matchesAccent: false,
                prefersThemeBackground: false,
                themeHasBackground: true,
                curatedTheme: .slate
            ),
            .curatedTheme(.slate)
        )
    }

    // MARK: - The user's own picture

    /// A picture the user chose by hand outranks everything, including a
    /// theme background the user is also letting win: choosing a file says
    /// "put exactly this on my homepage", importing a theme only says "use
    /// this theme".
    func testAChosenPictureOutranksTheThemeBackground() {
        XCTAssertEqual(
            resolve(
                matchesAccent: true,
                prefersCustomImage: true,
                customImageIsAvailable: true,
                prefersThemeBackground: true,
                themeHasBackground: true
            ),
            .customImage
        )
        XCTAssertEqual(
            resolve(
                matchesAccent: false,
                prefersCustomImage: true,
                customImageIsAvailable: true,
                prefersThemeBackground: false,
                themeHasBackground: false,
                curatedTheme: .forest
            ),
            .customImage
        )
    }

    /// The private-window rule keeps an imported third-party artifact out of
    /// private windows. The user's own picture is their appearance choice,
    /// like the accent wallpaper — which private windows have always shown —
    /// so it is not gated.
    func testAChosenPictureShowsInPrivateWindows() {
        XCTAssertEqual(
            resolve(
                matchesAccent: true,
                prefersCustomImage: true,
                customImageIsAvailable: true,
                prefersThemeBackground: true,
                themeHasBackground: true,
                isPrivate: true
            ),
            .customImage
        )
    }

    /// Storage can be cleaned or the copy corrupted behind the preference's
    /// back. Preferring a picture that is gone must fall through to whatever
    /// would have won without it — the homepage never goes blank.
    func testAMissingPictureFallsBackRatherThanBlanking() {
        XCTAssertEqual(
            resolve(
                matchesAccent: true,
                prefersCustomImage: true,
                customImageIsAvailable: false,
                prefersThemeBackground: true,
                themeHasBackground: true
            ),
            .themeBackground
        )
        XCTAssertEqual(
            resolve(
                matchesAccent: true,
                prefersCustomImage: true,
                customImageIsAvailable: false,
                prefersThemeBackground: false,
                themeHasBackground: false
            ),
            .accentWallpaper(assetName: "HomepageWallpaper2563EB")
        )
        XCTAssertEqual(
            resolve(
                matchesAccent: false,
                prefersCustomImage: true,
                customImageIsAvailable: false,
                prefersThemeBackground: false,
                themeHasBackground: false,
                curatedTheme: .rose
            ),
            .curatedTheme(.rose)
        )
    }

    /// A copy still sitting in storage stays quiet once the user has picked
    /// any other swatch — availability alone must never outrank a choice.
    func testAStoredPictureStaysQuietOnceAnotherSwatchIsPicked() {
        XCTAssertEqual(
            resolve(
                matchesAccent: true,
                prefersCustomImage: false,
                customImageIsAvailable: true,
                prefersThemeBackground: false,
                themeHasBackground: false
            ),
            .accentWallpaper(assetName: "HomepageWallpaper2563EB")
        )
    }

    // MARK: - Glyph treatment follows the source

    /// The halo decision is made against the source in one pure mapping:
    /// shipped wallpapers keep the stack their numbers were measured with,
    /// the user's picture gets the reinforced stack measured against pure
    /// white, and the gradient/flat sources — whose luminance is known —
    /// get none.
    func testEachSourceBuysItsGlyphTreatment() {
        XCTAssertEqual(
            HomepageGlyphHalo.treatment(for: .accentWallpaper(assetName: "HomepageWallpaperDB283C")),
            .standard
        )
        XCTAssertEqual(HomepageGlyphHalo.treatment(for: .customImage), .reinforced)
        XCTAssertEqual(HomepageGlyphHalo.treatment(for: .themeBackground), .none)
        XCTAssertEqual(HomepageGlyphHalo.treatment(for: .accentGradient), .none)
        XCTAssertEqual(HomepageGlyphHalo.treatment(for: .curatedTheme(.midnight)), .none)
    }

    // MARK: - Private windows are never themed

    func testAPrivateWindowNeverGetsTheThemeBackground() {
        // Same inputs as testAFreshlyImportedThemeBackgroundTakesOver, which is
        // .themeBackground in an ordinary window.
        XCTAssertEqual(
            resolve(
                matchesAccent: true,
                prefersThemeBackground: true,
                themeHasBackground: true,
                isPrivate: true
            ),
            .accentWallpaper(assetName: "HomepageWallpaper2563EB")
        )
        XCTAssertEqual(
            resolve(
                matchesAccent: false,
                prefersThemeBackground: true,
                themeHasBackground: true,
                isPrivate: true,
                curatedTheme: .forest
            ),
            .curatedTheme(.forest)
        )
    }

    func testPrivacyGateChangesNothingWhenNoThemeBackgroundIsWinning() {
        for isPrivate in [false, true] {
            XCTAssertEqual(
                resolve(
                    matchesAccent: true,
                    prefersThemeBackground: false,
                    themeHasBackground: true,
                    isPrivate: isPrivate
                ),
                .accentWallpaper(assetName: "HomepageWallpaper2563EB"),
                "isPrivate \(isPrivate)"
            )
        }
    }

    func testPreferringAThemeBackgroundIsInertWithoutOne() {
        // The flag stays true across theme removal; it must not strand the
        // homepage on a background that no longer exists.
        XCTAssertEqual(
            resolve(matchesAccent: true, prefersThemeBackground: true, themeHasBackground: false),
            .accentWallpaper(assetName: "HomepageWallpaper2563EB")
        )
        XCTAssertEqual(
            resolve(
                matchesAccent: false,
                prefersThemeBackground: true,
                themeHasBackground: false,
                curatedTheme: .rose
            ),
            .curatedTheme(.rose)
        )
    }
}
