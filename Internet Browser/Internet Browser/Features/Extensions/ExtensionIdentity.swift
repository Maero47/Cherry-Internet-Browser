//
//  ExtensionIdentity.swift
//  Internet Browser
//
//  What makes two packages the SAME extension.
//
//  Cherry keyed every install on a fresh `UUID()`, so nothing connected a
//  second install of an extension to the first: installing uBO Lite twice
//  produced two managed copies, two contexts and two toolbar buttons. That is
//  not hypothetical — the owner's real `index.json` held THREE uBO Lite
//  records (ids 0C2B61C2, A7FB389D, 7F49D5FA), two of them the identical
//  version 2026.804.1652, differing only in the filename each was downloaded
//  under.
//
//  Which is also why the filename cannot be the identity: the same extension
//  arrived as `uBlock-Origin-Lite.xpi`, `uBOLite.firefox.xpi` and
//  `uBOLite_2026.804.1652.firefox.signed.xpi`. The identity has to come from
//  the manifest WebKit parsed.
//

import Foundation

enum ExtensionIdentity {

    /// The value two installs of the same extension share, or `nil` if this
    /// package declares nothing stable enough to match on.
    ///
    /// `nil` means "install as new". A wrong match would silently replace an
    /// unrelated extension the user installed on purpose, which is worse than
    /// the duplicate this is here to prevent, so every source below is one an
    /// extension author sets deliberately to identify their own extension.
    static func of(manifest: [String: Any]) -> String? {
        // Firefox's own extension id, and what every package on Cherry's
        // shortlist carries. Both spellings: `browser_specific_settings` is
        // current, `applications` is the older key still shipped by some.
        for key in ["browser_specific_settings", "applications"] {
            if let settings = manifest[key] as? [String: Any],
               let gecko = settings["gecko"] as? [String: Any],
               let id = nonEmpty(gecko["id"]) {
                return "gecko:\(id)"
            }
        }

        // Chrome's packed-extension public key. The extension id Chrome shows
        // is derived from exactly this, so two packages sharing it are the
        // same extension.
        if let key = nonEmpty(manifest["key"]) {
            return "key:\(key)"
        }

        // Nothing declared. The manifest name is the last honest signal —
        // two extensions with the same name are indistinguishable to the user
        // too, since it is the name the toolbar and the settings pane show.
        //
        // Except when it is a localisation placeholder: `__MSG_extName__` is
        // what Simple Translate's manifest carries, and matching on it would
        // fuse every localised extension in the world into one entry.
        if let name = nonEmpty(manifest["name"]), !isLocalisationPlaceholder(name) {
            return "name:\(name.lowercased())"
        }

        return nil
    }

    /// A `__MSG_key__` reference into the extension's `_locales` files, rather
    /// than a name.
    static func isLocalisationPlaceholder(_ value: String) -> Bool {
        value.hasPrefix("__MSG_") && value.hasSuffix("__")
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
