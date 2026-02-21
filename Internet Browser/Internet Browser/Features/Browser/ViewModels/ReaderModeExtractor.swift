//
//  ReaderModeExtractor.swift
//  Cherry Browser
//

import WebKit

struct ReaderContent {
    let title: String
    let byline: String?
    let content: String // HTML
}

struct ReaderModeExtractor {
    /// JavaScript that extracts article content from the current page.
    /// Uses heuristics similar to Readability: finds the main content container
    /// by scoring elements based on paragraph density, class/id hints, etc.
    private static let extractionJS = """
    (function() {
        // Try to get article metadata
        var title = '';
        var byline = '';

        // Title: prefer og:title, then document title
        var ogTitle = document.querySelector('meta[property="og:title"]');
        title = ogTitle ? ogTitle.content : document.title;

        // Byline: look for common author patterns
        var authorMeta = document.querySelector('meta[name="author"]') ||
                         document.querySelector('meta[property="article:author"]');
        if (authorMeta) {
            byline = authorMeta.content;
        } else {
            var authorEl = document.querySelector('[class*="author"], [rel="author"], .byline, .post-author');
            if (authorEl) byline = authorEl.textContent.trim();
        }

        // Content extraction: find the best candidate element
        var candidates = document.querySelectorAll('article, [role="main"], .post-content, .article-body, .entry-content, .story-body, main');
        var best = null;
        var bestScore = 0;

        if (candidates.length > 0) {
            // Use the first semantic match
            best = candidates[0];
        }

        if (!best) {
            // Fallback: score divs/sections by paragraph count
            var elements = document.querySelectorAll('div, section');
            for (var i = 0; i < elements.length; i++) {
                var el = elements[i];
                var paragraphs = el.querySelectorAll('p');
                var score = paragraphs.length;

                // Boost for content-like class/id names
                var id = (el.id + ' ' + el.className).toLowerCase();
                if (/article|content|post|entry|story|text|body/.test(id)) score += 5;
                if (/comment|sidebar|nav|footer|header|menu|ad|widget/.test(id)) score -= 10;

                if (score > bestScore) {
                    bestScore = score;
                    best = el;
                }
            }
        }

        if (!best || best.textContent.trim().length < 200) {
            return null; // Not enough content for reader mode
        }

        // Clean the content: remove scripts, styles, nav, ads
        var clone = best.cloneNode(true);
        var removeSelectors = 'script, style, nav, footer, header, .ad, .ads, .sidebar, .comments, .social, .share, [role="navigation"], iframe, form';
        clone.querySelectorAll(removeSelectors).forEach(function(el) { el.remove(); });

        return {
            title: title,
            byline: byline,
            content: clone.innerHTML
        };
    })();
    """;

    static func extract(from webView: WKWebView) async -> ReaderContent? {
        do {
            let result = try await webView.evaluateJavaScript(extractionJS)
            guard let dict = result as? [String: Any],
                  let title = dict["title"] as? String,
                  let content = dict["content"] as? String else {
                return nil
            }
            let byline = dict["byline"] as? String
            return ReaderContent(
                title: title,
                byline: byline?.isEmpty == true ? nil : byline,
                content: content
            )
        } catch {
            return nil
        }
    }
}
