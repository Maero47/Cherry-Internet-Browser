//
//  ReaderModeView.swift
//  Cherry Browser
//

import SwiftUI
import WebKit

struct ReaderModeView: View {
    let content: ReaderContent
    let onDismiss: () -> Void
    /// A link the reader document tried to navigate to. Reader mode renders a
    /// snapshot, not a browsing context — following a link has to leave it and
    /// land in a real tab, which is the only place Cherry's per-site rules,
    /// history and chrome apply.
    var onOpenLink: ((URL) -> Void)? = nil

    @State private var fontSize: CGFloat = 18
    @State private var useSerif: Bool = true

    /// The document's content security policy, and the reason reader mode can
    /// afford a real base URL.
    ///
    /// With `baseURL: nil` the extracted markup resolved against nothing, so
    /// nothing it contained could load — the images were lost, and that was
    /// also, accidentally, the containment. Handing it the article's URL makes
    /// every relative reference resolve, which is the fix and also the new
    /// exposure. So the exposure is bounded explicitly rather than by accident:
    ///
    ///  * `default-src 'none'` — nothing loads unless named below. That covers
    ///    script, frames, workers, websockets, `<object>`, and form posts.
    ///  * `img-src` / `media-src` / `font-src` — what an article legitimately
    ///    is. `data:` for inline images, which are common in extracted markup.
    ///  * `style-src 'unsafe-inline'` — the reader's OWN stylesheet, which is
    ///    inline in this document. No external sheet can be pulled in.
    ///
    /// The requests this does permit go through the same `WKContentRuleList`
    /// set a normal page gets (see `ReaderWebView.makeNSView`), so a tracking
    /// pixel in an article is blocked here exactly as it is there.
    static let contentSecurityPolicy =
        "default-src 'none'; "
        + "img-src * data: blob:; "
        + "media-src * data: blob:; "
        + "font-src * data:; "
        + "style-src 'unsafe-inline'; "
        + "form-action 'none'; "
        + "base-uri 'none'"

    private var readerHTML: String {
        Self.document(for: content, fontSize: fontSize, useSerif: useSerif)
    }

    /// The reader document, assembled from extracted content. `static` and
    /// side-effect free so the containment above can be tested by loading the
    /// real document rather than by reading this file and believing it.
    static func document(
        for content: ReaderContent, fontSize: CGFloat, useSerif: Bool
    ) -> String {
        let fontFamily = useSerif ? "Georgia, 'Times New Roman', serif" : "-apple-system, Helvetica Neue, sans-serif"
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
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

    private static func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
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

            ReaderWebView(
                html: readerHTML,
                baseURL: content.sourceURL,
                onOpenLink: onOpenLink
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// Simple WKWebView wrapper for reader content
struct ReaderWebView: NSViewRepresentable {
    let html: String
    /// The article's own URL. Every relative `src` and `href` in the extracted
    /// markup resolves against this — which is the entire fix. With `nil` (an
    /// article extracted from a page with no URL) behaviour is what it always
    /// was: relative references resolve against nothing.
    let baseURL: URL?
    var onOpenLink: ((URL) -> Void)? = nil

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: Self.makeConfiguration())
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    /// The reader web view's configuration, split out so what it turns on and
    /// off can be asserted without building a SwiftUI representable context.
    static func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        // Reader mode renders extracted HTML, and that HTML keeps the article's
        // image URLs — absolute ones always, and relative ones now that there
        // is a base URL to resolve them against — so this web view does make
        // real third-party requests. It was the one birth path with no rule
        // lists at all.
        //
        // `pageURL: nil` is deliberate and is NOT an oversight now that a real
        // URL is available: nil means "protected" (`adBlockActive(for:)`), so
        // reader mode is always at least as blocked as the page it came from,
        // and a per-site ad-block pause — an opt-out the user made for a page
        // they were looking at — cannot follow them into reader mode.
        WebViewWrapper.applyContentRuleLists(to: config, pageURL: nil)
        // Always ephemeral. Reader mode has no use for persisted cookies or
        // storage, and this view is built without knowing whether the article
        // came from a private tab — it previously used the PERSISTENT store
        // even in a private window, which is a leak. An ephemeral store is
        // correct for both cases, so there is nothing to get wrong.
        config.websiteDataStore = .nonPersistent()
        // Reader mode is a static snapshot of prose. It has never needed
        // script, and with a base URL in place script would now run in the
        // article's own context rather than nowhere — so it is turned off at
        // the engine, underneath the extractor's sanitising pass and the
        // document's `default-src 'none'` CSP. Three independent layers,
        // because "the extractor strips every script tag" is a claim about a
        // regex over other people's HTML and this one is not.
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        return config
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onOpenLink = onOpenLink
        // This view has no coordinator observing `cherryContentRuleListsChanged`,
        // so re-derive here: every render reloads the article anyway, and a list
        // that finished compiling after the overlay opened then applies to that
        // reload rather than being missed until reader mode is reopened.
        WebViewWrapper.applyContentRuleLists(to: webView.configuration, pageURL: nil)
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onOpenLink: onOpenLink)
    }

    /// Reader mode's own navigation delegate — it has nothing to do with the
    /// page one (`WebViewWrapper.Coordinator`) and shares no state with it.
    ///
    /// It exists because the base URL turned links back on. Before, a relative
    /// `href` resolved against nothing and a click did nothing; now it
    /// resolves, and without this a click would navigate the READER's web view
    /// to a live site — an ephemeral, chrome-less, JavaScript-disabled window
    /// with no omnibox, no history, no per-site settings and no way back. That
    /// is not a browsing context and must not pretend to be one.
    final class Coordinator: NSObject, WKNavigationDelegate {
        var onOpenLink: ((URL) -> Void)?

        init(onOpenLink: ((URL) -> Void)?) {
            self.onOpenLink = onOpenLink
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // The reader's own `loadHTMLString` is the only navigation this
            // view performs; everything else came from the document.
            guard navigationAction.navigationType != .other else {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            guard let url = navigationAction.request.url,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else { return }
            onOpenLink?(url)
        }
    }
}
