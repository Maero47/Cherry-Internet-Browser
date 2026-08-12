//
//  SetupWizardChrome.swift
//  Cherry Browser
//
//  The wizard's type scale, its spacing, its masthead and its progress rule —
//  the parts that decide whether the setup screens look designed or assembled.
//
//  ## What was wrong
//
//  Every step had the same anatomy: an accent-tinted rounded square with an
//  SF Symbol in it, a 17pt bold title beside it, a 12pt grey line under that,
//  then a stack of cards fourteen points apart. Nothing on any step was the
//  most important thing on it, because everything was the same weight as
//  everything else. Across the sheet there were eight type sizes — 24, 17,
//  13, 12.5, 12, 11.5, 11, 10 — most of them within a point of a neighbour,
//  which is the same as having one size and a lot of noise. And the spacing
//  was 14 everywhere, so a card's relationship to the title above it looked
//  exactly like its relationship to the card below it.
//
//  ## What this is instead
//
//  FOUR sizes, far enough apart to be recognisable as roles rather than as
//  accidents, with the weight doing the work the size used to be asked to do:
//
//      30 semibold   the welcome, once
//      21 semibold   the question this step asks
//      13 regular    prose
//      11 regular    the quiet line
//      11 semibold   the counter — uppercase and letterspaced
//
//  That last pair is the whole discipline in miniature. The counter wants to
//  be smaller than the quiet line; the honest way to get there is NOT to draw
//  it at 10pt, because 10 beside 11 is not a smaller size, it is the same size
//  rendered slightly wrong — which is precisely how the old screens ended up
//  with 12.5 next to 12 next to 11.5. It is the same 11pt, made unmistakable
//  by weight, case and tracking instead.
//
//  The two prose sizes match `SettingsCard` exactly (13/11), because the cards
//  are shared with the Settings pane and the wizard is supposed to look like
//  the same product, not a questionnaire standing in front of it.
//
//  Spacing is no longer uniform: things that belong together are 4–7pt apart,
//  the break between the masthead and the controls is 20, and cards inside
//  one step sit 10 apart because they ARE one group.
//
//  The icon tile is gone. A coloured rounded square with a symbol in it, next
//  to a bold title and a grey subtitle, is the single most recognisable shape
//  in machine-made interface design, and it was doing nothing here that the
//  question itself does not do better.
//

import SwiftUI

// MARK: - Type

/// The wizard's five type roles, over four sizes. Named for what they ARE, so
/// a new screen picks a role rather than a number — and so the count of sizes
/// stays four, which `SetupTypographyTests` holds.
enum SetupType {
    /// The welcome, and nothing else in the wizard.
    static let welcome = Font.system(size: 30, weight: .semibold)
    /// The question a step asks. One per step.
    static let question = Font.system(size: 21, weight: .semibold)
    /// Prose: the welcome paragraph, a step's subtitle, Pearl's sign-off.
    static let body = Font.system(size: 13)
    /// The quiet line — the footer note, a status, an aside.
    static let aside = Font.system(size: 11)
    /// The step counter: the aside's size, separated by weight, uppercase and
    /// tracking rather than by a point of height. Never coloured.
    static let counter = Font.system(size: 11, weight: .semibold)
}

/// The wizard's spacing, in one place so the rhythm can be read at a glance
/// instead of being reconstructed from thirty call sites.
enum SetupMetrics {
    /// Content inset. Asymmetric on purpose: a step needs more air above the
    /// question than below the last card, and more at the sides than a
    /// settings pane does, because the sheet is narrow and the question is
    /// long.
    static let contentTop: CGFloat = 26
    static let contentSides: CGFloat = 32
    static let contentBottom: CGFloat = 22

    /// Inside the masthead — tight, because these three lines are one thing.
    static let counterToQuestion: CGFloat = 7
    static let questionToSubtitle: CGFloat = 3

    /// Masthead to the controls. The one real gap on the page.
    static let mastheadToControls: CGFloat = 20

    /// Between cards within a step. Closer than the gap above them, because
    /// they belong to each other more than they belong to the question.
    static let betweenCards: CGFloat = 10
}

// MARK: - Tone

/// The wizard's own greys, and why they are not `.secondary`.
///
/// `.secondary` is 50% black over whatever is behind it. Measured against the
/// sheet's own material (`NSColor.windowBackgroundColor`, #ECECEC in Aqua)
/// that lands at about **3.6:1** — under the 4.5:1 floor for text this size —
/// and `.tertiary`, which the step counter would naturally have taken, is far
/// worse again. The library screens met exactly this and answered it exactly
/// this way (`LibraryPalette`): stop fading text out, and carry hierarchy with
/// size, weight and position instead.
///
/// One tone, measured on both surfaces the wizard draws text on — the sheet
/// material and a card's fill — in both appearances:
///
///     supporting  #5C5C5C / #A8A8A8      sheet 5.40:1 / 5.96:1
///                                        card  6.69:1 / 7.77:1
///
/// `SetupTypographyContrastTests` re-measures these against the live system
/// colours rather than trusting the table.
enum SetupPalette {
    static let supporting = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.659, green: 0.659, blue: 0.659, alpha: 1)
            : NSColor(srgbRed: 0.361, green: 0.361, blue: 0.361, alpha: 1)
    })
}

// MARK: - The masthead

/// The counter and the question.
///
/// The counter says "QUESTION 3 OF 5" and not "STEP 4 OF 6" because the
/// welcome is not a question — it is Pearl saying hello — and counting it
/// makes the number disagree with the sentence on the welcome page that
/// promises five. It is never the accent: at 10pt semibold it is small text,
/// small text needs 4.5:1, and Cherry's accent palette runs to yellows that
/// cannot give it. The colour on this screen is spent on the progress rule and
/// the controls, where it means something.
///
/// ## Where the subtitle went
///
/// Every step used to carry a grey line under the question saying what the
/// step was about — "Light or dark, the colour it tints, and what sits behind
/// your homepage". Pearl now arrives at the top of the same step and says the
/// same thing better, in her own voice (`PearlIntroScript`), so the grey line
/// was the sheet saying everything twice with the second telling being the
/// duller one. It is gone; `subtitle` survives as an optional for any step
/// that ever needs a caveat Pearl should not be the one delivering.
struct SetupStepMasthead: View {
    /// 1-based, over the questions only.
    let number: Int
    let total: Int
    let question: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Question \(number) of \(total)")
                .font(SetupType.counter)
                .tracking(1.1)
                .textCase(.uppercase)
                .foregroundStyle(SetupPalette.supporting)
                .accessibilityHidden(true)

            Text(question)
                .font(SetupType.question)
                .padding(.top, SetupMetrics.counterToQuestion)

            if let subtitle {
                Text(subtitle)
                    .font(SetupType.body)
                    .foregroundStyle(SetupPalette.supporting)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, SetupMetrics.questionToSubtitle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // One element to VoiceOver, in the order it is read on screen; the
        // counter is folded in here rather than announced separately.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Question \(number) of \(total). \(question)")
        .accessibilityValue(subtitle ?? "")
    }
}

// MARK: - Progress

/// A hairline across the top of the sheet that fills as the wizard advances.
///
/// This replaces six grey dots. The dots were 6pt circles that could not show
/// how far through you were without being counted, sat in the footer competing
/// with three buttons, and were the sort of element that gets added rather
/// than designed. A rule at the very top edge is read without being looked at,
/// costs 3pt of a 560pt sheet, and is the one place the accent is allowed to
/// be loud.
///
/// It animates only when motion is allowed; under Reduce Motion it simply is
/// where it is on each step, which is the honest still frame of the same fact.
struct SetupProgressRule: View {
    /// 0 on the welcome, 1 on the last step.
    let fraction: Double
    let reduceMotion: Bool

    private var accent: Color { SettingsManager.shared.accentColor }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.primary.opacity(0.07))
                Capsule()
                    .fill(accent)
                    .frame(width: max(0, geo.size.width * fraction))
            }
        }
        .frame(height: 3)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.34), value: fraction)
        .accessibilityHidden(true)
    }
}
