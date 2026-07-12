//
//  SettingsView.swift
//  Cherry Browser
//

import SwiftUI

/// The Settings scene (Cmd+,). Routes to the same sidebar experience as the
/// in-tab settings page so there is a single settings UI to maintain.
struct SettingsView: View {
    var body: some View {
        SettingsPageView()
            .frame(width: 780, height: 580)
    }
}
