//
//  SettingsView.swift
//  Cherry Browser
//

import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            PrivacySettingsView()
                .tabItem {
                    Label("Privacy", systemImage: "lock.shield")
                }

            AboutSettingsView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 480, height: 400)
    }
}
