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
//  ## Starting
//
//  The game still never starts itself: no frame is simulated, and no driver
//  exists, until the player asks. What changed is how they ask. On the
//  offline surface a space bar starts the run outright — no button first —
//  and `PearlSpaceKey` is the rule for when that is allowed to happen. A
//  press the rule calls `notOurs` is returned `.ignored`, so it goes on up
//  the responder chain to the scroll view exactly as it did before.
//
//  ## Keys
//
//  Space and ↑ jump, ↓ ducks — but only while the runner's own slot holds
//  keyboard focus. The handlers hang off the focused view, so an unfocused
//  game cannot see, let alone steal, keys from the browser; losing focus
//  pauses the driver the same tick. The idle mark takes focus through
//  `defaultFocus` at automatic priority, which yields to anything the user
//  has already focused — the offline screen asks for the keyboard, it does
//  not take it off the omnibox.
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

    @StateObject private var controller = PearlRunnerController()
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if controller.hasStarted {
                PearlRunnerSurface(
                    controller: controller,
                    offersRunner: offersRunner,
                    available: available,
                    isFocused: $isFocused
                )
            } else {
                idleMark
            }
        }
        // Automatic priority: this asks for the keyboard when the offline
        // screen appears and nothing else has claimed it, and yields when
        // something has. The runner never pulls focus off the omnibox.
        .defaultFocus($isFocused, true)
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
        .contentShape(Rectangle())
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.space], phases: [.down, .up]) { press in
            guard press.phase == .down else {
                controller.spaceReleased()
                return .handled
            }
            let meaning = controller.spacePressed(
                offersRunner: offersRunner,
                runnerHasKeyboardFocus: isFocused
            )
            // A press that was never ours goes back up the responder chain,
            // where space still scrolls the failure column.
            return meaning == .notOurs ? .ignored : .handled
        }
        .onTapGesture {
            isFocused = true
            controller.begin()
        }
        .accessibilityElement()
        .accessibilityLabel("Pearl’s Runner")
        .accessibilityHint("Press space to run while you wait")
    }

    private var idleCaption: String {
        controller.highScore > 0
            ? "Space to run while you wait. Best \(controller.highScore)."
            : "Space to run while you wait. ↓ ducks."
    }
}

/// Pearl at rest, at the optical size of the symbol she stands in for. Drawn
/// from the sprite the game itself runs on, so the mark and the runner are
/// visibly the same cat; in placeholder mode it is the same silhouette the
/// canvas draws.
private struct PearlStillMark: View {

    /// Matches the 26pt symbol's drawn height closely enough that the copy
    /// below sits where it sits on every other failure screen.
    private static let height = 30.0

    var body: some View {
        Group {
            if let image = PearlSpriteLibrary.shared.image("run", frame: 0) {
                image.resizable()
            } else {
                RoundedRectangle(cornerRadius: 4).fill(FailurePalette.body)
            }
        }
        .frame(
            width: Self.height * PearlSpriteContract.run.width / PearlSpriteContract.run.height,
            height: Self.height
        )
        .accessibilityHidden(true)
    }
}

// MARK: - The game surface

private struct PearlRunnerSurface: View {

    @ObservedObject var controller: PearlRunnerController
    let offersRunner: Bool
    let available: CGSize
    var isFocused: FocusState<Bool>.Binding

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var metrics: PearlField.Metrics {
        PearlField.metrics(availableWidth: available.width, availableHeight: available.height)
    }

    var body: some View {
        PearlRunnerCanvas(
            game: controller.game,
            highScore: controller.highScore,
            isTicking: controller.isTicking,
            reduceMotion: reduceMotion
        )
        // The field's own size, not the column's. Exact rather than an aspect
        // ratio inside a maximum: the magnification is `PearlField`'s answer,
        // and the canvas is drawn at precisely it.
        .frame(width: metrics.width, height: metrics.height)
        .overlay(LibraryShape.rowShape.stroke(FailurePalette.hairline, lineWidth: 1))
        .contentShape(Rectangle())
        .focusable()
        .focused(isFocused)
        .focusEffectDisabled()
        .overlay(
            LibraryShape.rowShape
                .stroke(Color.accentColor.opacity(0.65), lineWidth: 1.5)
                .opacity(isFocused.wrappedValue ? 1 : 0)
        )
        .onTapGesture {
            isFocused.wrappedValue = true
            if controller.game.phase == .crashed {
                controller.restart()
            }
        }
        .onKeyPress(keys: [.space], phases: [.down, .up]) { press in
            guard press.phase == .down else {
                controller.spaceReleased()
                return .handled
            }
            // A run is in flight or crashed, so this can only come back as
            // jump or restart — but it goes through the same rule as the
            // press that started the run, not a second copy of it.
            let meaning = controller.spacePressed(
                offersRunner: offersRunner,
                runnerHasKeyboardFocus: isFocused.wrappedValue
            )
            return meaning == .notOurs ? .ignored : .handled
        }
        .onKeyPress(keys: [.upArrow], phases: [.down, .up]) { press in
            // ↑ is the jump's second key. It never starts a run: the offline
            // screen promises one key for that, and it is space.
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
            controller.input.duck = press.phase == .down
            return .handled
        }
        .onChange(of: isFocused.wrappedValue) { _, focused in
            // An unfocused game must neither hear keys (guaranteed by focus)
            // nor keep simulating a run the player is no longer steering.
            if focused {
                controller.resume()
            } else {
                controller.input = PearlInput()
                controller.pause()
            }
        }
        .onAppear {
            // The surface exists because the player asked for a run, with a
            // key or a click; keep the keyboard on it so the next space bar is
            // a jump. If the window declines, the overlay says "Click to run"
            // and the tap gesture takes the same path.
            isFocused.wrappedValue = true
        }
        .onDisappear {
            // The page came back, or the user navigated: nothing of the game
            // may keep running behind it.
            controller.shutDown()
        }
        // Full bleed. The field is wider than the reading column it is a row
        // of, so it reports the column's width to the layout and draws past
        // both edges of it — centred on the same axis as the copy below,
        // stopping at the same margin the copy keeps. A field that already
        // fits inside the column bleeds by zero and this does nothing.
        .padding(
            .horizontal,
            -PearlField.bleed(availableWidth: available.width, availableHeight: available.height)
        )
        .accessibilityLabel("Pearl’s Runner")
        .accessibilityValue("Score \(controller.game.score)")
        .accessibilityHint("Space jumps, down arrow ducks")
    }
}

// MARK: - The renderer

/// One `Canvas`, everything derived from the game value. In placeholder mode
/// (no sheet in the bundle yet) every element is a flat rectangle at exactly
/// the logical size the sprite contract fixes, so the geometry being played
/// is the geometry being drawn either way.
private struct PearlRunnerCanvas: View {

    let game: PearlRunnerGame
    let highScore: Int
    let isTicking: Bool
    let reduceMotion: Bool

    private var sprites: PearlSpriteLibrary { .shared }

    /// Day is paper, night is sky; the ink flips with it, Chrome-runner
    /// style, so the placeholder silhouettes stay visible in both.
    private var background: Color {
        game.isNight ? Color(red: 0.09, green: 0.09, blue: 0.12) : Color(red: 0.97, green: 0.97, blue: 0.96)
    }
    private var ink: Color {
        game.isNight ? Color(red: 0.92, green: 0.92, blue: 0.90) : Color(red: 0.20, green: 0.20, blue: 0.22)
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
                context.fill(Path(roundedRect: rect, cornerRadius: 6), with: .color(ink.opacity(0.25)))
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
                    with: .color(ink.opacity(0.85))
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
            // Pearl is a black cat; the placeholder is her silhouette, with
            // the run cycle shown as a 1pt bob so life reads before art does.
            var body = rect
            if name == "run" && frameIndex == 1 {
                body.origin.y += 1
                body.size.height -= 1
            }
            context.fill(Path(roundedRect: body, cornerRadius: 4), with: .color(ink))
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
        let text = Text(line)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(ink.opacity(blinkedOut ? 0.2 : 0.75))
        context.draw(text, at: CGPoint(x: PearlWorld.width - 10, y: 10), anchor: .topTrailing)
    }

    private func drawOverlayText(in context: inout GraphicsContext) {
        let message: String?
        if game.phase == .crashed {
            message = "Game over — Space to run again"
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
