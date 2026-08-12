//
//  PearlRunnerPalette.swift
//  Cherry Browser
//
//  The four colours the runner's canvas is drawn with, and the measurement
//  that fixes them.
//
//  ## What was wrong
//
//  The field used to be `#F7F7F5` by day and `#17171F` by night, and neither
//  of those numbers knew anything about the appearance the browser was in. In
//  Dark Aqua the offline screen is a `#1E1E1E` page, so a fresh run put a
//  near-white slab on it — the paper measured **15.6:1** against the page it
//  was punched into, which is more contrast than the headline has.
//
//  ## Why Cherry does not do what Chrome does
//
//  Chrome's runner inverts: light field with dark ink by day, dark field with
//  light ink by night and in dark mode. It can, because its dino is ONE flat
//  ink — flip the field and flip the ink and every drawn thing follows.
//
//  Cherry's runner is a pixel-art sheet with baked colours, and the cast is
//  not one polarity. Measured off the shipped sheet — body colours, and their
//  WCAG 2.x relative luminance:
//
//      element              body colour   relative luminance
//      Pearl                #201813       0.010   ← near-black
//      cherry tree canopy   #2D4A2B       0.056
//      ground, lower        #8A6A42       0.161
//      ground, top edge     #C9A86A       0.415
//      gull                 #E8E8E0       0.803   ← near-white
//      moon, stars          #F2E2C4       0.766
//      cloud                #F4EFE2       0.865
//
//  A near-black cat and a near-white gull share every frame. There is no
//  field polarity that serves both: on the old paper field the gull — the one
//  obstacle you have to duck — measured 2.07:1 and the clouds 1.07:1, and on a
//  Chrome-style dark field Pearl herself collapses to 1.30:1 and the trees to
//  1.80:1. Inverting in dark mode would have swapped an invisible bird for an
//  invisible cat.
//
//  So the field is not the page's colour, light or dark. It is a **dusk tone
//  chosen for the artwork**, and it is the same tone in both appearances,
//  because the artwork is the same artwork in both appearances: Pearl does
//  not get lighter when macOS does. What follows the appearance is the frame
//  around the picture — `FailurePalette.surface` under it, the hairline round
//  it — exactly as it does for any other picture on any other page.
//
//  ## The band, and why it is narrow
//
//  Sweeping the field's luminance against the shipped sheet, with each
//  element measured on the 75th percentile of its outline band (the bar
//  `PearlContrastTests` already sets for artwork — see that file for why a
//  silhouette is measured at its edge), everything drawn clears WCAG 1.4.11's
//  3:1 only between **0.139 and 0.224**. Below it the cherry trees go first
//  and Pearl goes next; above it the moon goes first and the gull next. The
//  score is text rather than artwork, so it wants 4.5:1, and white ink — the
//  brightest ink there is — holds that only up to **0.183**. Three walls, one
//  window:
//
//      0.139  ──────────  0.183 ····· 0.224      the field is drawn in here
//        ↑                  ↑           ↑
//        trees stop         score       moon and gull
//        reading            stops       stop reading
//
//  `day` sits at 0.170 and `night` at 0.152, both inside it. Nightfall
//  therefore cannot be a big step in brightness any more — there is no room
//  for one — so it is carried by hue (an overcast blue-grey going to indigo)
//  and by the moon and stars the renderer already only draws after 700.
//
//  Every number above is re-measured against the shipped sheet and the
//  shipped colours by `PearlRunnerContrastTests`; nothing here is trusted
//  from this comment.
//

import SwiftUI

nonisolated enum PearlRunnerPalette {

    /// Daylight, hazy. 0.170 relative luminance.
    static let day = Color(.sRGB, red: 104 / 255, green: 116 / 255, blue: 127 / 255, opacity: 1)

    /// After 700 points: the same sky at dusk. 0.152.
    static let night = Color(.sRGB, red: 108 / 255, green: 106 / 255, blue: 132 / 255, opacity: 1)

    /// The field for a run, which is the only thing `isNight` still decides
    /// about colour — the ink no longer flips with it, because the field no
    /// longer crosses the middle.
    static func field(isNight: Bool) -> Color {
        isNight ? night : day
    }

    /// The score, the overlay line, and the bright half of the placeholder
    /// cast. White rather than the sheet's cream `#F2E2C4`: the cream measures
    /// 3.74:1 on the day field and the score is 11pt text, so the brightest
    /// ink available is the one the band's ceiling was solved for.
    static let ink = Color.white

    /// The dark half of the placeholder cast — Pearl and the trees, when the
    /// sheet is missing and the canvas falls back to flat rectangles. Pearl's
    /// own `#201813`, so a placeholder run is legible for exactly the reason a
    /// real one is, rather than being a light-on-dusk negative of it.
    static let silhouette = Color(.sRGB, red: 32 / 255, green: 24 / 255, blue: 19 / 255, opacity: 1)
}
