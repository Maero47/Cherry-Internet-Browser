//
//  PageAIExtractor.swift
//  Cherry Browser
//

import WebKit

struct ExtractedPageContent {
    let title: String
    let text: String
}

/// Extracts the readable, plain-text content of a page for use as Foundation
/// Models input. Mirrors `ReaderModeExtractor`'s main-content heuristic (score
/// candidate containers by paragraph density / class-name hints) but returns
/// normalized plain text instead of HTML, since that's what gets fed to the
/// model's prompt.
struct PageAIExtractor {
    private static let extractionJS = """
    (function() {
        var title = '';
        var ogTitle = document.querySelector('meta[property="og:title"]');
        title = ogTitle ? ogTitle.content : document.title;

        var candidates = document.querySelectorAll('article, [role="main"], .post-content, .article-body, .entry-content, .story-body, main');
        var best = candidates.length > 0 ? candidates[0] : null;

        if (!best) {
            var elements = document.querySelectorAll('div, section');
            var bestScore = 0;
            for (var i = 0; i < elements.length; i++) {
                var el = elements[i];
                var paragraphs = el.querySelectorAll('p');
                var score = paragraphs.length;

                var id = (el.id + ' ' + el.className).toLowerCase();
                if (/article|content|post|entry|story|text|body/.test(id)) score += 5;
                if (/comment|sidebar|nav|footer|header|menu|ad|widget/.test(id)) score -= 10;

                if (score > bestScore) {
                    bestScore = score;
                    best = el;
                }
            }
        }

        if (!best) best = document.body;
        if (!best) return null;

        var clone = best.cloneNode(true);
        var removeSelectors = 'script, style, nav, footer, header, .ad, .ads, .sidebar, .comments, .social, .share, [role="navigation"], iframe, form, noscript';
        clone.querySelectorAll(removeSelectors).forEach(function(el) { el.remove(); });

        // innerText needs layout, which a detached clone doesn't have, so
        // stage it off-screen long enough to read innerText, then discard it.
        // This gives real paragraph/line breaks instead of the run-on text
        // that clone.textContent alone would produce.
        var stage = document.createElement('div');
        stage.style.cssText = 'position:absolute; left:-99999px; top:0; visibility:hidden;';
        stage.appendChild(clone);
        document.body.appendChild(stage);
        var text = clone.innerText || clone.textContent || '';
        document.body.removeChild(stage);

        text = text.replace(/[ \\t]+/g, ' ').replace(/\\n[ \\t]*\\n+/g, '\\n\\n').trim();

        if (text.length < 40) return null;

        return { title: title, text: text };
    })();
    """

    static func extract(from webView: WKWebView) async -> ExtractedPageContent? {
        do {
            let result = try await webView.evaluateJavaScript(extractionJS)
            guard let dict = result as? [String: Any],
                  let title = dict["title"] as? String,
                  let text = dict["text"] as? String,
                  !text.isEmpty else {
                return nil
            }
            return ExtractedPageContent(title: title, text: text)
        } catch {
            return nil
        }
    }
}
