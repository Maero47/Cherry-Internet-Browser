//
//  ReaderModeExtractor.swift
//  Cherry Browser
//

import WebKit

struct ReaderContent {
    let title: String
    let byline: String?
    let content: String // HTML
    /// The page the article was extracted from.
    ///
    /// The extracted HTML keeps the article's markup verbatim, and real
    /// articles are full of RELATIVE `src` and `href` — `/img/hero.jpg`,
    /// `../figure-2.png`, `#footnote-3`. Rendered with no base URL those
    /// resolve against nothing: every relative image silently fails to load
    /// and every relative link goes nowhere. This is what the reader view
    /// resolves them against. See `ReaderWebView`.
    let sourceURL: URL?
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

        // Everything else that can execute or fetch, which the list above did
        // not cover. This matters more than it used to: the reader document now
        // renders against the article's own base URL, so anything left in here
        // resolves and runs somewhere real rather than nowhere. The reader view
        // ALSO turns JavaScript off outright and serves a `default-src 'none'`
        // CSP — this pass is the first of those three, not the only one.
        //
        //  * `<base>` would silently override the base URL the reader passes in;
        //  * `<link>`/`<meta>` can fetch and can redirect the document;
        //  * `<object>`/`<embed>`/`<svg>` script are script by another name;
        //  * `<noscript>`/`<template>` hide markup from this pass that the
        //    parser will happily bring back.
        clone.querySelectorAll('base, link, meta, object, embed, applet, noscript, template, svg script, svg use').forEach(function(el) { el.remove(); });

        // Inline handlers (`onerror`, `onclick`, …) and `javascript:` URLs are
        // script that survives having every <script> removed.
        var all = clone.querySelectorAll('*');
        for (var n = 0; n < all.length; n++) {
            var el = all[n];
            var attrs = el.attributes;
            for (var a = attrs.length - 1; a >= 0; a--) {
                var name = attrs[a].name.toLowerCase();
                var value = (attrs[a].value || '').replace(/[\\s\\u0000-\\u001f]/g, '').toLowerCase();
                if (name.indexOf('on') === 0) { el.removeAttribute(attrs[a].name); continue; }
                if ((name === 'href' || name === 'src' || name === 'xlink:href' ||
                     name === 'action' || name === 'formaction' || name === 'data') &&
                    (value.indexOf('javascript:') === 0 || value.indexOf('vbscript:') === 0)) {
                    el.removeAttribute(attrs[a].name);
                }
            }
        }

        return {
            title: title,
            byline: byline,
            content: clone.innerHTML
        };
    })();
    """;

    static func extract(from webView: WKWebView) async -> ReaderContent? {
        // Read on the main actor before awaiting: `WKWebView.url` is the page
        // the extraction ran against, and it is what every relative `src` and
        // `href` in the returned markup is relative TO.
        let sourceURL = await MainActor.run { webView.url }
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
                content: content,
                sourceURL: sourceURL
            )
        } catch {
            return nil
        }
    }
}
