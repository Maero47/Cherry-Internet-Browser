//
//  PageAIExtractor.swift
//  Cherry Browser
//

import WebKit

/// Where the extracted text came from: which branch of the fallback chain won, and
/// whether the element it came from was actually being laid out.
///
/// ## Why the branch alone is not the answer
///
/// The obvious reading — "`innerText` means displayed, `textContent` means raw" —
/// is wrong twice, and both were measured rather than assumed:
///
/// * `innerText` silently degrades. Per the HTML spec, an element that is not
///   being rendered returns its `textContent` from `innerText`. On a page whose
///   only bulk text sits in a `display:none` panel, that panel's `innerText` and
///   `textContent` are both 1,320 characters — so an `innerText` branch can hand
///   back content the user has never seen and look like the safe path.
/// * The preferred branch reads `textContent` almost always. The stripped clone is
///   staged inside a `visibility: hidden` wrapper, and WebKit returns '' for
///   `innerText` there, so the clone path falls to `clone.textContent` even on a
///   fully rendered article. Classifying that as "raw" would mark essentially every
///   read as untrustworthy, which tells a caller nothing.
///
/// So the prefix reports the fact that actually varies and is actually checkable:
/// whether the source element had layout boxes (`getClientRects().length > 0`). On
/// the hidden-panel page that is 0; on a rendered article it is 1. `raw_` therefore
/// means "this text came from DOM that is not being displayed at all", which is a
/// claim a caller can act on.
///
/// What it does NOT claim: that every character of a `rendered_` result was visible.
/// A displayed container read via `textContent` still includes its own hidden
/// descendants. That caveat belongs in the tool description, and it is there.
nonisolated enum PageTextSource: String {
    /// Stripped clone of the chosen container, which is being rendered.
    case renderedClone = "rendered_clone"
    /// Stripped clone of a container that is NOT being rendered.
    case rawClone = "raw_clone"
    /// The chosen container's live text (SPA / shadow-DOM fallback), rendered.
    case renderedContainer = "rendered_container"
    /// …and the same fallback on a container that is not being rendered.
    case rawContainer = "raw_container"
    /// The whole body's live text, body rendered.
    case renderedBody = "rendered_body"
    /// The body's `textContent`: either the layout-independent last resort, or a
    /// body that is not being rendered at all.
    case rawBody = "raw_body"

    /// Whether the element this text came from was being laid out.
    var isSourceDisplayed: Bool {
        switch self {
        case .renderedClone, .renderedContainer, .renderedBody: true
        case .rawClone, .rawContainer, .rawBody: false
        }
    }
}

struct ExtractedPageContent {
    let title: String
    let text: String

    /// Which branch produced `text`, when the extractor reported one.
    ///
    /// Defaulted so callers that do not care are unaffected.
    let source: PageTextSource?

    init(title: String, text: String, source: PageTextSource? = nil) {
        self.title = title
        self.text = text
        self.source = source
    }
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

        // Rank by innerText where it's available (rendered pages: it reflects
        // VISIBLE text, so nav/script/hidden blobs don't inflate a container's
        // score — the long-standing displayed-page behavior), falling back to
        // textContent when innerText is empty. innerText needs a live render
        // tree (it's '' for anything WebKit hasn't laid out — background tabs,
        // mid-load reads), while textContent is layout-independent, so a real
        // container still wins even when nothing has rendered yet.
        var best = null, bestLen = -1;
        candidates.forEach(function(el) {
            var len = (el.innerText || '').length || (el.textContent || '').length;
            if (len > bestLen) { bestLen = len; best = el; }
        });

        // Preferred path: a cloned, stripped copy staged off-screen so nav/ads
        // are removed and innerText has real line breaks. But cloneNode() drops
        // shadow-DOM / custom-element content, so on Web-Component SPAs
        // (YouTube, etc.) this yields near-nothing.
        // `source` records which branch below won AND whether the element the text
        // came from was actually being laid out, so a caller can tell text taken
        // from a displayed container from text scraped out of DOM that is not on
        // screen at all. `innerText` alone cannot say: the spec makes it fall back
        // to textContent for an unrendered element, so it reports hidden panels
        // while looking like the safe path.
        function isDisplayed(el) {
            try { return !!(el && el.getClientRects().length > 0); } catch (e) { return false; }
        }
        function label(el, branch) {
            return (isDisplayed(el) ? 'rendered_' : 'raw_') + branch;
        }

        var text = '';
        var source = null;
        if (best) {
            var clone = best.cloneNode(true);
            clone.querySelectorAll('script, style, nav, footer, header, .ad, .ads, .sidebar, .comments, .social, .share, [role="navigation"], iframe, form, noscript').forEach(function(el) { el.remove(); });
            var stage = document.createElement('div');
            stage.style.cssText = 'position:absolute; left:-99999px; top:0; visibility:hidden;';
            stage.appendChild(clone);
            document.body.appendChild(stage);
            text = normalize(clone.innerText || clone.textContent || '');
            if (text.length > 0) source = label(best, 'clone');
            document.body.removeChild(stage);
        }

        // Fallback for SPAs where the clone lost the content: read LIVE innerText
        // (reflects rendered text, including shadow DOM), first from the chosen
        // container, then from the whole page — whichever gives more.
        if (text.length < MIN) {
            var liveBest = best ? normalize(best.innerText) : '';
            if (liveBest.length > text.length) { text = liveBest; source = label(best, 'container'); }
        }
        if (text.length < MIN && document.body) {
            var liveBody = normalize(document.body.innerText);
            if (liveBody.length > text.length) { text = liveBody; source = label(document.body, 'body'); }
        }

        // Layout-independent last resort: every read above except the clone's
        // textContent branch depends on innerText, which is '' without a
        // render tree. Strip the obvious non-content and take the body's raw
        // textContent rather than returning null on an unrendered page.
        //
        // Always `raw_body`: this branch is reached precisely because nothing was
        // laid out, so calling it displayed would be a lie whatever the body's
        // client rects say.
        if (text.length < MIN && document.body) {
            var bodyClone = document.body.cloneNode(true);
            bodyClone.querySelectorAll('script, style, noscript').forEach(function(el) { el.remove(); });
            var bodyText = normalize(bodyClone.textContent);
            if (bodyText.length > text.length) { text = bodyText; source = 'raw_body'; }
        }

        if (text.length < 40) return null;

        return { title: title, text: text, source: source };
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
            return ExtractedPageContent(
                title: title,
                text: text,
                source: (dict["source"] as? String).flatMap(PageTextSource.init(rawValue:))
            )
        } catch {
            return nil
        }
    }
}
