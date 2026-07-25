//
//  DownloadQuarantine.swift
//  Cherry Browser
//

import CoreServices
import Foundation

/// Marks finished downloads as "downloaded from the internet".
///
/// Cherry moves every download into place itself, and nothing was setting
/// `NSURLQuarantinePropertiesKey` on the result. A `.dmg`, `.pkg` or `.app`
/// that arrives without the quarantine xattr is not a download as far as
/// LaunchServices is concerned: opening it skips Gatekeeper's "downloaded
/// from the internet — are you sure?" prompt entirely, and on an unnotarized
/// bundle skips the Gatekeeper check with it. `LSFileQuarantineEnabled` in
/// Info.plist covers files the frameworks write on our behalf; this covers the
/// ones we move ourselves.
enum DownloadQuarantine {

    /// Attaches quarantine metadata to a finished download.
    /// - Parameter sourceURL: where the bytes came from, recorded so Gatekeeper
    ///   and the Finder can tell the user which site they trusted.
    static func apply(to fileURL: URL, sourceURL: URL?) {
        var properties: [String: Any] = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
            kLSQuarantineAgentNameKey as String: "Cherry",
            kLSQuarantineTimeStampKey as String: Date(),
        ]
        if let sourceURL {
            properties[kLSQuarantineDataURLKey as String] = sourceURL.absoluteString
            properties[kLSQuarantineOriginURLKey as String] = sourceURL.absoluteString
        }

        var url = fileURL
        var values = URLResourceValues()
        values.quarantineProperties = properties
        do {
            try url.setResourceValues(values)
        } catch {
            print("Failed to quarantine downloaded file: \(error)")
        }
    }

    /// File types macOS will execute, install, or run a script from. Opening
    /// one of these from inside Cherry asks first — the Gatekeeper prompt only
    /// appears for some of them, and a double-click in a browser sidebar is
    /// too small a gesture to launch an installer on its own.
    static let riskyExtensions: Set<String> = [
        "app", "dmg", "pkg", "mpkg", "iso",
        "command", "sh", "bash", "zsh", "csh", "tool",
        "scpt", "scptd", "applescript", "workflow", "action",
        "jar", "pl", "py", "rb", "php",
        "exe", "msi", "bat", "cmd", "scr", "vbs",
        "deb", "rpm", "run", "bin", "apk",
        "prefpane", "kext", "dylib", "so", "plugin", "bundle", "qlgenerator",
        "terminal", "webloc", "inetloc", "url", "shortcut",
    ]

    static func isRisky(_ fileURL: URL) -> Bool {
        riskyExtensions.contains(
            HostNormalizer.foldedASCII(fileURL.pathExtension)
        )
    }
}
