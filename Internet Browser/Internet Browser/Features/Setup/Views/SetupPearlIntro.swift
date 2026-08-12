//
//  SetupPearlIntro.swift
//  Cherry Browser
//
//  Pearl arriving on a setup step: large, once, with a speech bubble that says
//  what the step is for in her own voice — and then out of the way.
//
//  ## What changed, and why it is a rework rather than a bubble bolted on
//
//  She used to live in the wizard's footer at 34pt for the whole run. That is
//  a resident, and a resident stops being looked at somewhere around the
//  second screen: by the third question she was a small dark shape beside a
//  sentence about Settings. Worse, being down there is what made her hearts
//  invisible — see `PearlHeartBurst` for the AppKit reason.
//
//  So her presence is now an EVENT. She is not on the step; she arrives at it,
//  says one thing, and leaves the step to the person answering it. Her arc
//  through the sheet is unchanged in shape and louder in every frame of it:
//
//      welcome     she IS the page — waving, introducing herself.
//      questions   she arrives at the top of each one, 120pt, with a bubble
//                  that explains that question and nothing else.
//      last step   the same arrival, delighted, and her bubble is the goodbye.
//
//  ## The three rules she is held to
//
//  1. **She never delays anybody.** The bubble is in the layout flow above the
//     step, not over it; nothing in the intro is hit-testable except the one
//     control that dismisses it; and the step's own cards are live and
//     complete on the same frame she lands on. Skipping her is one click and
//     it collapses the strip.
//  2. **Once per step.** `PearlIntroDirector` spends a step's appearance when
//     the user skips her OR when they leave the step. Back and forward again
//     does not summon her a second time — an arrival that repeats is not an
//     arrival, it is the footer with extra steps.
//  3. **Reduce Motion gets the words, not the show.** Every animated value
//     here is a pure function of `(landed, reduceMotion)`, and with Reduce
//     Motion on those functions return the SETTLED value at `landed == false`
//     — so she is simply there, at full opacity, saying her piece, before
//     anything has had a chance to animate.
//

import SwiftUI

// MARK: - What she says

/// The five bubbles.
///
/// This is the copy, and the copy is the point. Each one has to explain its
/// step in her voice — not describe the controls, which the cards already do,
/// and not narrate the wizard, which the progress rule already does. The test
/// of a line is reading it aloud: if it could appear under a heading in a
/// preferences pane with nobody noticing, it is help text and it is wrong.
///
/// This is also why the question steps no longer carry a masthead subtitle.
/// Those subtitles were exactly the help text this replaces ("Light or dark,
/// the colour it tints, and what sits behind your homepage"), and running them
/// three inches above her saying the same thing better would make the sheet
/// read as a form with a cat stapled to it.
enum PearlIntroScript {

    struct Arrival {
        /// Which drawing of her arrives. `.sitting` is her front-on, talking
        /// pose; the last step gets `.delighted` because that arrival is also
        /// the sign-off.
        let pose: PearlMascot.Pose
        let line: String
    }

    /// Exhaustive over `SetupWizardStep` on purpose: a new step does not
    /// compile until somebody has decided whether she speaks on it and what
    /// she says.
    static func arrival(on step: SetupWizardStep) -> Arrival? {
        switch step {
        case .welcome:
            // She is already the whole page here, at 196pt, saying her name.
            // A speech bubble on top of that is her talking over herself.
            return nil

        case .appearance:
            return Arrival(pose: .sitting, line: """
                Let's start with the part you'll be looking at all day. Light or dark, a colour \
                that's yours, and something behind the homepage that isn't grey — I'm partial to \
                the dark.
                """)

        case .searchPrivacy:
            return Arrival(pose: .sitting, line: """
                Two things that follow you onto every page: who answers when you type a question, \
                and how much of you the page gets to keep. Blocking is already on — I'd leave it there.
                """)

        case .importData:
            return Arrival(pose: .sitting, line: """
                If you've been using something else, I'll go and get your bookmarks and history so \
                you're not starting from nothing. It's all read off this Mac, and none of it leaves.
                """)

        case .extensions:
            return Arrival(pose: .sitting, line: """
                These three I've actually watched working in here, warts and all — the small print \
                under each one is the warts. Tick what you want; nothing installs on its own.
                """)

        case .tabLayout:
            return Arrival(pose: .delighted, line: """
                Last one, and it's only a shape: tabs across the top, or down the side. Then I'll \
                leave you to it — though if your connection ever drops, come and find me on the \
                offline page, and I'll race you.
                """)
        }
    }

    /// Every step she speaks on, in flow order. Used by the tests, and by
    /// nothing else — the wizard asks per step.
    @MainActor
    static var steps: [SetupWizardStep] {
        SetupWizardModel.steps.filter { arrival(on: $0) != nil }
    }
}

// MARK: - Once per step

/// Which steps Pearl has already had her one appearance on.
///
/// Its own object rather than state on `SetupWizardModel`, for the same reason
/// `PearlReactions` is: that model is pinned by a reflection test to hold
/// navigation and nothing else. "Has the cat spoken here yet" is not
/// navigation.
///
/// The spend is deliberately on LEAVING and not on arriving. Marking a step
/// spent the instant she lands would mean a re-render could take her away
/// mid-sentence; spending it when the user moves on (or skips her) means she
/// is present for exactly as long as the user is on the step, and never again.
@MainActor
@Observable
final class PearlIntroDirector {

    private(set) var spent: Set<SetupWizardStep> = []

    /// Whether she is on this step right now. `false` for steps she has no
    /// line for at all, so callers never have to ask twice.
    func isPresent(on step: SetupWizardStep) -> Bool {
        PearlIntroScript.arrival(on: step) != nil && !spent.contains(step)
    }

    /// The user dismissed her, or navigated off the step. Either way that
    /// step's one appearance is over.
    func spend(_ step: SetupWizardStep) {
        spent.insert(step)
    }
}

// MARK: - How she lands

/// The arrival, as arithmetic.
///
/// Pure functions rather than modifiers written inline, because the Reduce
/// Motion promise — "she appears without the animation, the bubble still says
/// its piece" — is a claim about VALUES, and a claim about values can be
/// tested without rendering anything. With Reduce Motion on, every one of
/// these returns the settled result even before `landed` flips, so there is no
/// frame in which she is transparent, offset or small.
enum PearlArrival {

    /// How far below her resting place she starts. Small: she rises into
    /// position, she does not fly in from off-screen.
    static let travel: CGFloat = 24

    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.74)
    }

    static func offset(landed: Bool, reduceMotion: Bool) -> CGFloat {
        (landed || reduceMotion) ? 0 : travel
    }

    static func opacity(landed: Bool, reduceMotion: Bool) -> Double {
        (landed || reduceMotion) ? 1 : 0
    }

    static func scale(landed: Bool, reduceMotion: Bool) -> CGFloat {
        (landed || reduceMotion) ? 1 : 0.94
    }
}

// MARK: - The bubble

/// A rounded plate with a tail pointing back at her.
///
/// The tail is the entire reason this is not a `SettingsCard`: same fill, same
/// hairline, same corner language as every other plate in the wizard, and one
/// triangle that turns it from a container into somebody talking.
struct PearlSpeechBubbleShape: Shape {
    /// How far the tail sticks out of the plate's leading edge.
    static let tail: CGFloat = 9
    static let corner: CGFloat = 13

    func path(in rect: CGRect) -> Path {
        let plate = CGRect(x: rect.minX + Self.tail, y: rect.minY,
                           width: max(0, rect.width - Self.tail), height: rect.height)
        var path = Path(roundedRect: plate, cornerRadius: Self.corner, style: .continuous)

        // Pointed at her upper body rather than her feet, and clamped so a
        // short bubble does not grow a tail out of its own rounded corner.
        let spread: CGFloat = 9
        let y = min(max(rect.minY + rect.height * 0.40, rect.minY + Self.corner + spread),
                    rect.maxY - Self.corner - spread)
        path.move(to: CGPoint(x: rect.minX, y: y))
        path.addLine(to: CGPoint(x: plate.minX + 1, y: y - spread))
        path.addLine(to: CGPoint(x: plate.minX + 1, y: y + spread))
        path.closeSubpath()
        return path
    }
}

/// What she says, and the one control that stops her saying it.
///
/// Her line is `.primary` and not `SetupPalette.supporting`: the supporting
/// tone exists for the interface's own asides, and this is not an aside, it is
/// the only voice on the screen. `PearlBubbleContrastTests` measures it on the
/// bubble's fill in both appearances rather than assuming a label colour on a
/// control fill is safe.
struct PearlSpeechBubble: View {
    let line: String
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(line)
                .font(SetupType.body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                // She is a character speaking, so VoiceOver is told who is
                // speaking. Without this the line arrives as an unattributed
                // sentence floating above the question.
                .accessibilityLabel("Pearl says: \(line)")

            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Button("Got it") { onSkip() }
                    .controlSize(.small)
                    .accessibilityLabel("Got it — dismiss Pearl's note")
            }
        }
        .padding(.leading, PearlSpeechBubbleShape.tail + 15)
        .padding(.trailing, 15)
        .padding(.vertical, 13)
        .background {
            PearlSpeechBubbleShape()
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
        }
        .overlay {
            PearlSpeechBubbleShape()
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }
}

// MARK: - The arrival

/// Pearl, big, beside what she has to say about this step.
///
/// The "Got it" button is the ONLY control in here — there is no tap-anywhere
/// gesture, no swipe, no hover target, and Pearl herself is explicitly
/// non-hit-testable and hidden from VoiceOver. That is the mechanical half of
/// "she must not delay the user": one discoverable way out, and nothing else
/// in the strip that can swallow a click or announce itself on the way to the
/// question.
struct PearlIntro: View {
    let arrival: PearlIntroScript.Arrival
    /// `PearlReactions.pulse` — her hearts, contained inside her own frame.
    let pulse: Int
    let reduceMotion: Bool
    let onSkip: () -> Void

    @State private var landed = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            PearlPortrait(
                pose: arrival.pose,
                height: PearlMascot.introHeight,
                label: "Pearl",
                pulse: pulse
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            PearlSpeechBubble(line: arrival.line, onSkip: onSkip)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .offset(y: PearlArrival.offset(landed: landed, reduceMotion: reduceMotion))
        .opacity(PearlArrival.opacity(landed: landed, reduceMotion: reduceMotion))
        .scaleEffect(PearlArrival.scale(landed: landed, reduceMotion: reduceMotion),
                     anchor: .bottomLeading)
        .onAppear {
            guard !reduceMotion else {
                landed = true
                return
            }
            withAnimation(PearlArrival.animation(reduceMotion: false)) { landed = true }
        }
    }
}
