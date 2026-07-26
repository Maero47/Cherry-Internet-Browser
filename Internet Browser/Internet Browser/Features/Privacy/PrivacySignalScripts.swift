//
//  PrivacySignalScripts.swift
//  Cherry Browser
//

import Foundation

/// The Global Privacy Control signal.
///
/// Replaces a "Send Do Not Track Header" toggle that had **zero readers** — no
/// header was ever sent, the setting was a promise the browser did not keep.
/// WKWebView gives an embedder no way to add a request header to every page
/// load, so the header form of DNT/GPC is not implementable here. The JS
/// surface is: `navigator.globalPrivacyControl` is what the GPC spec asks a
/// user agent to expose, and unlike DNT it carries legal weight under the CCPA
/// and several other privacy regimes — sites in scope must honour it.
///
/// `navigator.doNotTrack` is set alongside it so the older signal is at least
/// truthful for the scripts that still read it.
enum PrivacySignalScripts {

    /// Injected at document start into every frame, so a signal is present
    /// before any page or third-party script gets to look for one.
    static let globalPrivacyControlScript = """
    (function() {
        'use strict';
        try {
            Object.defineProperty(navigator, 'globalPrivacyControl', {
                value: true,
                configurable: false,
                enumerable: true,
                writable: false
            });
        } catch (e) {}
        try {
            Object.defineProperty(navigator, 'doNotTrack', {
                value: '1',
                configurable: false,
                enumerable: true,
                writable: false
            });
        } catch (e) {}
    })();
    """
}
