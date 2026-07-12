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

            PasswordsSettingsView()
                .tabItem {
                    Label("Passwords", systemImage: "key.fill")
                }

            FocusModeSettingsView()
                .tabItem {
                    Label("Focus", systemImage: "brain.head.profile")
                }

            ExtensionsSettingsView()
                .tabItem {
                    Label("Extensions", systemImage: "puzzlepiece.extension")
                }

            AboutSettingsView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 520, height: 520)
    }
}
