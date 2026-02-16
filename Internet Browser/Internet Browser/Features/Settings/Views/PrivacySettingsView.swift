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
        Form {
            Section("Content Blocking") {
                Toggle("Block Ads & Trackers", isOn: $settings.adBlockEnabled)

                Text("Uses EasyList and EasyPrivacy filter lists to block ads, trackers, and intrusive content. Lists are updated automatically every 24 hours.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if settings.adBlockEnabled {
                    Button("Update Filter Lists Now") {
                        isUpdatingFilters = true
                        Task { @MainActor in
                            AdBlockManager.shared.forceUpdate()
                            await AdBlockManager.shared.ensureRulesCompiled()
                            isUpdatingFilters = false
                        }
                    }
                    .disabled(isUpdatingFilters)

                    if isUpdatingFilters {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("Downloading and compiling filter lists...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Web Content") {
                Toggle("Enable JavaScript", isOn: $settings.enableJavaScript)

                Toggle("HTTPS-Only Mode", isOn: $settings.httpsOnlyMode)
                if settings.httpsOnlyMode {
                    Text("Automatically upgrades connections to HTTPS when available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("Block Pop-up Windows", isOn: $settings.blockPopups)
                if settings.blockPopups {
                    Text("Blocks pop-up windows that are not triggered by user actions. New tabs will use updated settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Cookies") {
                Picker("Cookie Policy", selection: $settings.blockCookies) {
                    ForEach(CookieBlockingLevel.allCases) { level in
                        Text(level.rawValue).tag(level)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("Tracking") {
                Toggle("Send Do Not Track Header", isOn: $settings.sendDoNotTrack)

                if settings.sendDoNotTrack {
                    Text("Requests that websites do not track your browsing activity. Websites may choose to ignore this.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Data") {
                Button("Clear Browsing Data...") {
                    showClearData = true
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .sheet(isPresented: $showClearData) {
            ClearDataView()
        }
    }
}
