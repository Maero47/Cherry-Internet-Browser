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

        var MIN = 200;
        function normalize(t) {
            return (t || '').replace(/[ \\t]+/g, ' ').replace(/\\n[ \\t]*\\n+/g, '\\n\\n').trim();
        }

        // Pick the semantic container with the MOST live rendered text (not just
        // the first match) — sites often have several main/role=main shells.
        var candidates = Array.prototype.slice.call(document.querySelectorAll(
            'article, [role="main"], main, .post-content, .article-body, .entry-content, .story-body'
        ));
        if (candidates.length === 0) {
            var scored = document.querySelectorAll('div, section');
            var bestScore = 0, scoredBest = null;
            for (var i = 0; i < scored.length; i++) {
                var el = scored[i];
                var score = el.querySelectorAll('p').length;
                var id = (el.id + ' ' + el.className).toLowerCase();
                if (/article|content|post|entry|story|text|body/.test(id)) score += 5;
                if (/comment|sidebar|nav|footer|header|menu|ad|widget/.test(id)) score -= 10;
                if (score > bestScore) { bestScore = score; scoredBest = el; }
            }
            if (scoredBest) candidates.push(scoredBest);
        }

        // Rank by textContent, not innerText: innerText needs a live render
        // tree (it's '' for anything WebKit hasn't laid out — background
        // tabs, mid-load reads), while textContent is layout-independent, so
        // a real container still wins even when nothing has rendered yet.
        var best = null, bestLen = -1;
        candidates.forEach(function(el) {
            var len = (el.textContent || '').length;
            if (len > bestLen) { bestLen = len; best = el; }
        });

        // Preferred path: a cloned, stripped copy staged off-screen so nav/ads
        // are removed and innerText has real line breaks. But cloneNode() drops
        // shadow-DOM / custom-element content, so on Web-Component SPAs
        // (YouTube, etc.) this yields near-nothing.
        var text = '';
        if (best) {
            var clone = best.cloneNode(true);
            clone.querySelectorAll('script, style, nav, footer, header, .ad, .ads, .sidebar, .comments, .social, .share, [role="navigation"], iframe, form, noscript').forEach(function(el) { el.remove(); });
            var stage = document.createElement('div');
            stage.style.cssText = 'position:absolute; left:-99999px; top:0; visibility:hidden;';
            stage.appendChild(clone);
            document.body.appendChild(stage);
            text = normalize(clone.innerText || clone.textContent || '');
            document.body.removeChild(stage);
        }

        // Fallback for SPAs where the clone lost the content: read LIVE innerText
        // (reflects rendered text, including shadow DOM), first from the chosen
        // container, then from the whole page — whichever gives more.
        if (text.length < MIN) {
            var liveBest = best ? normalize(best.innerText) : '';
            if (liveBest.length > text.length) text = liveBest;
        }
        if (text.length < MIN && document.body) {
            var liveBody = normalize(document.body.innerText);
            if (liveBody.length > text.length) text = liveBody;
        }

        // Layout-independent last resort: every read above except the clone's
        // textContent branch depends on innerText, which is '' without a
        // render tree. Strip the obvious non-content and take the body's raw
        // textContent rather than returning null on an unrendered page.
        if (text.length < MIN && document.body) {
            var bodyClone = document.body.cloneNode(true);
            bodyClone.querySelectorAll('script, style, noscript').forEach(function(el) { el.remove(); });
            var bodyText = normalize(bodyClone.textContent);
            if (bodyText.length > text.length) text = bodyText;
        }

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
