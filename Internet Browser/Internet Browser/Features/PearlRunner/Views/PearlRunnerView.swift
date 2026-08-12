//
//  PearlRunnerView.swift
//  Cherry Browser
//
//  The offline screen's game, drawn as thinly as possible.
//
//  ## What this file is allowed to know
//
//  Nothing about rules. It reads a `PearlRunnerGame` value and draws it; it
//  translates keys into a `PearlInput`; it starts and stops the controller's
//  driver at the lifecycle edges. Every decision — what a jump does, what
//  collides, when night falls — already happened in the model, where tests
//  can see it.
//
//  ## Where it sits, and why the copy still reads first
//
//  Pearl stands at the top of the offline screen, in the slot the failure
//  symbol holds on every other family — which is where Chrome puts the dino,
//  and it is above the failure text without having pushed any of it down: the
//  mark is wordless artwork the same height as the symbol it replaces, and
//  the button-and-caption offer that used to sit under the actions is gone.
//  So the title is still the first *text* on the screen, still 22pt semibold
//  against an 11pt dimmed caption, and the address and Retry have not moved
//  at all.
//
//  Once a run starts the canvas does grow into that slot and the copy moves
//  down — but by then the user is playing rather than reading, and every word
//  of the failure, the address and Retry are intact directly below it.
//
//  ## How big it gets
//
//  As big as the window allows, up to twice the world's own measure: a run on
//  a full-screen window is drawn 1120×300 rather than 560×150. The field is
//  wider than the reading column it is a row of, so it reports the column's
//  width to the layout and bleeds past both edges — centred on the same axis
//  as the copy, stopping at the same 40pt margin the copy keeps.
//
//  The size is one number, `PearlField`'s magnification, applied by the
//  canvas's own `scaleBy`. Nothing in the simulation is told about it: the
//  world is still 560×150, the collision boxes are still the sprite
//  contract's, and a jump still clears exactly what it cleared. What grows is
//  everything drawn — Pearl, the trees, the gulls, the ground, the score.
//  What does not grow is the idle mark: it stands in for the failure symbol
//  and has to stay the symbol's height, or the copy below it moves.
//
//  ## What colour any of it is
//
//  Not this file's decision, and not the appearance's either: the field is a
//  dusk tone picked for the sprite sheet's own baked colours, the same one in
//  Aqua and in Dark Aqua, because a near-black cat and a near-white gull share
//  every frame and only the middle serves both. `PearlRunnerPalette` is where
//  that is measured and argued.
//
//  ## Starting
//
//  The game still never starts itself: no frame is simulated, and no driver
//  exists, until the player asks. What changed is how they ask. On the
//  offline surface a space bar starts the run outright — no button first —
//  and `PearlSpaceKey` is the rule for when that is allowed to happen. A
//  press the rule calls `notOurs` is returned `.ignored`, so it goes on up
//  the responder chain to the scroll view exactly as it did before.
//
//  ## Sound
//
//  Cherry has never made one before this file's game did. It is one system
//  `Tink` every hundred points, and it is `PearlRunnerChime` that decides
//  whether it may be heard at all — this file contributes exactly two things
//  to that: the M key that silences it, and the `MUTED` the canvas draws when
//  it has been. Nothing here plays anything.
//
//  ## Keys
//
//  Space and ↑ jump, ↓ ducks, M mutes — but only while the runner's own slot holds
//  keyboard focus. The handlers hang off that slot, so an unfocused game
//  cannot see, let alone steal, keys from the browser; losing focus pauses the
//  driver the same tick. There is exactly one slot, and it belongs to the
//  section rather than to the mark or the field, because a slot that is torn
//  down when the mark becomes a field is a slot that loses the keyboard
//  halfway through the first press (see `body`).
//
//  Which leaves the question that decides whether any of it works: how the
//  slot comes to hold focus on a screen nobody has clicked. It asks, when it
//  appears, and `PearlKeyboardClaim` is the rule for whether it may — the
//  offline screen only, and never out of something being typed into. It used
//  to ask through `defaultFocus`, and that ask never arrived: a default focus
//  target is applied when its scope first takes focus, which for a window is
//  long before a page has failed to load. The runner was drawn focusable,
//  offering a space bar, holding nothing; the press ran off the end of the
//  responder chain and macOS beeped. Taking focus is also given back — see
//  `PearlKeyboardHandover` — so the page that comes back after Retry is not
//  left deaf.
//
//  ## Motion
//
//  The rest of this screen is deliberately still (see the note atop
//  `NavigationFailureView`), and the offer keeps that stillness: nothing
//  animates until the player explicitly asks for a game of dodging trees.
//  With Reduce Motion on, the game still runs — motion the user requested is
//  not the motion the setting is about — but the decorative extras (the
//  score's milestone blink) are dropped.
//

import SwiftUI

// MARK: - The mark, and the run it becomes

struct PearlRunnerSection: View {

    /// Whether this failure screen offers the runner at all. Passed in rather
    /// than assumed: the same fact the layout branched on is the fact the key
    /// rule is evaluated with, so a mistake that builds this section on an
    /// instruction screen still cannot make space start a game there.
    let offersRunner: Bool

    /// The whole surface the failure screen was given, not the column's share
    /// of it. A run's field is sized against this; the idle mark ignores it.
    @Environment(\.failureContainerSize) private var available

    @StateObject private var controller: PearlRunnerController
    @FocusState private var isFocused: Bool

    /// Which window this is in, and who had the keyboard before the runner
    /// asked for it.
    @State private var handover = PearlKeyboardHandover()

    /// The controller is injectable for exactly one reason: the tests that
    /// press a real space bar at a real window need to see whether the run
    /// started, and a `@StateObject` the section makes for itself is reachable
    /// from nowhere. The app never passes one.
    init(offersRunner: Bool, controller: PearlRunnerController? = nil) {
        self.offersRunner = offersRunner
        _controller = StateObject(wrappedValue: controller ?? PearlRunnerController())
    }

    private var metrics: PearlField.Metrics {
        PearlField.metrics(availableWidth: available.width, availableHeight: available.height)
    }

    /// ONE keyboard slot, and it is the mark's.
    ///
    /// There used to be two — the mark was focusable, and so was the field
    /// that replaced it — and the swap between them dropped the keyboard on
    /// the floor: SwiftUI treats the two branches of an `if` as two different
    /// views, so the focused one was torn down and the keyboard went back to
    /// the window. `isFocused` went false, which paused the run in the same
    /// breath that started it, and the space bar that should have been the
    /// first jump was a beep again.
    ///
    /// So the mark is the base of the slot whether or not a run is going. It
    /// is what sizes the idle row, it is hidden once the field is drawn over
    /// it, and — the part that matters — it never goes away, so neither does
    /// the keyboard. A view swapped inside an `overlay` does not disturb the
    /// focus of the view it is drawn on; a view swapped by an `if` is the
    /// focus.
    var body: some View {
        idleMark
        .opacity(controller.hasStarted ? 0 : 1)
        .accessibilityHidden(controller.hasStarted)
        // The run's own measure, taken over from the mark's. `nil` while the
        // mark is what is showing, so the idle row is sized by the mark
        // exactly as it always was.
        .frame(
            width: controller.hasStarted ? metrics.width : nil,
            height: controller.hasStarted ? metrics.height : nil
        )
        .overlay {
            if controller.hasStarted {
                PearlRunnerSurface(
                    controller: controller,
                    metrics: metrics,
                    isFocused: isFocused
                )
            }
        }
        .contentShape(Rectangle())
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.space], phases: [.down, .up]) { press in
            guard press.phase == .down else {
                controller.spaceReleased()
                return .handled
            }
            // Start, jump or run again — one rule, asked the same way at every
            // point of the run, because there is now one place that asks.
            let meaning = controller.spacePressed(
                offersRunner: offersRunner,
                runnerHasKeyboardFocus: isFocused
            )
            // A press that was never ours goes back up the responder chain,
            // where space still scrolls the failure column.
            return meaning == .notOurs ? .ignored : .handled
        }
        .onKeyPress(keys: [.upArrow], phases: [.down, .up]) { press in
            // ↑ is the jump's second key. It never starts a run: the offline
            // screen promises one key for that, and it is space — so before
            // there is a run, ↑ is the scroll view's, exactly as it was.
            guard controller.hasStarted else { return .ignored }
            if press.phase == .down {
                if controller.game.phase == .crashed {
                    controller.input.jump = false
                    controller.restart()
                } else {
                    controller.input.jump = true
                    controller.resume()
                }
            } else {
                controller.input.jump = false
            }
            return .handled
        }
        .onKeyPress(keys: [.downArrow], phases: [.down, .up]) { press in
            guard controller.hasStarted else { return .ignored }
            controller.input.duck = press.phase == .down
            return .handled
        }
        .onKeyPress(keys: ["m"], phases: [.down]) { _ in
            // The silencer, and it is deliberately in the game rather than in
            // Settings: the person who wants the noise to stop is holding the
            // keyboard, looking at the thing making it. Like ↑ and ↓ it does
            // nothing before a run exists, so `m` still reaches whatever the
            // offline screen would otherwise have done with it.
            guard controller.hasStarted else { return .ignored }
            controller.toggleMute()
            return .handled
        }
        .onTapGesture {
            // A click is the other way in, and it is allowed to take the
            // keyboard from anywhere — the user pointed at the game. It still
            // records what it took it from, so the page gets it back.
            handover.take()
            isFocused = true
            if !controller.hasStarted {
                controller.begin()
            } else if controller.game.phase == .crashed {
                controller.restart()
            }
        }
        .onChange(of: isFocused) { _, focused in
            // An unfocused game must neither hear keys (guaranteed by focus)
            // nor keep simulating a run the player is no longer steering.
            // Inert until a run exists: `resume()` and `pause()` both know
            // there is nothing to drive.
            if focused {
                controller.resume()
            } else {
                controller.input = PearlInput()
                controller.pause()
            }
        }
        // How the handover learns which window it is in — and, because the
        // answer can arrive either side of `onAppear`, the second of the two
        // places the keyboard is asked for.
        .background {
            PearlKeyboardWindowReader(handover: handover, windowKnown: windowBecameKnown)
        }
        .onAppear(perform: windowBecameKnown)
        .onDisappear {
            // The failure screen is gone — the page came back, or the tab did.
            // Whatever held the keyboard before the runner asked for it gets
            // it back.
            handover.giveBack()
        }
        // Full bleed. The field is wider than the reading column it is a row
        // of, so it reports the column's width to the layout and draws past
        // both edges of it — centred on the same axis as the copy below,
        // stopping at the same margin the copy keeps. A field that already
        // fits inside the column bleeds by zero, and the idle mark, which is
        // narrower than the column to begin with, never bleeds at all.
        .padding(
            .horizontal,
            controller.hasStarted
                ? -PearlField.bleed(availableWidth: available.width, availableHeight: available.height)
                : 0
        )
    }

    /// The window arrived — from either side of the same instant, see below.
    /// Two things want it: the keyboard claim, and the chime, which will not
    /// make a sound unless that window is the one holding the keyboard.
    private func windowBecameKnown() {
        controller.chime.observe(window: handover.window)
        claimKeyboardIfAllowed()
    }

    /// Ask for the keyboard, if this screen is allowed to have it.
    ///
    /// Called twice, from either side of the same instant: SwiftUI's
    /// `onAppear` and AppKit's `viewDidMoveToWindow` have no guaranteed order
    /// between them, and the decision needs the window — a claim made while
    /// the window is still unknown is a claim made without being able to see
    /// the omnibox it must not interrupt. So whichever runs while the window
    /// is unknown does nothing, and the other one does the work.
    private func claimKeyboardIfAllowed() {
        guard handover.window != nil, !handover.hasTakenKeyboard else { return }
        guard PearlKeyboardClaim.mayClaim(
            offersRunner: offersRunner,
            textIsBeingEdited: handover.textIsBeingEdited
        ) else { return }
        handover.take()
        isFocused = true
    }

    /// Pearl standing still, where the failure symbol stands on every other
    /// screen. Artwork, not a control: there is no button, nothing animates,
    /// and no frame is simulated until space arrives.
    private var idleMark: some View {
        HStack(spacing: 10) {
            PearlStillMark()

            Text(idleCaption)
                .font(.system(size: 11))
                .foregroundStyle(FailurePalette.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement()
        .accessibilityLabel("Pearl’s Runner")
        .accessibilityHint("Press space to run while you wait")
    }

    private var idleCaption: String {
        controller.highScore > 0
            ? "Space to run while you wait. Best \(controller.highScore)."
            : "Space to run while you wait. ↓ ducks, M mutes."
    }
}

/// Pearl at rest, at the optical size of the symbol she stands in for. Drawn
/// from the sprite the game itself runs on, so the mark and the runner are
/// visibly the same cat; in placeholder mode it is the same silhouette the
/// canvas draws.
///
/// ## Why she is on a chip and not on the page
///
/// She is the same near-black cat here as she is in a run, and the offline
/// page in Dark Aqua is `#1E1E1E`. Standing straight on it, the mark measured
/// **1.22:1** — a cat-shaped hole with two gold eyes in it, where every other
/// failure family has a legible symbol. The runner sheet has no cream rim
/// light to save her the way the mascot art does (see `PearlContrastTests`),
/// so what saves her is the same thing that saves her in a run: the field.
///
/// The mark is therefore a 30pt chip of `PearlRunnerPalette.day` with Pearl
/// standing on it — the game's own tone, at rest, so the field the space bar
/// grows is a field already on screen. The chip is the height the mark has
/// always been, so nothing below it moves; Pearl inside it is 26pt, which is
/// the drawn height of the 26pt symbol she stands in for.
///
/// Internal for the same reason `PearlRunnerCanvas` is: the harness measures
/// the tone this view actually puts behind her, walked out of its own body,
/// rather than the palette it is supposed to be reading.
struct PearlStillMark: View {

    /// The chip. Matches the 26pt symbol's drawn height closely enough that
    /// the copy below sits where it sits on every other failure screen.
    private static let height = 30.0
    /// Pearl inside it.
    private static let inset = 2.0

    private static var catHeight: Double { height - inset * 2 }

    var body: some View {
        Group {
            if let image = PearlSpriteLibrary.shared.image("run", frame: 0) {
                image.resizable()
            } else {
                RoundedRectangle(cornerRadius: 4).fill(PearlRunnerPalette.silhouette)
            }
        }
        .frame(
            width: Self.catHeight * PearlSpriteContract.run.width / PearlSpriteContract.run.height,
            height: Self.catHeight
        )
        .padding(Self.inset)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(PearlRunnerPalette.day)
        )
        .accessibilityHidden(true)
    }
}

// MARK: - The game surface

/// The field, once a run exists. It draws and it measures; it neither takes
/// keys nor takes focus — the section around it holds the one keyboard slot,
/// which is what keeps a run from starting deaf. What it still reads is
/// whether that slot is focused, because the ring around the field is how the
/// player can see it.
private struct PearlRunnerSurface: View {

    @ObservedObject var controller: PearlRunnerController
    /// Handed down rather than recomputed: the section sizes its own slot
    /// against these, and a second answer to the same question is how the
    /// field and the row it is drawn in stop agreeing.
    let metrics: PearlField.Metrics
    let isFocused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PearlRunnerCanvas(
            game: controller.game,
            highScore: controller.highScore,
            isTicking: controller.isTicking,
            isMuted: controller.chime.isMuted,
            reduceMotion: reduceMotion
        )
        // The field's own size, not the column's. Exact rather than an aspect
        // ratio inside a maximum: the magnification is `PearlField`'s answer,
        // and the canvas is drawn at precisely it.
        .frame(width: metrics.width, height: metrics.height)
        // The corners have to come off now. The canvas fills a rectangle and
        // the hairline round it is `LibraryShape.rowShape` — the address
        // box's shape, which is how the field is joined to the page rather
        // than dropped on it. While the field was near-white on a near-white
        // page nobody could see the four square corners poking out past that
        // curve; a dusk field on either page colour, they are the first thing
        // you see.
        .clipShape(LibraryShape.rowShape)
        .overlay(LibraryShape.rowShape.stroke(FailurePalette.hairline, lineWidth: 1))
        .overlay(
            LibraryShape.rowShape
                .stroke(Color.accentColor.opacity(0.65), lineWidth: 1.5)
                .opacity(isFocused ? 1 : 0)
        )
        .onDisappear {
            // The page came back, or the user navigated: nothing of the game
            // may keep running behind it.
            controller.shutDown()
        }
        .accessibilityElement()
        .accessibilityLabel("Pearl’s Runner")
        .accessibilityValue("Score \(controller.game.score)")
        .accessibilityHint("Space jumps, down arrow ducks, M mutes the milestone sound")
    }
}

// MARK: - The renderer

/// One `Canvas`, everything derived from the game value. In placeholder mode
/// (no sheet in the bundle yet) every element is a flat rectangle at exactly
/// the logical size the sprite contract fixes, so the geometry being played
/// is the geometry being drawn either way.
///
/// Internal rather than private, and its three tones are internal properties,
/// because the contrast harness measures THIS — the colour the canvas hands
/// to `context.fill`, for a game value it built — rather than the palette the
/// canvas is supposed to be reading. A field hardcoded back into the renderer
/// is the mutation that has to die, and a test that asks the palette cannot
/// see it.
struct PearlRunnerCanvas: View {

    let game: PearlRunnerGame
    let highScore: Int
    let isTicking: Bool
    /// Drawn, not just obeyed: a game that has gone quiet has to say so, or
    /// the next player assumes it is broken.
    let isMuted: Bool
    let reduceMotion: Bool

    private var sprites: PearlSpriteLibrary { .shared }

    /// The field. Never the page's colour: the sheet's cast runs from a
    /// near-black cat to a near-white gull, and only a tone in the middle
    /// leaves both of them visible — see `PearlRunnerPalette`. The sky moves
    /// it within that band, four times round; the appearance does not move it
    /// at all.
    var background: Color { PearlRunnerPalette.field(game.sky) }

    /// Text, and the bright half of the placeholder cast. One tone now, in day
    /// and night alike, because the field no longer crosses the middle.
    var ink: Color { PearlRunnerPalette.ink }

    /// The dark half of the placeholder cast: Pearl and the trees, drawn in
    /// the sheet's own near-black so a sheet-less run reads the way a real one
    /// does.
    var silhouette: Color { PearlRunnerPalette.silhouette }

    /// The score's tone as it is actually drawn, blink included. A function
    /// rather than a literal at the call site because the strength is half the
    /// measurement — 11pt white at full opacity clears the text floor on both
    /// fields and the three quarters it used to be drawn at does not — and the
    /// harness has to be able to ask for the number that ships.
    func scoreInk(blinkedOut: Bool) -> Color {
        ink.opacity(blinkedOut ? 0.25 : 1)
    }

    var body: some View {
        Canvas(opaque: true, rendersAsynchronously: false) { context, size in
            let scale = size.width / PearlWorld.width
            context.scaleBy(x: scale, y: scale)

            context.fill(
                Path(CGRect(x: 0, y: 0, width: PearlWorld.width, height: PearlWorld.height)),
                with: .color(background)
            )

            drawSky(in: &context)
            drawGround(in: &context)
            for obstacle in game.obstacles {
                draw(obstacle, in: &context)
            }
            drawPearl(in: &context)
            drawScore(in: &context)
            drawOverlayText(in: &context)
        }
        .accessibilityHidden(true)
    }

    // MARK: Sky

    private func drawSky(in context: inout GraphicsContext) {
        for cloud in game.clouds {
            let rect = CGRect(
                x: cloud.x, y: cloud.y,
                width: PearlSpriteContract.cloud.width,
                height: PearlSpriteContract.cloud.height
            )
            if let image = sprites.image("cloud", frame: 0) {
                context.draw(image, in: rect)
            } else {
                context.fill(Path(roundedRect: rect, cornerRadius: 6), with: .color(ink.opacity(0.85)))
            }
        }

        guard game.isNight else { return }
        let moonRect = CGRect(
            x: 470, y: 18,
            width: PearlSpriteContract.moon.width,
            height: PearlSpriteContract.moon.height
        )
        if let moon = sprites.image("moon", frame: 0) {
            context.draw(moon, in: moonRect)
        } else {
            context.fill(Path(ellipseIn: moonRect), with: .color(ink.opacity(0.8)))
        }
        // A fixed constellation: decoration needs no randomness.
        for (x, y) in [(60.0, 24.0), (170.0, 42.0), (300.0, 16.0), (395.0, 50.0)] {
            let rect = CGRect(
                x: x, y: y,
                width: PearlSpriteContract.star.width,
                height: PearlSpriteContract.star.height
            )
            if let star = sprites.image("star", frame: 0) {
                context.draw(star, in: rect)
            } else {
                context.fill(Path(ellipseIn: rect.insetBy(dx: 3, dy: 3)), with: .color(ink.opacity(0.7)))
            }
        }
    }

    // MARK: Ground

    private func drawGround(in context: inout GraphicsContext) {
        let stripTop = PearlWorld.feetLine - PearlSpriteContract.groundHeight
        if let manifest = sprites.manifest,
           let groundFrame = manifest.frames("ground").first,
           sprites.hasArtwork {
            // Tile the strip, scrolled by distance, wrapped by its own width.
            let tileWidth = Double(groundFrame.w) / Double(manifest.scale)
            let offset = game.distance.truncatingRemainder(dividingBy: tileWidth)
            var x = -offset
            while x < PearlWorld.width {
                if let image = sprites.image("ground", frame: 0) {
                    context.draw(
                        image,
                        in: CGRect(x: x, y: stripTop, width: tileWidth,
                                   height: PearlSpriteContract.groundHeight)
                    )
                }
                x += tileWidth
            }
        } else {
            // Placeholder: the running surface as a line, with a scrolling
            // speckle so motion reads even before the art lands.
            context.fill(
                Path(CGRect(x: 0, y: stripTop, width: PearlWorld.width, height: 2)),
                with: .color(ink)
            )
            let phase = game.distance.truncatingRemainder(dividingBy: 24)
            var x = -phase
            while x < PearlWorld.width {
                context.fill(
                    Path(CGRect(x: x, y: stripTop + 7, width: 3, height: 2)),
                    with: .color(ink.opacity(0.45))
                )
                x += 24
            }
        }
    }

    // MARK: Obstacles

    private func draw(_ obstacle: PearlObstacle, in context: inout GraphicsContext) {
        switch obstacle.kind {
        case .smallTrees(let count):
            drawTrees(named: "tree_small", count: count, size: PearlSpriteContract.treeSmall,
                      at: obstacle.x, in: &context)
        case .largeTrees(let count):
            drawTrees(named: "tree_large", count: count, size: PearlSpriteContract.treeLarge,
                      at: obstacle.x, in: &context)
        case .gull:
            let flap = (game.frame / 15) % 2
            let rect = CGRect(
                x: obstacle.x, y: obstacle.kind.topY,
                width: PearlSpriteContract.gull.width,
                height: PearlSpriteContract.gull.height
            )
            if let image = sprites.image("gull", frame: flap) {
                context.draw(image, in: rect)
            } else {
                // Placeholder gull: body bar with the flap shown as the bar
                // riding high or low in its box.
                let bar = CGRect(
                    x: rect.minX + 6,
                    y: rect.minY + (flap == 0 ? 8 : 18),
                    width: rect.width - 12,
                    height: 10
                )
                context.fill(Path(roundedRect: bar, cornerRadius: 3), with: .color(ink))
            }
        }
    }

    private func drawTrees(
        named name: String,
        count: Int,
        size: PearlSpriteContract.LogicalSize,
        at x: Double,
        in context: inout GraphicsContext
    ) {
        for index in 0..<count {
            let rect = CGRect(
                x: x + Double(index) * size.width,
                y: PearlWorld.feetLine - size.height,
                width: size.width,
                height: size.height
            )
            if let image = sprites.image(name, frame: 0) {
                context.draw(image, in: rect)
            } else {
                context.fill(
                    Path(roundedRect: rect.insetBy(dx: 1, dy: 0), cornerRadius: 2),
                    with: .color(silhouette)
                )
            }
        }
    }

    // MARK: Pearl

    private func drawPearl(in context: inout GraphicsContext) {
        let bounds = game.pearlBounds
        let rect = CGRect(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height)

        let name: String
        let frameIndex: Int
        if game.phase == .crashed {
            name = "hit"
            frameIndex = 0
        } else if game.isAirborne {
            name = "jump"
            frameIndex = 0
        } else if game.isDucking {
            name = "duck"
            frameIndex = (game.frame / 6) % 2
        } else {
            name = "run"
            frameIndex = (game.frame / 6) % 2
        }

        if let image = sprites.image(name, frame: frameIndex) {
            context.draw(image, in: rect)
        } else {
            // Pearl is a black cat; the placeholder is her silhouette, in her
            // own near-black rather than in the ink, with the run cycle shown
            // as a 1pt bob so life reads before art does.
            var body = rect
            if name == "run" && frameIndex == 1 {
                body.origin.y += 1
                body.size.height -= 1
            }
            context.fill(Path(roundedRect: body, cornerRadius: 4), with: .color(silhouette))
        }
    }

    // MARK: Score and overlays

    private func drawScore(in context: inout GraphicsContext) {
        // The milestone blink: five short pulses after each 100. Dropped
        // entirely under Reduce Motion.
        let justCrossedMilestone = game.score > 0 && game.score % 100 < 2
        let blinkedOut = !reduceMotion && justCrossedMilestone && (game.frame / 8) % 2 == 1

        var line = String(format: "%05d", game.score)
        if highScore > 0 {
            line = "HI " + String(format: "%05d", highScore) + "  " + line
        }
        // Full strength between blinks. It used to be 0.75, which was
        // affordable on paper and is not on a dusk field: the score is 11pt
        // text, it wants 4.5:1, and the field's brightness ceiling was solved
        // for the brightest ink there is rather than for three quarters of it.
        let text = Text(line)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(scoreInk(blinkedOut: blinkedOut))
        context.draw(text, at: CGPoint(x: PearlWorld.width - 10, y: 10), anchor: .topTrailing)

        guard isMuted else { return }
        // The mute state, opposite the score and in the score's own tone, so
        // it is one measured piece of text rather than a second one.
        let muted = Text("MUTED")
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(scoreInk(blinkedOut: false))
        context.draw(muted, at: CGPoint(x: 10, y: 10), anchor: .topLeading)
    }

    private func drawOverlayText(in context: inout GraphicsContext) {
        let message: String?
        if game.phase == .crashed {
            // The crash screen is where the key is advertised, because it is
            // the first moment the player has definitely heard the sound and
            // is not busy dodging a tree.
            message = isMuted
                ? "Game over — Space to run again · M unmutes"
                : "Game over — Space to run again · M mutes"
        } else if !isTicking {
            message = "Click to run"
        } else {
            message = nil
        }
        guard let message else { return }

        let text = Text(message)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(ink)
        context.draw(text, at: CGPoint(x: PearlWorld.width / 2, y: 58), anchor: .center)
    }
}
