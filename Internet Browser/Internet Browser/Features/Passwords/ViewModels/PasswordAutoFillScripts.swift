//
//  PasswordAutoFillScripts.swift
//  Cherry Browser
//

import Foundation

enum PasswordAutoFillScripts {

    // MARK: - Form Detection Script

    /// Injected at document end to detect login forms on the page.
    /// Handles SPAs (React, Angular, Vue) where login forms appear dynamically
    /// long after page load — e.g. Footlocker, Nike, etc.
    static let formDetectionScript = """
    (function() {
        if (window.__cherryPasswordDetectInstalled) return;
        window.__cherryPasswordDetectInstalled = true;

        var alreadyDetected = false;

        function detectLoginForm() {
            var passwordFields = document.querySelectorAll('input[type="password"]');
            if (passwordFields.length === 0) return;

            // Only check for visible password fields
            var visible = false;
            for (var i = 0; i < passwordFields.length; i++) {
                if (passwordFields[i].offsetParent !== null || passwordFields[i].getClientRects().length > 0) {
                    visible = true;
                    break;
                }
            }
            if (!visible) return;

            if (alreadyDetected) return;
            alreadyDetected = true;

            window.webkit.messageHandlers.cherryPasswordDetect.postMessage({
                type: 'loginFormDetected',
                forms: [{ hasPassword: true }],
                url: window.location.href
            });
        }

        // 1. Check immediately and after short delays for server-rendered pages
        detectLoginForm();
        setTimeout(detectLoginForm, 500);
        setTimeout(detectLoginForm, 1500);

        // 2. MutationObserver for dynamically added forms (SPAs)
        //    Keep observing indefinitely — SPAs can show login modals at any time
        var debounceTimer = null;
        var observer = new MutationObserver(function() {
            if (alreadyDetected) return;
            clearTimeout(debounceTimer);
            debounceTimer = setTimeout(detectLoginForm, 200);
        });
        if (document.body) {
            observer.observe(document.body, { childList: true, subtree: true, attributes: true, attributeFilter: ['type'] });
        }

        // 3. Listen for focus on password fields — catches cases where the field
        //    exists but was hidden and becomes visible (modals, tab switches, etc.)
        document.addEventListener('focusin', function(e) {
            if (e.target && e.target.tagName === 'INPUT' && e.target.type === 'password') {
                alreadyDetected = false; // allow re-detection
                detectLoginForm();
            }
        }, true);

        // 4. Periodic check every 3 seconds for 2 minutes — catches everything else
        //    (lazy-loaded iframes, delayed renders, SPAs with slow navigation)
        var checks = 0;
        var interval = setInterval(function() {
            checks++;
            if (checks > 40) { // 40 * 3s = 2 minutes
                clearInterval(interval);
                return;
            }
            if (!alreadyDetected) {
                detectLoginForm();
            }
        }, 3000);
    })();
    """

    // MARK: - Auto-Fill Script

    /// Executed on demand to fill username and password fields.
    /// Escape a value for embedding in a single-quoted JS string literal.
    /// \r and the U+2028/U+2029 line separators terminate JS string literals
    /// just like \n — leaving them raw makes the whole script fail to parse,
    /// so autofill would silently do nothing for such passwords.
    private static func escapeForJSString(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    static func autoFillScript(username: String, password: String) -> String {
        let escapedUsername = escapeForJSString(username)
        let escapedPassword = escapeForJSString(password)

        return """
        (function() {
            function fillField(field, value) {
                if (!field) return;
                // Focus the field first (some sites listen for focus)
                field.focus();
                var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
                nativeSetter.call(field, value);
                field.dispatchEvent(new Event('input', { bubbles: true }));
                field.dispatchEvent(new Event('change', { bubbles: true }));
                field.dispatchEvent(new KeyboardEvent('keydown', { bubbles: true }));
                field.dispatchEvent(new KeyboardEvent('keyup', { bubbles: true }));
            }

            // Find visible password field
            var passwordFields = document.querySelectorAll('input[type="password"]');
            var pwField = null;
            for (var i = 0; i < passwordFields.length; i++) {
                if (passwordFields[i].offsetParent !== null || passwordFields[i].getClientRects().length > 0) {
                    pwField = passwordFields[i];
                    break;
                }
            }
            if (!pwField) return false;

            // Find username/email field: search form, then parent containers, then whole page
            var containers = [
                pwField.closest('form'),
                pwField.closest('[class*="login"], [class*="signin"], [class*="auth"], [id*="login"], [id*="signin"], [class*="account"], [class*="credential"], [class*="sign-in"], [class*="log-in"]'),
                pwField.parentElement && pwField.parentElement.parentElement && pwField.parentElement.parentElement.parentElement,
                document.body
            ].filter(Boolean);

            var usernameSelectors = 'input[type="text"], input[type="email"], input[type="tel"], input[inputmode="email"], input[name*="user"], input[name*="email"], input[name*="login"], input[name*="account"], input[name*="identifier"], input[autocomplete="username"], input[autocomplete="email"], input[id*="user"], input[id*="email"], input[id*="login"], input[id*="account"], input[id*="identifier"]';
            var usernameField = null;

            // First pass: try specific selectors
            for (var c = 0; c < containers.length; c++) {
                var inputs = containers[c].querySelectorAll(usernameSelectors);
                for (var j = 0; j < inputs.length; j++) {
                    if (inputs[j].type === 'password' || inputs[j].type === 'hidden') continue;
                    if (inputs[j].offsetParent !== null || inputs[j].getClientRects().length > 0) {
                        usernameField = inputs[j];
                        break;
                    }
                }
                if (usernameField) break;
            }

            // Second pass: check placeholder/aria-label for email/username hints
            if (!usernameField) {
                var allInputs = (containers[0] || document.body).querySelectorAll('input:not([type="password"]):not([type="hidden"]):not([type="submit"]):not([type="button"]):not([type="checkbox"]):not([type="radio"])');
                for (var k = 0; k < allInputs.length; k++) {
                    var inp = allInputs[k];
                    if (inp.offsetParent === null && inp.getClientRects().length === 0) continue;
                    var ph = (inp.placeholder || '').toLowerCase();
                    var aria = (inp.getAttribute('aria-label') || '').toLowerCase();
                    var label = ph + ' ' + aria;
                    if (label.match(/email|e-mail|username|user name|login|account|identifier|phone/)) {
                        usernameField = inp;
                        break;
                    }
                }
            }

            if (usernameField && '\(escapedUsername)'.length > 0) {
                fillField(usernameField, '\(escapedUsername)');
            }
            fillField(pwField, '\(escapedPassword)');

            return true;
        })();
        """
    }

    // MARK: - Credential Capture Script

    /// Injected at document end to capture credentials on form submission.
    /// Handles both traditional form submit and modern JS-driven logins
    /// (button clicks, XHR/fetch, Enter key) used by sites like Footlocker, Nike, etc.
    static let credentialCaptureScript = """
    (function() {
        if (window.__cherryPasswordCaptureInstalled) return;
        window.__cherryPasswordCaptureInstalled = true;

        var captured = false;

        function findCredentials() {
            var passwordFields = document.querySelectorAll('input[type="password"]');
            if (passwordFields.length === 0) return null;

            for (var i = 0; i < passwordFields.length; i++) {
                var pwField = passwordFields[i];
                if (!pwField.value || pwField.value.length === 0) continue;
                if (pwField.offsetParent === null) continue; // skip hidden fields

                // Search for username field: first in the same form, then nearby in DOM
                var container = pwField.closest('form') || pwField.closest('[class*="login"], [class*="signin"], [class*="auth"], [id*="login"], [id*="signin"]') || pwField.parentElement.parentElement.parentElement || document.body;

                var usernameSelectors = 'input[type="text"], input[type="email"], input[type="tel"], input[inputmode="email"], input[name*="user"], input[name*="email"], input[name*="login"], input[name*="account"], input[name*="identifier"], input[autocomplete="username"], input[autocomplete="email"], input[id*="user"], input[id*="email"], input[id*="login"], input[id*="identifier"]';
                var usernameInputs = container.querySelectorAll(usernameSelectors);

                var username = '';
                for (var j = 0; j < usernameInputs.length; j++) {
                    if (usernameInputs[j].type === 'password' || usernameInputs[j].type === 'hidden') continue;
                    if (usernameInputs[j].value && usernameInputs[j].value.length > 0 && usernameInputs[j].offsetParent !== null) {
                        username = usernameInputs[j].value;
                        break;
                    }
                }

                // Fallback: check placeholder/aria-label for email/username hints
                if (!username) {
                    var allInputs = container.querySelectorAll('input:not([type="password"]):not([type="hidden"]):not([type="submit"]):not([type="button"]):not([type="checkbox"]):not([type="radio"])');
                    for (var k = 0; k < allInputs.length; k++) {
                        var inp = allInputs[k];
                        if (!inp.value || inp.value.length === 0 || inp.offsetParent === null) continue;
                        var ph = (inp.placeholder || '').toLowerCase();
                        var aria = (inp.getAttribute('aria-label') || '').toLowerCase();
                        var label = ph + ' ' + aria;
                        if (label.match(/email|e-mail|username|user name|login|account|identifier|phone/)) {
                            username = inp.value;
                            break;
                        }
                    }
                }

                return { username: username, password: pwField.value };
            }
            return null;
        }

        function sendCredentials(reason) {
            if (captured) return;
            var creds = findCredentials();
            if (!creds || !creds.password) return;
            captured = true;

            window.webkit.messageHandlers.cherryPasswordCapture.postMessage({
                type: 'credentialsCaptured',
                username: creds.username,
                password: creds.password,
                url: window.location.href
            });
        }

        // 1. Traditional form submit
        document.addEventListener('submit', function(e) {
            sendCredentials('submit');
        }, true);

        // 2. Click on submit/login buttons (covers JS-driven forms)
        document.addEventListener('click', function(e) {
            var target = e.target.closest('button, input[type="submit"], a, [role="button"]');
            if (!target) return;

            var text = (target.textContent || target.value || '').toLowerCase().trim();
            var ariaLabel = (target.getAttribute('aria-label') || '').toLowerCase();
            var id = (target.id || '').toLowerCase();
            var className = (target.className || '').toLowerCase();

            var loginKeywords = ['sign in', 'signin', 'log in', 'login', 'submit', 'continue', 'next', 'enter', 'sign-in', 'log-in', 'anmelden', 'connexion', 'inloggen'];
            var isLoginButton = loginKeywords.some(function(kw) {
                return text.includes(kw) || ariaLabel.includes(kw) || id.includes(kw) || className.includes(kw);
            });

            // Also check if button is type="submit"
            if (target.tagName === 'INPUT' && target.type === 'submit') isLoginButton = true;
            if (target.tagName === 'BUTTON' && target.type === 'submit') isLoginButton = true;

            // Check if there is a visible password field on the page with a value
            if (isLoginButton) {
                var passwordFields = document.querySelectorAll('input[type="password"]');
                for (var i = 0; i < passwordFields.length; i++) {
                    if (passwordFields[i].value && passwordFields[i].value.length > 0 && passwordFields[i].offsetParent !== null) {
                        // Small delay so the page can process the click first
                        setTimeout(function() { sendCredentials('button-click'); }, 100);
                        return;
                    }
                }
            }
        }, true);

        // 3. Enter key press in password field or adjacent username field
        document.addEventListener('keydown', function(e) {
            if (e.key !== 'Enter') return;
            var target = e.target;
            if (!target || target.tagName !== 'INPUT') return;
            if (target.type === 'password' || target.type === 'email' || target.type === 'text') {
                // Only capture if there's a filled password field on the page
                var passwordFields = document.querySelectorAll('input[type="password"]');
                for (var i = 0; i < passwordFields.length; i++) {
                    if (passwordFields[i].value && passwordFields[i].value.length > 0 && passwordFields[i].offsetParent !== null) {
                        setTimeout(function() { sendCredentials('enter-key'); }, 300);
                        return;
                    }
                }
            }
        }, true);
    })();
    """
}
