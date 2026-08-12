//
//  PearlPetView.swift
//  Cherry Browser
//
//  Pearl, standing on the page.
//
//  ## Why this is an `NSView` and not a SwiftUI view
//
//  Everything decorative in Cherry is SwiftUI. This one thing is not, and the
//  reason is the promise at the top of the feature: **she must never steal a
//  click from the page.**
//
//  A SwiftUI overlay above a `WKWebView` is drawn by the hosting view, and
//  what it can express about hit-testing is a shape: a rectangle, a rounded
//  rectangle, a path. Pearl is a cat-shaped hole in a rectangle — the corners
//  of her frame are the page, and a click there is the page's click, including
//  the click that follows a link she is standing next to. The only honest way
//  to say that is per PIXEL, and per-pixel is what `hitTest(_:)` below does:
//  it reads the alpha of the exact sprite pixel under the pointer and returns
//  `nil` for everything else, which hands the event straight back to AppKit to
//  deliver to the web view underneath. Nothing is intercepted, nothing is
//  forwarded, nothing is re-synthesised — the event never reaches this view at
//  all.
//
//  That is also why the view is only as big as she is plus the room her hearts
//  need, rather than covering the page: AppKit rejects points outside a view's
//  frame before it ever calls `hitTest`, so for the whole page except one
//  small rectangle, Pearl costs a frame comparison in code that was going to
//  run anyway.
//
//  ## What is drawn, and how often
//
//  One `CALayer` whose `contents` is a `CGImage` sliced out of the shared
//  sprite sheet, magnified nearest-neighbour. A frame change is a `contents`
//  assignment — no `draw(_:)`, no `CGContext`, no rasterisation. The tick that
//  performs it runs at 10 Hz, computes the pose with the arithmetic in
//  `PearlPetMood`, and assigns only when the frame actually changed.
//
//  The hearts are `CAShapeLayer`s running a Core Animation keyframe, so once
//  they are handed to the render server the main thread does nothing at all
//  until they are removed.
//
//  ## Nothing outlives the window
//
//  The frame driver is the runner's (`PearlFrameTimerDriver`), whose timer is
//  invalidated both by `stop()` and by its own `deinit`. It is stopped when
//  the view leaves its window and started when it joins one, so a closed
//  window leaves nothing running — and `PearlPetLifecycleTests` is what keeps
//  that true.
//

import AppKit
import SwiftUI
import WebKit

@MainActor
final class PearlPetView: NSView {

    // MARK: - Wiring

    /// The browser this Pearl borrows her menu actions from. Weak: the view
    /// model owns the window that owns this view.
    weak var host: (any PearlPetHost)?

    /// Called when the user drags her, with her new position as a fraction of
    /// the usable width. The SwiftUI side owns where she is; this view only
    /// reports the gesture.
    var onMove: ((CGFloat) -> Void)?

    /// "Put Pearl Away" — the Settings switch, reachable from where she is.
    var onPutAway: (() -> Void)?

    /// What SwiftUI resolved for this view, not what AppKit thinks globally:
    /// the same reasoning as `PearlReactions.fire(_:reduceMotion:)`.
    var reduceMotion = false {
        didSet {
            guard reduceMotion != oldValue else { return }
            refresh()
            syncTicking()
        }
    }

    // MARK: - State

    private var mood: PearlPetMood
    private let sprites: PearlSpriteLibrary
    private let driver: any PearlFrameDriving
    private let clock: () -> TimeInterval

    private let spriteLayer = CALayer()
    private var shown: PearlPetAppearance?

    private var dragOrigin: CGPoint?
    private var dragStartPosition: CGFloat = 0
    private var didDrag = false

    /// The pane she is standing in, and where along its floor she is. Both are
    /// SwiftUI's to decide and are pushed in by `PearlPetOverlay`; the view
    /// keeps them only so a drag can be expressed in the same fraction the
    /// placement model uses.
    var contentSize: CGSize = .zero
    var position: CGFloat = PearlPetPlacement.defaultPosition

    /// One art pixel per point. The sheet is authored at 1x and drawn at 1x,
    /// so `hitTest`'s pixel lookup is a straight cast; a magnified pet would
    /// have to divide here and in `spriteRect`.
    private static let spriteScale: CGFloat = 1

    // MARK: - Life

    init(
        sprites: PearlSpriteLibrary = .shared,
        driver: (any PearlFrameDriving)? = nil,
        clock: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }
    ) {
        self.sprites = sprites
        // Not a default argument: those are evaluated in the caller's context,
        // which need not be the main actor this driver requires.
        self.driver = driver ?? PearlFrameTimerDriver(interval: PearlPetMood.tickInterval)
        self.clock = clock
        var mood = PearlPetMood()
        let now = clock()
        mood.lastDisturbed = now
        // Her loop starts somewhere of its own, so two windows do not blink in
        // unison.
        mood.phaseOffset = now.truncatingRemainder(dividingBy: PearlPetMood.idleLoop)
        self.mood = mood
        super.init(frame: .zero)

        wantsLayer = true
        layer?.masksToBounds = false
        spriteLayer.magnificationFilter = .nearest
        spriteLayer.minificationFilter = .nearest
        spriteLayer.contentsGravity = .resize
        spriteLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(spriteLayer)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Pearl")
        // Deliberately no `toolTip` and no cursor rect: both are rectangular,
        // and a tooltip that appears while the pointer is over the page beside
        // her ear is the same intrusion as a stolen click, in slow motion.
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            driver.stop()
            spriteLayer.removeAllAnimations()
        } else {
            keepAboveWebContent()
            syncTicking()
        }
    }

    /// Insurance, run once when she joins a window.
    ///
    /// SwiftUI puts an overlay's hosted view above the content's, which is
    /// what draws her over the page. If a future layout ever ends up with the
    /// two as siblings in the other order, she would be drawn behind the web
    /// view and simply never be seen — a silent failure with no test that can
    /// catch it, because verifying it needs pixels. One `sortSubviews`-free
    /// reorder at attach time costs nothing and removes the failure mode.
    private func keepAboveWebContent() {
        guard let superview,
              let index = superview.subviews.firstIndex(of: self),
              superview.subviews[(index + 1)...].contains(where: { $0 is WKWebView })
        else { return }
        removeFromSuperview()
        superview.addSubview(self, positioned: .above, relativeTo: nil)
    }

    // MARK: - Geometry

    /// Her sprite inside this view: at the bottom, centred, with the heart
    /// room above and either side of it.
    var spriteRect: CGRect {
        let size = spriteSize
        return CGRect(
            x: ((bounds.width - size.width) / 2).rounded(),
            y: 0,
            width: size.width,
            height: size.height
        )
    }

    private var spriteSize: CGSize {
        let logical = (shown?.pose ?? .sitting).logicalSize
        return CGSize(
            width: logical.width * Self.spriteScale,
            height: logical.height * Self.spriteScale
        )
    }

    override func layout() {
        super.layout()
        spriteLayer.frame = spriteRect
    }

    override var isOpaque: Bool { false }

    /// A window-dragging background would make picking her up move the whole
    /// window. She is a cat, not a title bar.
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: - The promise: only her own pixels

    /// `point` is in the superview's coordinates, the way AppKit asks.
    ///
    /// Returning `nil` is not "ignore this click": it is "there is no view
    /// here", which is what lets AppKit carry on down the stack and deliver
    /// the event to the web view. Everything transparent about her — the
    /// corners of her frame, the gaps between her ears, the whole heart
    /// headroom above her — is a hole in this view.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        return isOnPearl(local) ? self : nil
    }

    /// Whether a point in THIS view's coordinates lands on a pixel Pearl
    /// actually drew.
    func isOnPearl(_ point: CGPoint) -> Bool {
        let rect = spriteRect
        guard rect.contains(point) else { return false }
        guard let appearance = shown else { return false }

        let mask = sprites.alphaMask(appearance.pose.frameName, frame: appearance.frame)
        let logical = appearance.pose.logicalSize
        let width = Int(logical.width), height = Int(logical.height)
        guard !mask.isEmpty, mask.count == width * height else {
            // No mask means no sliced artwork: with nothing drawn there is
            // nothing to click, and the page keeps every click. Falling back
            // to "the whole rectangle is Pearl" would be the one failure mode
            // this whole file exists to prevent.
            return false
        }

        let x = Int((point.x - rect.minX) / Self.spriteScale)
        // Art rows run downwards; the view's y runs up from her feet.
        let y = height - 1 - Int((point.y - rect.minY) / Self.spriteScale)
        guard x >= 0, x < width, y >= 0, y < height else { return false }
        return mask[y * width + x] > 0
    }

    // MARK: - Being a cat

    private func syncTicking() {
        guard window != nil else {
            driver.stop()
            return
        }
        if mood.isStill(at: clock(), reduceMotion: reduceMotion) {
            driver.stop()
        } else if !driver.isRunning {
            driver.start { [weak self] in self?.tick() }
        }
    }

    private func tick() {
        refresh()
        // Under Reduce Motion the tick exists only to end a reaction; the
        // moment one is over there is nothing left to animate, so it stops.
        if reduceMotion, mood.isStill(at: clock(), reduceMotion: true) {
            driver.stop()
        }
    }

    /// Pulls the layer onto whatever the mood says the moment is. The early
    /// return is what makes a 10 Hz tick free: nine out of ten of them decide
    /// nothing changed and do nothing at all.
    private func refresh() {
        let appearance = mood.appearance(at: clock(), reduceMotion: reduceMotion)
        guard appearance != shown else { return }
        let poseChanged = appearance.pose != shown?.pose
        shown = appearance
        spriteLayer.contents = sprites.slice(appearance.pose.frameName, frame: appearance.frame)
        if poseChanged {
            spriteLayer.frame = spriteRect
        }
    }

    /// The current pose, for tests and for the hearts' launch point.
    var currentAppearance: PearlPetAppearance? { shown }

    /// Whether her tick is running. `PearlPetLifecycleTests` reads this.
    var isTicking: Bool { driver.isRunning }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            presentMenu()
            return
        }
        // WINDOW coordinates, not this view's: SwiftUI re-places this view
        // under the pointer as the drag moves her, so a local origin would be
        // chasing itself and she would stop dead after the first pixel.
        dragOrigin = event.locationInWindow
        dragStartPosition = position
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragOrigin else { return }
        let travelled = event.locationInWindow.x - dragOrigin.x
        if abs(travelled) > 2 { didDrag = true }
        guard didDrag else { return }
        mood.disturb(at: clock())
        // In fractions of her travel, never in window coordinates: this view's
        // own frame is moving underneath the drag as SwiftUI re-places it.
        let travel = PearlPetPlacement.travel(in: contentSize, spriteSize: spriteSize)
        guard travel > 0 else { return }
        onMove?(PearlPetPlacement.clampedPosition(dragStartPosition + travelled / travel))
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragOrigin = nil }
        guard dragOrigin != nil, !didDrag else { return }
        pet()
    }

    override func rightMouseDown(with event: NSEvent) {
        presentMenu()
    }

    /// AppKit routes a right click and a Control-click here; returning `nil`
    /// means "no `NSMenu`", because Cherry has already opened its own.
    override func menu(for event: NSEvent) -> NSMenu? {
        presentMenu()
        return nil
    }

    // MARK: - Reactions

    /// She was clicked.
    func pet() {
        mood.delight(at: clock())
        refresh()
        burstHearts()
        syncTicking()
    }

    /// She was given a fish.
    func feed() {
        mood.feed(at: clock())
        refresh()
        burstHearts()
        syncTicking()
    }

    // MARK: - The menu

    private func presentMenu() {
        // Captured NOW: the pointer is free to move while the page is asked
        // what is selected, and a menu that opens where the mouse ended up is
        // a menu that opens somewhere the user did not click.
        let origin = NSEvent.mouseLocation
        mood.disturb(at: clock())

        guard let host else { return }
        host.readPageSelection { [weak self] selection in
            self?.showMenu(at: origin, selection: selection)
        }
    }

    private func showMenu(at origin: CGPoint, selection: String?) {
        guard window != nil, let host else { return }

        var items: [CherryMenuItem] = [
            .action("Take a Screenshot", systemImage: "camera") {
                PearlPetMenu.takeScreenshot(host: host)
            }
        ]
        if let query = PearlPetMenu.query(from: selection) {
            items.append(
                .action(PearlPetMenu.searchTitle(for: query), systemImage: "magnifyingglass") {
                    PearlPetMenu.search(query, host: host)
                }
            )
        }
        items.append(
            .action("Give Pearl a Fish", systemImage: "fish") { [weak self] in
                self?.feed()
            }
        )
        items.append(.separator)
        items.append(
            .action("Put Pearl Away", systemImage: "moon.zzz") { [weak self] in
                self?.onPutAway?()
            }
        )

        CherryMenuController.shared.present(
            items,
            placement: .point(origin),
            parentWindow: window
        )
    }

    // MARK: - Hearts

    /// Three hearts, rising and gone in under a second — the same drawing the
    /// setup wizard's Pearl reacts with (`PearlHeartShape`), in the same tint,
    /// under the same rule about Reduce Motion (`PearlMascot.heartsMayFly`).
    ///
    /// Core Animation runs them, so the main thread's entire involvement is
    /// building three small layers.
    private func burstHearts() {
        guard PearlMascot.heartsMayFly(reduceMotion: reduceMotion) else { return }
        // Resolved against THIS window's appearance: her tint is a dynamic
        // colour, and a `CGColor` taken outside a drawing appearance resolves
        // against whatever was last current.
        var heartTint = PearlMascot.heartNSTint.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            heartTint = PearlMascot.heartNSTint.cgColor
        }
        let rect = spriteRect
        let launch = CGPoint(x: rect.midX, y: rect.maxY - 6)

        for (size, drift, delay, rise) in [
            (11.0, -13.0, 0.00, 30.0),
            (15.0, 2.0, 0.07, 37.0),
            (9.0, 12.0, 0.15, 27.0),
        ] {
            let heart = CAShapeLayer()
            let box = CGRect(x: 0, y: 0, width: size, height: size)
            heart.path = CGPath.pearlHeart(in: box)
            heart.fillColor = heartTint
            heart.bounds = box
            heart.position = launch
            heart.opacity = 0
            layer?.addSublayer(heart)

            let travel = CABasicAnimation(keyPath: "position.y")
            travel.fromValue = launch.y
            travel.toValue = launch.y + rise
            travel.beginTime = CACurrentMediaTime() + delay
            travel.duration = 0.71
            travel.timingFunction = CAMediaTimingFunction(name: .easeOut)
            travel.fillMode = .backwards

            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 1, 0]
            fade.keyTimes = [0, 0.14, 0.59, 1]
            fade.beginTime = CACurrentMediaTime() + delay
            fade.duration = 0.71
            fade.fillMode = .backwards

            let sidle = CABasicAnimation(keyPath: "position.x")
            sidle.fromValue = launch.x
            sidle.toValue = launch.x + drift
            sidle.beginTime = CACurrentMediaTime() + delay
            sidle.duration = 0.71
            sidle.fillMode = .backwards

            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak heart] in
                heart?.removeFromSuperlayer()
            }
            heart.add(travel, forKey: "rise")
            heart.add(fade, forKey: "fade")
            heart.add(sidle, forKey: "drift")
            CATransaction.commit()
        }
    }
}

// MARK: - The heart, as a path

extension CGPath {
    /// `PearlHeartShape`'s geometry, resolved for Core Animation. The shape is
    /// the single source of truth for what one of her hearts looks like; this
    /// is only the conversion, and `PearlPetHeartTests` pins the two together.
    static func pearlHeart(in rect: CGRect) -> CGPath {
        PearlHeartShape().path(in: rect).cgPath
    }

}

