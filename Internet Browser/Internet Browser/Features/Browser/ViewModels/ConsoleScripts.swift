//
//  ConsoleScripts.swift
//  Cherry Browser
//

import Foundation

enum ConsoleScripts {

    /// Injected at document start. Overrides console.log/info/warn/error
    /// and posts structured messages via the "cherryConsole" message handler.
    static let consoleInterceptScript = """
    (function() {
        if (window.__cherryConsoleInstalled) return;
        window.__cherryConsoleInstalled = true;

        var _handler = window.webkit
                         && window.webkit.messageHandlers
                         && window.webkit.messageHandlers.cherryConsole;
        if (!_handler) return;

        function serialize(args) {
            return Array.prototype.map.call(args, function(a) {
                if (a === null)      return 'null';
                if (a === undefined) return 'undefined';
                if (typeof a === 'object') {
                    try { return JSON.stringify(a); } catch(e) { return String(a); }
                }
                return String(a);
            }).join(' ');
        }

        ['log', 'info', 'warn', 'error'].forEach(function(level) {
            var original = console[level].bind(console);
            console[level] = function() {
                original.apply(console, arguments);
                try {
                    _handler.postMessage({ level: level, message: serialize(arguments) });
                } catch(e) {}
            };
        });
    })();
    """

    /// Registers a permissive TrustedTypePolicy named 'cherry-devtools' at document start,
    /// before the page's own scripts run.  The apply-HTML script then uses this policy
    /// to wrap arbitrary HTML into a TrustedHTML value that TT-enforcing sites accept.
    /// Falls back silently when TrustedTypes is not supported.
    static let devToolsPolicyScript = """
    (function(){
        if (!window.trustedTypes || !window.trustedTypes.createPolicy) return;
        try {
            window.__cherryDTP = window.trustedTypes.createPolicy('cherry-devtools', {
                createHTML:      function(s){ return s; },
                createScript:    function(s){ return s; },
                createScriptURL: function(s){ return s; }
            });
        } catch(e) {
            // CSP may restrict policy names — try the page's own default policy
            try { window.__cherryDTP = window.trustedTypes.defaultPolicy; } catch(e2) {}
        }
    })();
    """

    /// XHR + fetch interception — posts start/finish events via "cherryNetwork".
    static let networkInterceptScript = """
    (function() {
        if (window.__cherryNetworkInstalled) return;
        window.__cherryNetworkInstalled = true;

        var _handler = window.webkit
                         && window.webkit.messageHandlers
                         && window.webkit.messageHandlers.cherryNetwork;
        if (!_handler) return;

        // --- XMLHttpRequest ---
        var OrigXHR = window.XMLHttpRequest;
        function PatchedXHR() {
            var xhr = new OrigXHR();
            var method = 'GET', xhrURL = '', startTime;
            var origOpen = xhr.open.bind(xhr);
            xhr.open = function(m, u) { method = m; xhrURL = u; return origOpen.apply(xhr, arguments); };
            var origSend = xhr.send.bind(xhr);
            xhr.send = function() {
                startTime = Date.now();
                try { _handler.postMessage({ type: 'start', method: method.toUpperCase(), url: xhrURL }); } catch(e){}
                xhr.addEventListener('loadend', function() {
                    try {
                        _handler.postMessage({
                            type: 'finish', url: xhrURL,
                            status: xhr.status,
                            mimeType: xhr.getResponseHeader('Content-Type') || '',
                            elapsed: Date.now() - startTime
                        });
                    } catch(e){}
                });
                return origSend.apply(xhr, arguments);
            };
            return xhr;
        }
        PatchedXHR.prototype = OrigXHR.prototype;
        window.XMLHttpRequest = PatchedXHR;

        // --- fetch ---
        var origFetch = window.fetch.bind(window);
        window.fetch = function(input, init) {
            var url    = (typeof input === 'string') ? input : (input && input.url) || '';
            var method = (init && init.method) || (input && input.method) || 'GET';
            var start  = Date.now();
            try { _handler.postMessage({ type: 'start', method: method.toUpperCase(), url: url }); } catch(e){}
            return origFetch(input, init).then(function(resp) {
                try {
                    _handler.postMessage({
                        type: 'finish', url: url, status: resp.status,
                        mimeType: resp.headers.get('Content-Type') || '',
                        elapsed: Date.now() - start
                    });
                } catch(e){}
                return resp;
            }, function(err) {
                try { _handler.postMessage({ type: 'finish', url: url, status: 0, mimeType: '', elapsed: Date.now() - start }); } catch(e){}
                throw err;
            });
        };
    })();
    """
}
