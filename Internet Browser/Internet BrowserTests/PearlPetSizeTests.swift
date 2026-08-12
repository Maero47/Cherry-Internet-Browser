//
//  PearlPetSizeTests.swift
//  Internet BrowserTests
//
//  "She is too small — and let the user change it."
//
//  The constraint that shapes the whole answer is that Pearl is pixel art. She
//  is a 36x40 drawing at 1x, and the ONLY magnification that preserves it is a
//  whole multiple with a nearest-neighbour filter: at 1.5x her two-pixel eye
//  becomes three pixels wide and two tall, and her one-pixel glint appears and
//  disappears as she breathes. So the sizes on offer are 1x, 2x and 3x, and
//  these tests hold that — the enum can only produce whole multiples, every
//  drawn box is the contract's box times one of them, and the pixel lookup
//  behind her hit test divides by the same number so a click on a 3x cat still
//  finds the art pixel that was drawn there.
//

import AppKit
import XCTest
@testable import Cherry

@MainActor
final class PearlPetSizeTests: XCTestCase {

    // MARK: - Whole multiples, nothing else

    /// Every size is a whole multiple of the sheet's own scale, and there is no
    /// way to express one that is not.
    ///
    /// Dies on a `case half = 0`-style addition, on the raw values being turned
    /// into indices (0, 1, 2), and on anybody adding a fractional scale.
    func testEverySizeIsAWholeMultiple() {
        for size in PearlPetSize.allCases {
            XCTAssertGreaterThanOrEqual(size.multiple, 1, "\(size) magnifies by less than 1x")
            XCTAssertEqual(size.scale, CGFloat(size.multiple), "\(size)'s scale is not its multiple")
            XCTAssertEqual(size.scale.truncatingRemainder(dividingBy: 1), 0, "\(size) is fractional")
            XCTAssertEqual(size.rawValue, size.multiple, "the stored value is not the multiple")
        }
        XCTAssertEqual(PearlPetSize.allCases.map(\.multiple), [1, 2, 3])
    }

    /// The sheet is authored at 1x, which is what makes a whole multiple exact:
    /// every art pixel becomes an n-by-n block of points with no resampling.
    /// If the sheet were ever re-authored at 2x this test is the one that says
    /// the sizes have to be re-thought.
    func testTheSheetSheIsMagnifiedFromIsAuthoredAt1x() throws {
        let manifest = try XCTUnwrap(PearlSpriteLibrary.shared.manifest)
        XCTAssertEqual(manifest.scale, 1, "the sizes on offer assume a 1x sheet")
    }

    /// Her drawn box at every size is the contract's box times the multiple —
    /// including the sleeping box, which is a different shape and must scale
    /// with her rather than staying put.
    func testEveryPoseIsTheContractBoxTimesTheMultiple() {
        for size in PearlPetSize.allCases {
            for pose in PearlPetPose.allCases {
                let drawn = size.spriteSize(for: pose)
                XCTAssertEqual(drawn.width, pose.logicalSize.width * size.scale, accuracy: 0.001)
                XCTAssertEqual(drawn.height, pose.logicalSize.height * size.scale, accuracy: 0.001)
                XCTAssertEqual(
                    drawn.width.truncatingRemainder(dividingBy: 1), 0,
                    "\(pose) at \(size) is \(drawn.width)pt wide — a fraction of a point"
                )
            }
            XCTAssertEqual(size.standingSize, size.spriteSize(for: .sitting))
        }
    }

    /// The default is the one the owner asked for: bigger than she was.
    func testTheDefaultIsBiggerThanSheWas() {
        XCTAssertEqual(PearlPetSize.default, .medium)
        XCTAssertGreaterThan(
            PearlPetSize.default.scale, PearlPetSize.small.scale,
            "the default is still the size the owner called too small"
        )
        XCTAssertEqual(PearlPetSize.small.standingSize, CGSize(width: 36, height: 40))
        XCTAssertEqual(PearlPetSize.default.standingSize, CGSize(width: 72, height: 80))
    }

    /// She is a companion at every size, not the page: even at 3x on the
    /// smallest window she is allowed in, her whole view is a small share of
    /// it.
    func testEvenAtHerLargestSheIsNotThePage() {
        for size in PearlPetSize.allCases {
            let smallest = PearlPetPlacement.minimumContentSize(for: size)
            let host = PearlPetPlacement.hostSize(for: size)
            let share = (host.width * host.height) / (smallest.width * smallest.height)
            XCTAssertLessThan(
                share, 0.25,
                "\(size) covers \(share * 100)% of the smallest window she is allowed in"
            )
            print(String(format: "PET SIZE %@: %.0fx%.0fpt cat, view %.0fx%.0f, needs %.0fx%.0f",
                         size.title, size.standingSize.width, size.standingSize.height,
                         host.width, host.height, smallest.width, smallest.height))
        }
    }

    /// A bigger cat needs a bigger page, and the thresholds go up with her.
    func testABiggerCatNeedsABiggerPage() {
        let sizes = PearlPetSize.allCases.map { PearlPetPlacement.minimumContentSize(for: $0) }
        for (smaller, larger) in zip(sizes, sizes.dropFirst()) {
            XCTAssertGreaterThanOrEqual(larger.width, smaller.width)
            XCTAssertGreaterThan(larger.height, smaller.height)
        }
        // At 1x the absolute floor is the binding one, so the rule she has
        // always had is unchanged.
        XCTAssertEqual(
            PearlPetPlacement.minimumContentSize(for: .small),
            CGSize(width: 420, height: 260)
        )
    }

    // MARK: - The view draws at the size it is told

    /// The view's own sprite rectangle is the size the user picked, and it
    /// changes the moment the size does — there may be no next tick to do it
    /// (she may be asleep, dozing, or under Reduce Motion).
    ///
    /// Dies on `spriteRect` going back to a constant scale, and on `size`'s
    /// `didSet` not re-laying the layer.
    func testTheViewDrawsAtTheSizeItIsTold() {
        let view = PearlPetView(driver: SilentDriver())
        for size in PearlPetSize.allCases {
            view.size = size
            view.frame = CGRect(origin: .zero, size: PearlPetPlacement.hostSize(for: size))
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(view.spriteRect.size, size.standingSize, "\(size) drew the wrong box")
            XCTAssertEqual(
                view.spriteRect.midX, view.bounds.midX, accuracy: 0.5,
                "\(size) is not centred in her own view"
            )
            XCTAssertEqual(view.spriteRect.minY, 0, "\(size) left the bottom of her view")
        }
    }

    /// The hit test finds the art pixel that was drawn under the pointer at
    /// every size: the same point in HER coordinates is the same pixel of the
    /// drawing, whether that point is 1, 2 or 3 points across.
    ///
    /// Dies on `isOnPearl` losing its division by the scale — at which point a
    /// 3x cat would be clickable only in her bottom-left ninth, and the rest of
    /// her would silently be page.
    func testTheSamePixelIsHitAtEverySize() throws {
        XCTAssertTrue(PearlSpriteLibrary.shared.hasArtwork, "no art: this would prove nothing")

        var maps: [PearlPetSize: [[Bool]]] = [:]
        for size in PearlPetSize.allCases {
            let view = PearlPetView(driver: SilentDriver())
            view.size = size
            view.frame = CGRect(origin: .zero, size: PearlPetPlacement.hostSize(for: size))
            let sprite = view.spriteRect

            // Sample the middle of every art pixel, in art coordinates.
            let art = PearlSpriteContract.petStanding
            var map: [[Bool]] = []
            for row in 0..<Int(art.height) {
                var line: [Bool] = []
                for column in 0..<Int(art.width) {
                    let point = CGPoint(
                        x: sprite.minX + (CGFloat(column) + 0.5) * size.scale,
                        y: sprite.maxY - (CGFloat(row) + 0.5) * size.scale
                    )
                    line.append(view.isOnPearl(point))
                }
                map.append(line)
            }
            maps[size] = map
        }

        let reference = try XCTUnwrap(maps[.small])
        let solid = reference.flatMap { $0 }.filter { $0 }.count
        XCTAssertGreaterThan(solid, 400, "almost none of her is solid — is the sprite loading?")
        for size in PearlPetSize.allCases {
            XCTAssertEqual(
                maps[size], reference,
                "\(size) is a different cat-shaped hole from the 1x one"
            )
        }
    }

    /// And the magnified cat really is bigger to click on: the same drawing,
    /// covering n-squared the area.
    func testABiggerCatIsBiggerToClick() {
        var areas: [PearlPetSize: CGFloat] = [:]
        for size in PearlPetSize.allCases {
            let view = PearlPetView(driver: SilentDriver())
            view.size = size
            view.frame = CGRect(origin: .zero, size: PearlPetPlacement.hostSize(for: size))
            let sprite = view.spriteRect
            var hits: CGFloat = 0
            for x in stride(from: sprite.minX + 0.5, to: sprite.maxX, by: 1) {
                for y in stride(from: sprite.minY + 0.5, to: sprite.maxY, by: 1) {
                    if view.isOnPearl(CGPoint(x: x, y: y)) { hits += 1 }
                }
            }
            areas[size] = hits
        }
        let small = areas[.small] ?? 0
        XCTAssertGreaterThan(small, 400)
        XCTAssertEqual((areas[.medium] ?? 0) / small, 4, accuracy: 0.05, "2x is not four times the area")
        XCTAssertEqual((areas[.large] ?? 0) / small, 9, accuracy: 0.05, "3x is not nine times the area")
    }

    // MARK: - Choosing one

    /// The menu changes her there and then, tells the SwiftUI side so it can be
    /// written down, and does nothing at all when the size is already the one
    /// picked.
    func testPickingASizeChangesHerAndIsReported() {
        let view = PearlPetView(driver: SilentDriver())
        view.size = .small
        var reported: [PearlPetSize] = []
        view.onResize = { reported.append($0) }

        view.resize(to: .large)
        XCTAssertEqual(view.size, .large)
        XCTAssertEqual(reported, [.large])

        view.resize(to: .large)
        XCTAssertEqual(reported, [.large], "picking the size she already is reported a change")
    }

    /// A size Cherry cannot draw never comes back out of the preference.
    func testAnImpossibleStoredSizeIsHerDefault() {
        for raw in [-3, 0, 4, 99, Int.max] {
            XCTAssertEqual(
                PearlPetSize.stored(raw), .default,
                "a stored size of \(raw) produced a cat this code cannot draw"
            )
        }
        for size in PearlPetSize.allCases {
            XCTAssertEqual(PearlPetSize.stored(size.rawValue), size)
        }
    }
}
