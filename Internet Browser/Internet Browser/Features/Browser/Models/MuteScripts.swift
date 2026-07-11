//
//  MuteScripts.swift
//  Internet Browser
//

import Foundation

/// JS-based tab muting. WKWebView has no public audio-mute API on macOS, so we
/// mute by setting `.muted` on every <audio>/<video> element instead. The
/// install script is injected into EVERY frame (main + iframes) so that media
/// inside cross-origin embeds (YouTube/Vimeo players, video ads) is also muted
/// — `evaluateJavaScript` alone only reaches the main frame.
enum MuteScripts {

    /// Injected at documentStart into every frame. `muted` is baked in at
    /// registration so a freshly-loaded cross-origin iframe — which Swift
    /// cannot address with `evaluateJavaScript` — still applies the correct
    /// state on its own. It (1) mutes existing media immediately, (2) watches
    /// for media added later via a MutationObserver, and (3) re-enforces on
    /// `play`/`loadeddata` (capture phase) so media that starts after the tab
    /// was muted — including inside iframes — is caught without any cross-frame
    /// messaging. `window.__cherryApplyMute` lets Swift flip the main frame
    /// live without a reload.
    static func installScript(muted: Bool) -> String {
        """
        (function() {
            if (window.__cherryMuteInstalled) {
                if (window.__cherryApplyMute) { window.__cherryApplyMute(\(muted)); }
                return;
            }
            window.__cherryMuteInstalled = true;
            window.__cherryMuted = \(muted);

            function muteAll() {
                if (!window.__cherryMuted) return;
                document.querySelectorAll('audio, video').forEach(function(el) {
                    el.muted = true;
                });
            }

            window.__cherryApplyMute = function(m) {
                window.__cherryMuted = m;
                document.querySelectorAll('audio, video').forEach(function(el) {
                    el.muted = m;
                });
            };

            var observer = new MutationObserver(function(mutations) {
                if (!window.__cherryMuted) return;
                mutations.forEach(function(mut) {
                    mut.addedNodes.forEach(function(node) {
                        if (node.nodeType !== 1) return;
                        if (node.tagName === 'AUDIO' || node.tagName === 'VIDEO') {
                            node.muted = true;
                        }
                        if (node.querySelectorAll) {
                            node.querySelectorAll('audio, video').forEach(function(el) {
                                el.muted = true;
                            });
                        }
                    });
                });
            });

            function startObserver() {
                var root = document.documentElement || document.body;
                if (root) {
                    observer.observe(root, { childList: true, subtree: true });
                }
            }

            // Re-enforce whenever media starts (capture phase catches it before
            // audio is audible); covers iframe media that begins after muting.
            function enforce(e) {
                if (window.__cherryMuted && e.target && 'muted' in e.target) {
                    e.target.muted = true;
                }
            }
            document.addEventListener('play', enforce, true);
            document.addEventListener('loadeddata', enforce, true);

            startObserver();
            muteAll();
        })();
        """
    }

    /// Live-toggles mute on the current frame's page. Falls back to setting the
    /// flag directly if `installScript` hasn't run yet (e.g. about:blank).
    static func applyMuteJS(muted: Bool) -> String {
        """
        (function() {
            if (window.__cherryApplyMute) {
                window.__cherryApplyMute(\(muted));
            } else {
                window.__cherryMuted = \(muted);
            }
        })();
        """
    }
}
