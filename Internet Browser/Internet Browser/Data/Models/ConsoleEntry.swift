//
//  ConsoleEntry.swift
//  Cherry Browser
//

import Foundation
import SwiftUI

enum ConsoleLevel: String {
    case log    = "log"
    case info   = "info"
    case warn   = "warn"
    case error  = "error"
    case repl   = "repl"    // REPL input command (▶)
    case result = "result"  // REPL evaluation result (◀)

    /// Levels shown in the filter pills — excludes REPL variants
    static let filterCases: [ConsoleLevel] = [.log, .info, .warn, .error]

    var color: Color {
        switch self {
        case .log:    return .primary
        case .info:   return .blue
        case .warn:   return Color(nsColor: .systemOrange)
        case .error:  return .red
        case .repl:   return Color(nsColor: .systemPurple)
        case .result: return Color(nsColor: .systemIndigo)
        }
    }

    var icon: String {
        switch self {
        case .log:    return "chevron.right"
        case .info:   return "info.circle"
        case .warn:   return "exclamationmark.triangle"
        case .error:  return "xmark.octagon"
        case .repl:   return "arrow.right.circle"
        case .result: return "arrow.left.circle"
        }
    }
}

struct ConsoleEntry: Identifiable {
    let id: UUID
    let timestamp: Date
    let level: ConsoleLevel
    let message: String
    /// Tab (and therefore pane/window) this entry originated from, so split
    /// panes and separate windows can each show only their own tab's log.
    let tabID: UUID

    init(level: ConsoleLevel, message: String, tabID: UUID) {
        self.id        = UUID()
        self.timestamp = Date()
        self.level     = level
        self.message   = message
        self.tabID     = tabID
    }

    var timestampString: String {
        let cal = Calendar.current
        let c   = cal.dateComponents([.hour, .minute, .second, .nanosecond], from: timestamp)
        let ms  = (c.nanosecond ?? 0) / 1_000_000
        return String(format: "%02d:%02d:%02d.%03d",
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0, ms)
    }
}
