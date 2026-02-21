//
//  ReaderModeView.swift
//  Cherry Browser
//

import SwiftUI
import WebKit

struct ReaderModeView: View {
    let content: ReaderContent
    let onDismiss: () -> Void

    @State private var fontSize: CGFloat = 18
    @State private var useSerif: Bool = true

    private var readerHTML: String {
        let fontFamily = useSerif ? "Georgia, 'Times New Roman', serif" : "-apple-system, Helvetica Neue, sans-serif"
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body {
                font-family: \(fontFamily);
                font-size: \(Int(fontSize))px;
                line-height: 1.7;
                color: #333;
                background: #fafafa;
                padding: 40px 20px;
                max-width: 700px;
                margin: 0 auto;
            }
            @media (prefers-color-scheme: dark) {
                body { color: #ddd; background: #1a1a1a; }
                a { color: #6cb4ee; }
            }
            h1 { font-size: 1.8em; line-height: 1.3; margin-bottom: 8px; }
            .byline { color: #888; font-size: 0.85em; margin-bottom: 24px; }
            p { margin-bottom: 1em; }
            img { max-width: 100%; height: auto; border-radius: 4px; margin: 16px 0; }
            blockquote { border-left: 3px solid #ccc; padding-left: 16px; margin: 16px 0; color: #666; }
            pre, code { font-size: 0.9em; background: #f0f0f0; padding: 2px 4px; border-radius: 3px; }
            @media (prefers-color-scheme: dark) {
                pre, code { background: #2a2a2a; }
                blockquote { border-color: #555; color: #999; }
            }
            pre { padding: 12px; overflow-x: auto; }
            pre code { background: none; padding: 0; }
        </style>
        </head>
        <body>
            <h1>\(escapeHTML(content.title))</h1>
            \(content.byline.map { "<p class='byline'>\(escapeHTML($0))</p>" } ?? "")
            \(content.content)
        </body>
        </html>
        """
    }

    var body: some View {
        VStack(spacing: 0) {
            // Reader toolbar
            HStack {
                Button(action: onDismiss) {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark")
                        Text("Exit Reader")
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderless)

                Spacer()

                HStack(spacing: 12) {
                    Button(action: { fontSize = max(12, fontSize - 2) }) {
                        Text("A-")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.borderless)

                    Text("\(Int(fontSize))px")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)

                    Button(action: { fontSize = min(28, fontSize + 2) }) {
                        Text("A+")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.borderless)

                    Divider().frame(height: 16)

                    Button(action: { useSerif.toggle() }) {
                        Text(useSerif ? "Serif" : "Sans")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.regularMaterial)

            Divider()

            ReaderWebView(html: readerHTML)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// Simple WKWebView wrapper for reader content
struct ReaderWebView: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(html, baseURL: nil)
    }
}
