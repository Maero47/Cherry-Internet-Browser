//
//  PageZoom.swift
//  Cherry Browser
//

import Foundation

/// The page-zoom ladder behind View ▸ Zoom In / Zoom Out / Actual Size.
/// Pure arithmetic, kept out of the view model so it's testable without a
/// `WKWebView`.
enum PageZoom {
    /// 100%.
    static let defaultLevel: Double = 1.0

    /// Chrome's zoom ladder, 25% → 500%.
    static let levels: [Double] = [
        0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9,
        1.0,
        1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0, 5.0
    ]

    /// The next level above (`direction > 0`) or below (`direction < 0`)
    /// `current`. Clamped at both ends, so holding ⌘+ at 500% is a no-op rather
    /// than an unreadable page. A `current` that isn't exactly on the ladder
    /// (a pinch-zoomed page) snaps to the neighbouring step in that direction.
    static func step(from current: Double, direction: Int) -> Double {
        guard direction != 0 else { return current }

        if direction > 0 {
            // First level strictly greater than current, else stay at the top.
            return levels.first { $0 > current + epsilon } ?? levels[levels.count - 1]
        } else {
            return levels.last { $0 < current - epsilon } ?? levels[0]
        }
    }

    /// Guards against floating-point drift making an exact level compare as
    /// "greater than itself".
    private static let epsilon = 0.0001
}
