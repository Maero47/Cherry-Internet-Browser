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
//  Her SIZE costs nothing here. A 3x Pearl is the same 36x40 image in a
//  108x120 layer with `magnificationFilter = .nearest` — the magnification is
//  the GPU's, done once per composite, and every art pixel lands on a whole
//  3x3 block of points because the multiple is a whole number
//  (`PearlPetSize`). The only place the scale appears in code at all is
//  `isOnPearl`, which divides by it to find the art pixel under the pointer.
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
//  The same door handles the two `NSApplication` observations she carries
//  (`didResignActive` / `didBecomeActive`, which are how she knows you have
//  gone away): registered when she joins a window, removed when she leaves it,
//  and removed again in `deinit` for the case where she is dropped without
//  ever having been in one.
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

    /// Called when the user drags her or sends her home, with her new spot as
    /// fractions of her travel. The SwiftUI side owns where she is; this view
    /// only reports the gesture.
    var onMove: ((PearlPetSpot) -> Void)?

    /// Called when the user picks a size off her menu. Same arrangement: the
    /// SwiftUI side owns it and writes it down, this view only asks.
    var onResize: ((PearlPetSize) -> Void)?

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
    private var dragStartSpot = PearlPetSpot.home
    private var didDrag = false

    /// True only while `pageBehind(at:)` is asking the view stack who is under
    /// the pointer with her taken out of it. See `scrollWheel`.
    private var isPassingThrough = false

    /// The number of finished downloads she has already reacted to. Compared
    /// rather than counted, so a Pearl built into a window that has seen ten
    /// downloads does not celebrate ten times on arrival.
    private var noticedDownloads: Int?

    /// The pane she is standing in and where in it she is. Both are SwiftUI's
    /// to decide and are pushed in by `PearlPetOverlay`; the view keeps them
    /// only so a drag can be expressed in the same fractions the placement
    /// model uses.
    var contentSize: CGSize = .zero
    var spot = PearlPetSpot.home

    /// How big she is drawn. Changing it re-lays the layer immediately rather
    /// than waiting for the next tick, because a size change is a thing the
    /// user just chose off a menu and there may be no next tick at all (she
    /// may be asleep, dozing, or under Reduce Motion).
    var size: PearlPetSize = .default {
        didSet {
            guard size != oldValue else { return }
            spriteLayer.frame = spriteRect
        }
    }

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

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            driver.stop()
            spriteLayer.removeAllAnimations()
            NotificationCenter.default.removeObserver(self)
        } else {
            keepAboveWebContent()
            watchTheApp()
            syncTicking()
        }
    }

    /// The two notifications behind "she dozes when you leave Cherry".
    ///
    /// Notifications rather than a poll of `NSApp.isActive`: there is no tick
    /// to poll from once she has stopped, which is the entire point of
    /// stopping. Registered here and torn down on the way out of the window,
    /// so an off Pearl is an absent Pearl — no observer, no timer, no residue.
    private func watchTheApp() {
        let centre = NotificationCenter.default
        centre.removeObserver(self)
        centre.addObserver(
            self, selector: #selector(appWentAway),
            name: NSApplication.didResignActiveNotification, object: nil
        )
        centre.addObserver(
            self, selector: #selector(appCameBack),
            name: NSApplication.didBecomeActiveNotification, object: nil
        )
    }

    @objc private func appWentAway() {
        mood.doze()
        refresh()
        syncTicking()
    }

    @objc private func appCameBack() {
        guard mood.isDozing else { return }
        mood.disturb(at: clock())
        refresh()
        syncTicking()
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
        size.spriteSize(for: shown?.pose ?? .sitting)
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
        guard !isHidden, !isPassingThrough else { return nil }
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

        // The only division by her scale in the whole feature: the layer is
        // magnified by the GPU, so this is what turns a point on a 3x cat back
        // into the art pixel that was drawn there.
        let x = Int((point.x - rect.minX) / size.scale)
        // Art rows run downwards; the view's y runs up from her feet.
        let y = height - 1 - Int((point.y - rect.minY) / size.scale)
        guard x >= 0, x < width, y >= 0, y < height else { return false }
        return mask[y * width + x] > 0
    }

    /// The view a mouse event at this window point would have reached if she
    /// were not standing there — normally the page.
    ///
    /// Asked by taking herself out of the answer for the length of one
    /// `hitTest` rather than by looking for a `WKWebView` among her siblings:
    /// the pane's subview stack is SwiftUI's to arrange, and a rule that names
    /// a class is a rule that goes quietly wrong the day the page is wrapped
    /// in something.
    func pageBehind(at windowPoint: CGPoint) -> NSView? {
        guard let superview else { return nil }
        isPassingThrough = true
        defer { isPassingThrough = false }
        let found = superview.hitTest(superview.convert(windowPoint, from: nil))
        return found === self ? nil : found
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

    /// Picking her up.
    ///
    /// The page never sees any of this: AppKit delivered the `mouseDown` here
    /// because the pointer was on one of her own pixels, and every event of
    /// the drag that follows goes to the view that took the `mouseDown`. So a
    /// drag that starts on Pearl cannot start a text selection underneath her,
    /// and there is nothing to suppress — the page is simply not part of the
    /// gesture.
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            presentMenu()
            return
        }
        // WINDOW coordinates, not this view's: SwiftUI re-places this view
        // under the pointer as the drag moves her, so a local origin would be
        // chasing itself and she would stop dead after the first pixel.
        dragOrigin = event.locationInWindow
        dragStartSpot = spot
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragOrigin else { return }
        let travelled = CGSize(
            width: event.locationInWindow.x - dragOrigin.x,
            height: event.locationInWindow.y - dragOrigin.y
        )
        if abs(travelled.width) > 2 || abs(travelled.height) > 2 { didDrag = true }
        guard didDrag else { return }
        mood.disturb(at: clock())
        // In fractions of her travel, never in window coordinates: this view's
        // own frame is moving underneath the drag as SwiftUI re-places it.
        onMove?(
            PearlPetPlacement.spot(
                draggedFrom: dragStartSpot, by: travelled, in: contentSize, size: size
            )
        )
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragOrigin = nil }
        guard dragOrigin != nil, !didDrag else { return }
        pet()
    }

    /// A wheel event that lands on her belongs to the page.
    ///
    /// AppKit routes scrolling by hit test, so without this she would be a
    /// hole in the page's scrolling — a small one at 1x, nine times the area
    /// at 3x, and the same broken promise as a stolen click either way. The
    /// event is handed to whatever was behind her unmodified; nothing is
    /// re-synthesised and nothing is consumed.
    override func scrollWheel(with event: NSEvent) {
        guard let page = pageBehind(at: event.locationInWindow) else {
            super.scrollWheel(with: event)
            return
        }
        page.scrollWheel(with: event)
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

    /// The browser has finished this many downloads. She looks up at the ones
    /// she has not seen yet — once, whatever the jump — and no hearts: hearts
    /// are for affection, and a finished download is news.
    ///
    /// This is the whole of "she reacts to the browser". It is a comparison of
    /// two integers on a value SwiftUI already had, so there is no observer,
    /// no timer, no notification and nothing that runs when nothing is
    /// happening. Under Reduce Motion it does nothing at all: the fish is a
    /// reply to something the user asked for, this is not.
    func noticeDownloads(_ finished: Int) {
        defer { noticedDownloads = finished }
        // The first value she is ever handed is the state of the world when
        // she arrived, not news.
        guard let seen = noticedDownloads, finished > seen, !reduceMotion else { return }
        mood.notice(at: clock())
        refresh()
        syncTicking()
    }

    /// Send her back to her corner. The menu's way out of a bad parking spot;
    /// the placement model owns where "home" is.
    func sendHome() {
        mood.disturb(at: clock())
        spot = .home
        onMove?(.home)
        refresh()
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
        CherryMenuController.shared.present(
            menuItems(selection: selection, host: host),
            placement: .point(origin),
            parentWindow: window
        )
    }

    /// Her menu, as rows. Built apart from presenting it so
    /// `PearlPetMenuTests` can read what is on it and run what it does — a
    /// menu that is only ever handed to a controller is a menu no test can
    /// open.
    func menuItems(selection: String?, host: any PearlPetHost) -> [CherryMenuItem] {
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
            .submenu("Pearl's Size", systemImage: "arrow.up.left.and.arrow.down.right") {
                PearlPetSize.allCases.map { choice -> CherryMenuItem in
                    CherryMenuItem.action(choice.title, on: choice == size) { [weak self] in
                        self?.resize(to: choice)
                    }
                }
            }
        )
        items.append(
            // Disabled rather than absent when she is already there: the row
            // is the answer to "how do I undo this", and a row that vanishes
            // once you no longer need it is a row you cannot learn.
            .action("Send Pearl Home", systemImage: "arrow.uturn.backward",
                    enabled: !spot.isHome) { [weak self] in
                self?.sendHome()
            }
        )
        items.append(.separator)
        items.append(
            .action("Put Pearl Away", systemImage: "moon.zzz") { [weak self] in
                self?.onPutAway?()
            }
        )
        return items
    }

    /// A size off her menu: applied here so she changes under the pointer, and
    /// reported so the SwiftUI side can re-place her view and write it down.
    func resize(to size: PearlPetSize) {
        guard size != self.size else { return }
        mood.disturb(at: clock())
        self.size = size
        onResize?(size)
        refresh()
        syncTicking()
    }

    // MARK: - Hearts

    /// Three hearts, rising and gone in under a second — the same drawing the
    /// setup wizard's Pearl reacts with (`PearlHeartShape`), in the same tint,
    /// under the same rule about Reduce Motion (`PearlMascot.heartsMayFly`),
    /// and — see `PearlPetBurst` — the same three hearts.
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

        for flight in PearlPetBurst.flights(span: bounds.height, centreX: spriteRect.midX) {
            let heart = CAShapeLayer()
            let box = CGRect(x: 0, y: 0, width: flight.size, height: flight.size)
            heart.path = CGPath.pearlHeart(in: box)
            heart.fillColor = heartTint
            heart.bounds = box
            heart.position = flight.start
            heart.opacity = 0
            layer?.addSublayer(heart)

            let duration = PearlHeartBurst.travelDuration

            let travel = CABasicAnimation(keyPath: "position.y")
            travel.fromValue = flight.start.y
            travel.toValue = flight.end.y
            travel.beginTime = CACurrentMediaTime() + flight.delay
            travel.duration = duration
            travel.timingFunction = CAMediaTimingFunction(name: .easeOut)
            travel.fillMode = .backwards

            // The same shape as the wizard's opacity track, whose four
            // segments are 0, 0.10, 0.32 and 0.29 of the same 0.71 seconds.
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 1, 0]
            fade.keyTimes = [0, 0.14, 0.59, 1]
            fade.beginTime = CACurrentMediaTime() + flight.delay
            fade.duration = duration
            fade.fillMode = .backwards

            let sidle = CABasicAnimation(keyPath: "position.x")
            sidle.fromValue = flight.start.x
            sidle.toValue = flight.end.x
            sidle.beginTime = CACurrentMediaTime() + flight.delay
            sidle.duration = duration
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

// MARK: - The burst, in the pet's own coordinates

/// `PearlHeartBurst`'s three hearts, resolved for Core Animation.
///
/// Pearl reacts in two places and in two technologies, and the wizard's file
/// is where the burst is described: three hearts, each a `size`, a `rise` and
/// a `drift` given as FRACTIONS OF A SPAN, plus a stagger. That is not a
/// stylistic choice over there — it is the fix for a burst that painted its
/// whole ascent outside the thing it was drawn over and was never once seen.
///
/// The pet used to carry those numbers again, in points, and they were the
/// points the wizard's own file had by then replaced. So this reads the one
/// table instead. The only thing the pet decides is the SPAN, and it decides
/// it the same way `PearlPortrait` does: the span is the height of the frame
/// the burst must not leave, which here is `PearlPetView`'s own bounds — her
/// sprite plus `PearlPetPlacement.heartHeadroom`. Containment is then the same
/// arithmetic in both places, and `PearlPetHeartTests` checks it here the way
/// `PearlHeartContainmentTests` checks it there.
enum PearlPetBurst {

    /// One heart's flight, in the pet view's coordinates: y counts UP from her
    /// feet, where `PearlHeartBurst.origin` counts down from the top.
    struct Flight: Equatable {
        /// The side of the heart.
        let size: CGFloat
        /// Its centre when it appears.
        let start: CGPoint
        /// Its centre at the top of the rise.
        let end: CGPoint
        /// Its stagger, in seconds — the one thing in the table measured in a
        /// unit, and taken from the table all the same.
        let delay: Double
    }

    static func flights(span: CGFloat, centreX: CGFloat) -> [Flight] {
        let launchY = span * (1 - PearlHeartBurst.origin)
        return PearlHeartBurst.hearts.map { heart in
            let start = CGPoint(x: centreX, y: launchY)
            return Flight(
                size: span * heart.size,
                start: start,
                end: CGPoint(x: start.x + span * heart.drift, y: start.y + span * heart.rise),
                delay: heart.delay
            )
        }
    }

    /// Everything the burst paints, as one rectangle. The pet's answer to
    /// `PearlHeartBurst.paintedBand`, and what a test can hold against the
    /// view's own bounds.
    static func paintedRect(span: CGFloat, centreX: CGFloat) -> CGRect {
        flights(span: span, centreX: centreX).reduce(CGRect.null) { union, flight in
            let half = flight.size / 2
            return union
                .union(CGRect(x: flight.start.x - half, y: flight.start.y - half,
                              width: flight.size, height: flight.size))
                .union(CGRect(x: flight.end.x - half, y: flight.end.y - half,
                              width: flight.size, height: flight.size))
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

