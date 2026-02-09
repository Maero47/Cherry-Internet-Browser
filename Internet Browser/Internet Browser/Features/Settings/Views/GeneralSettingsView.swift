//
//  GeneralSettingsView.swift
//  Cherry Browser
//

import SwiftUI

struct GeneralSettingsView: View {
    @Bindable private var settings = SettingsManager.shared

    var body: some View {
        Form {
            Section("Search") {
                Picker("Search Engine", selection: $settings.searchEngine) {
                    ForEach(SearchEngine.allCases) { engine in
                        Text(engine.rawValue).tag(engine)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("Homepage") {
                TextField("Homepage URL", text: $settings.homepage)
                    .textFieldStyle(.roundedBorder)
            }

            Section("Appearance") {
                Toggle("Show Bookmark Bar", isOn: $settings.showBookmarkBar)
                Toggle("Use Vertical Tab Bar", isOn: $settings.useVerticalTabs)
            }

            Section("Tabs") {
                Toggle("Auto-sleep Inactive Tabs", isOn: $settings.tabSleepEnabled)

                if settings.tabSleepEnabled {
                    Picker("Sleep After", selection: $settings.tabSleepTimeout) {
                        Text("15 minutes").tag(15)
                        Text("30 minutes").tag(30)
                        Text("1 hour").tag(60)
                        Text("2 hours").tag(120)
                    }
                    .pickerStyle(.menu)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
