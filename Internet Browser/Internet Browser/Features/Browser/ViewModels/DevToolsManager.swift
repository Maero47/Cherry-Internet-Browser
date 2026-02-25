//
//  DevToolsManager.swift
//  Cherry Browser
//

import Foundation
import Observation
import SwiftUI

// MARK: - DevToolsTab (shared by manager + panel view)

enum DevToolsTab: String, CaseIterable {
    case console  = "Console"
    case network  = "Network"
    case elements = "Elements"

    var icon: String {
        switch self {
        case .console:  return "terminal"
        case .network:  return "network"
        case .elements: return "rectangle.3.offgrid"
        }
    }
}

// MARK: - Inspected Element

struct InspectedElement {
    var tag: String
    var id: String
    var classes: String
    var outerHTML: String
    var selector: String
    var styles: [String: String]       // computed styles
    var attrs: [String: String]        // DOM attributes

    var displayName: String {
        var s = "<\(tag)"
        if !id.isEmpty      { s += " id=\"\(id)\"" }
        if !classes.isEmpty { s += " class=\"\(classes)\"" }
        return s + ">"
    }
}

// MARK: - DevToolsManager

@Observable
final class DevToolsManager {
    static let shared = DevToolsManager()
    private init() {}

    // MARK: - Console

    var consoleEntries: [ConsoleEntry] = []

    func appendConsole(_ entry: ConsoleEntry) {
        if consoleEntries.count >= 2000 {
            consoleEntries.removeFirst(consoleEntries.count - 1999)
        }
        consoleEntries.append(entry)
    }

    func clearConsole() { consoleEntries.removeAll() }

    // MARK: - Network

    var networkEntries: [NetworkEntry] = []
    private var inFlight: [String: Date] = [:]

    func networkRequestStarted(url: String, method: String) -> String {
        let entry = NetworkEntry(url: url, method: method)
        let key   = entry.id.uuidString
        inFlight[key] = Date()
        if networkEntries.count >= 2000 {
            networkEntries.removeFirst(networkEntries.count - 1999)
        }
        networkEntries.append(entry)
        return key
    }

    func networkRequestFinished(key: String, statusCode: Int?, mimeType: String?, isError: Bool) {
        guard let startDate = inFlight.removeValue(forKey: key) else { return }
        let elapsed = Date().timeIntervalSince(startDate) * 1000
        if let idx = networkEntries.firstIndex(where: { $0.id.uuidString == key }) {
            networkEntries[idx].statusCode     = statusCode
            networkEntries[idx].responseTimeMs = elapsed
            networkEntries[idx].mimeType       = mimeType
            networkEntries[idx].isError        = isError
        }
    }

    func finalizeByURL(url: String, statusCode: Int, mimeType: String?, isError: Bool) {
        guard let key = inFlight.keys.first(where: { k in
            networkEntries.first(where: { $0.id.uuidString == k })?.url == url
        }) else { return }
        networkRequestFinished(key: key, statusCode: statusCode, mimeType: mimeType, isError: isError)
    }

    func clearNetwork() { networkEntries.removeAll(); inFlight.removeAll() }

    // MARK: - Elements / Inspect

    var inspectedElement: InspectedElement? = nil
    var activeDevToolsTab: DevToolsTab = .console

    /// Called from the right-click "Inspect Element" JS result
    func selectElement(from dict: [String: Any]) {
        let stylesRaw = dict["styles"] as? [String: Any] ?? [:]
        var styles: [String: String] = [:]
        for (k, v) in stylesRaw { styles[k] = "\(v)" }

        let attrsRaw = dict["attrs"] as? [String: Any] ?? [:]
        var attrs: [String: String] = [:]
        for (k, v) in attrsRaw { attrs[k] = "\(v)" }

        inspectedElement = InspectedElement(
            tag:       dict["tag"]       as? String ?? "",
            id:        dict["id"]        as? String ?? "",
            classes:   dict["classes"]   as? String ?? "",
            outerHTML: dict["outerHTML"] as? String ?? "",
            selector:  dict["selector"]  as? String ?? "",
            styles:    styles,
            attrs:     attrs
        )
        activeDevToolsTab = .elements
    }

    // MARK: - JS Helper Scripts

    static func highlightScript(for selector: String) -> String {
        let escaped = selector
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'",  with: "\\'")
        return """
        (function(){
            var e=document.getElementById('__cherry_hl');if(e)e.remove();
            var el=document.querySelector('\(escaped)');if(!el)return;
            var r=el.getBoundingClientRect();
            var d=document.createElement('div');d.id='__cherry_hl';
            d.style.cssText='position:fixed!important;top:'+r.top+'px!important;left:'+r.left+'px!important;width:'+r.width+'px!important;height:'+r.height+'px!important;background:rgba(66,133,244,0.15)!important;border:2px solid rgba(66,133,244,0.9)!important;pointer-events:none!important;z-index:2147483647!important;box-sizing:border-box!important;transition:all .1s ease!important;';
            document.body.appendChild(d);
            setTimeout(function(){var h=document.getElementById('__cherry_hl');if(h)h.remove();},3000);
        })();
        """
    }

    static func applyScript(selector: String, base64HTML: String) -> String {
        let escaped = selector
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'",  with: "\\'")
        // Strategy:
        //   1. Use window.__cherryDTP (our TrustedTypePolicy injected at document start)
        //      to wrap the raw HTML string into a TrustedHTML object.
        //   2. Pass that to DOMParser.parseFromString — TT-enforcing sites (Google, YouTube…)
        //      accept TrustedHTML but reject plain strings.
        //   3. Import the resulting DOM node and replace the target element.
        //   DOMParser, importNode and replaceChild are NOT TT sinks, so step 3 is always safe.
        return """
        (function(){
            try{
                var el=document.querySelector('\(escaped)');
                if(!el)return 'not found';
                // Decode base64 → UTF-8 bytes → string via TextDecoder.
                // atob() produces a Latin-1 byte string; feeding those bytes directly
                // to the DOM corrupts multi-byte characters (ü, ñ, 中, emoji…).
                var b64bytes=atob('\(base64HTML)');
                var u8=new Uint8Array(b64bytes.length);
                for(var i=0;i<b64bytes.length;i++)u8[i]=b64bytes.charCodeAt(i);
                var raw=new TextDecoder('utf-8').decode(u8);

                // Wrap in TrustedHTML if the page enforces Trusted Types
                var htmlVal=raw;
                if(window.__cherryDTP&&window.__cherryDTP.createHTML){
                    try{htmlVal=window.__cherryDTP.createHTML(raw);}catch(e){}
                }

                var parser=new DOMParser();
                var parsed=parser.parseFromString(htmlVal,'text/html');
                var newNode=parsed.body&&parsed.body.firstChild;
                if(!newNode)return 'empty html';
                var imported=document.importNode(newNode,true);
                el.parentNode.replaceChild(imported,el);
                return 'ok';
            }catch(e){return 'error: '+e.message;}
        })();
        """
    }
}
