//
//  NetworkEntry.swift
//  Cherry Browser
//

import Foundation
import SwiftUI

struct NetworkEntry: Identifiable {
    let id: UUID
    let timestamp: Date
    let url: String
    let method: String
    var statusCode: Int?
    var responseTimeMs: Double?
    var mimeType: String?
    var isError: Bool
    /// Tab (and therefore pane/window) this request originated from, so split
    /// panes and separate windows can each show only their own tab's traffic.
    let tabID: UUID

    init(url: String, method: String, tabID: UUID) {
        self.id             = UUID()
        self.timestamp      = Date()
        self.url            = url
        self.method         = method
        self.statusCode     = nil
        self.responseTimeMs = nil
        self.mimeType       = nil
        self.isError        = false
        self.tabID          = tabID
    }

    var displayURL: String {
        guard let u = URL(string: url) else { return url }
        let host = u.host ?? ""
        let path = u.path.isEmpty ? "/" : u.path
        let full = host + path
        return full.count > 80 ? String(full.prefix(77)) + "…" : full
    }

    var statusColor: Color {
        guard let code = statusCode else { return .secondary }
        switch code {
        case 200..<300: return .green
        case 300..<400: return Color(nsColor: .systemOrange)
        case 400..<600: return .red
        default:        return .secondary
        }
    }

    var methodColor: Color {
        switch method.uppercased() {
        case "GET":    return .blue
        case "POST":   return .green
        case "PUT":    return Color(nsColor: .systemOrange)
        case "DELETE": return .red
        default:       return .secondary
        }
    }
}
