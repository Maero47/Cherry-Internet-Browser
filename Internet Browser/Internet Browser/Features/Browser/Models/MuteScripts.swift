//
//  MuteScripts.swift
//  Internet Browser
//

import Foundation

/// JS-based tab muting. WKWebView has no public audio-mute API on macOS, so we
/// mute by setting `.muted` on every <audio>/<video> element instead.
enum MuteScripts {

    /// Installed once per navigation (WKUserScript re-injects on every page
    /// load). Sets up a MutationObserver so media elements added after load
    /// pick up the current mute state, and exposes `window.__cherryApplyMute`
    /// so Swift can flip the live state via evaluateJavaScript without a reload.
    static let installScript = """
    (function() {
        if (window.__cherryMuteInstalled) return;
        window.__cherryMuteInstalled = true;
        window.__cherryMuted = false;

        function muteAll(muted) {
            document.querySelectorAll('audio, video').forEach(function(el) {
                el.muted = muted;
            });
        }

        window.__cherryApplyMute = function(muted) {
            window.__cherryMuted = muted;
            muteAll(muted);
        };

        var observer = new MutationObserver(function(mutations) {
            if (!window.__cherryMuted) return;
            mutations.forEach(function(m) {
                m.addedNodes.forEach(function(node) {
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

        var root = document.documentElement || document.body;
        if (root) {
            observer.observe(root, { childList: true, subtree: true });
        }
    })();
    """

    /// Live-toggles mute on the currently loaded page. Falls back to setting
    /// the flag directly if `installScript` hasn't run yet (e.g. about:blank).
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
