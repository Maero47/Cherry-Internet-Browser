//
//  AboutSettingsView.swift
//  Cherry Browser
//

import SwiftUI

struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            // App icon
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 20))

            Text(AppConstants.appName)
                .font(.title)
                .fontWeight(.bold)

            Text("Version \(appVersion) (\(buildNumber))")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("A fast, lightweight web browser for macOS.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Divider()
                .padding(.horizontal, 40)

            VStack(spacing: 4) {
                Text("Built with SwiftUI & WebKit")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text("All data stays on your device.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}
