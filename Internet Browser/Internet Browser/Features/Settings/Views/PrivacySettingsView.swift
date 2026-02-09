//
//  PrivacySettingsView.swift
//  Cherry Browser
//

import SwiftUI

struct PrivacySettingsView: View {
    @Bindable private var settings = SettingsManager.shared
    @State private var showClearData = false

    var body: some View {
        Form {
            Section("Web Content") {
                Toggle("Enable JavaScript", isOn: $settings.enableJavaScript)
                Toggle("HTTPS-Only Mode", isOn: $settings.httpsOnlyMode)

                if settings.httpsOnlyMode {
                    Text("Automatically upgrades connections to HTTPS when available.")
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
