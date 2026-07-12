//
//  PrivacySettingsView.swift
//  Cherry Browser
//

import SwiftUI

struct PrivacySettingsView: View {
    @Bindable private var settings = SettingsManager.shared
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
                SettingsToggleRow(title: "Enable JavaScript", isOn: $settings.enableJavaScript)

                Divider()

                SettingsToggleRow(
                    title: "HTTPS-Only Mode",
                    subtitle: "Automatically upgrades connections to HTTPS when available.",
                    isOn: $settings.httpsOnlyMode
                )

                Divider()

                SettingsToggleRow(
                    title: "Block Pop-up Windows",
                    subtitle: "Blocks pop-up windows that are not triggered by user actions. New tabs will use updated settings.",
                    isOn: $settings.blockPopups
                )
            }

            SettingsCard(icon: "cylinder.split.1x2", title: "Cookies") {
                SettingsLabeledRow(title: "Cookie Policy") {
                    Picker("", selection: $settings.blockCookies) {
                        ForEach(CookieBlockingLevel.allCases) { level in
                            Text(level.rawValue).tag(level)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }

            SettingsCard(icon: "eye.slash", title: "Tracking") {
                SettingsToggleRow(
                    title: "Send Do Not Track Header",
                    subtitle: "Requests that websites do not track your browsing activity. Websites may choose to ignore this.",
                    isOn: $settings.sendDoNotTrack
                )
            }

            SettingsCard(icon: "trash", title: "Data") {
                SettingsLabeledRow(
                    title: "Browsing Data",
                    subtitle: "Remove history, cookies, and caches."
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
