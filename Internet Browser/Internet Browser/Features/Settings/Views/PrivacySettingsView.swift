//
//  PrivacySettingsView.swift
//  Cherry Browser
//

import SwiftUI

struct PrivacySettingsView: View {
    @Bindable private var settings = SettingsManager.shared
    @State private var adBlocker = AdBlockManager.shared
    @State private var cookiePolicy = CookiePolicyManager.shared
    @State private var showClearData = false
    @State private var isUpdatingFilters = false

    var body: some View {
        SettingsStack {
            SettingsCard(
                icon: "shield.lefthalf.filled",
                title: "Content Blocking",
                subtitle: "Uses EasyList and EasyPrivacy filter lists to block ads, trackers, and intrusive content. Lists are updated automatically every 24 hours."
            ) {
                SettingsToggleRow(title: "Block Ads & Trackers", isOn: $settings.adBlockEnabled)

                // A rule list WebKit refuses to compile is invisible at
                // runtime — the requests it would have blocked simply go
                // through. Say so instead of showing a switch that reads "on".
                if settings.adBlockEnabled, let title = adBlocker.blockingWarningTitle {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title)
                                .font(.system(size: 11, weight: .medium))
                            if let detail = adBlocker.blockingWarningDetail {
                                Text(detail)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if settings.adBlockEnabled {
                    HStack(spacing: 10) {
                        Button("Update Filter Lists Now") {
                            isUpdatingFilters = true
                            Task { @MainActor in
                                AdBlockManager.shared.forceUpdate()
                                await AdBlockManager.shared.ensureRulesCompiled()
                                isUpdatingFilters = false
                            }
                        }
                        .controlSize(.small)
                        .disabled(isUpdatingFilters)

                        if isUpdatingFilters {
                            ProgressView()
                                .scaleEffect(0.55)
                            Text("Downloading and compiling filter lists...")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            SettingsCard(icon: "globe", title: "Web Content") {
                SettingsToggleRow(
                    title: "Enable JavaScript",
                    subtitle: "Open pages keep running their scripts until you reload them.",
                    isOn: $settings.enableJavaScript
                )

                Divider()

                SettingsToggleRow(
                    title: "Upgrade Known Sites to HTTPS",
                    subtitle: "Uses WebKit's list of HTTPS-capable sites to upgrade http:// links to those sites. Other http:// addresses still load unencrypted.",
                    isOn: $settings.httpsOnlyMode
                )

                Divider()

                SettingsToggleRow(
                    title: "Block Pop-up Windows",
                    subtitle: "Blocks pop-up windows that are not triggered by user actions. New tabs will use updated settings.",
                    isOn: $settings.blockPopups
                )
            }

            SettingsCard(
                icon: "cylinder.split.1x2",
                title: "Cookies",
                subtitle: "Cookies are stripped from network requests. A page's own scripts can still keep cookies for as long as that page is open. Open tabs are updated and reloaded when you change this."
            ) {
                SettingsLabeledRow(title: "Cookie Policy") {
                    Picker("", selection: $settings.blockCookies) {
                        ForEach(CookieBlockingLevel.allCases) { level in
                            Text(level.displayName).tag(level)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }

                if let failure = cookiePolicy.compileFailure {
                    Text("This policy could not be loaded, so cookies are not being blocked. \(failure)")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            SettingsCard(icon: "eye.slash", title: "Tracking") {
                SettingsToggleRow(
                    title: "Send Global Privacy Control Signal",
                    subtitle: "Tells every site you do not consent to having your data sold or shared, via navigator.globalPrivacyControl. Legally binding on sites covered by the CCPA and similar laws; others may ignore it. Open tabs are reloaded when you change this.",
                    isOn: $settings.sendGlobalPrivacyControl
                )
            }

            SettingsCard(icon: "trash", title: "Data") {
                SettingsLabeledRow(
                    title: "Browsing Data",
                    subtitle: "Remove history, cookies, site storage (including IndexedDB and service workers), and caches."
                ) {
                    Button("Clear Browsing Data...") {
                        showClearData = true
                    }
                    .controlSize(.small)
                }
            }
        }
        .sheet(isPresented: $showClearData) {
            ClearDataView()
        }
    }
}
