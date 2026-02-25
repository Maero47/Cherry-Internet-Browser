//
//  SettingsPageView.swift
//  Cherry Browser
//

import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case privacy = "Privacy"
    case passwords = "Passwords"
    case focus = "Focus"
    case about = "About"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: "gear"
        case .privacy: "lock.shield"
        case .passwords: "key.fill"
        case .focus: "brain.head.profile"
        case .about: "info.circle"
        }
    }
}

struct SettingsPageView: View {
    @State private var selectedSection: SettingsSection = .general
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            let showSidebar = geo.size.width > 500

            if showSidebar {
                // Wide layout: sidebar + content
                HStack(spacing: 0) {
                    settingsSidebar
                        .frame(width: 180)

                    Divider()

                    settingsContent
                }
            } else {
                // Narrow layout: top picker + content
                VStack(spacing: 0) {
                    compactPicker
                    Divider()
                    settingsContent
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Settings")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 12)

            ForEach(SettingsSection.allCases) { section in
                Button {
                    selectedSection = section
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: section.icon)
                            .font(.system(size: 14))
                            .frame(width: 20)
                        Text(section.rawValue)
                            .font(.system(size: 13))
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(selectedSection == section
                                  ? SettingsManager.shared.accentColor.opacity(0.15)
                                  : Color.clear)
                    )
                    .foregroundStyle(selectedSection == section ? .primary : .secondary)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
            }

            Spacer()
        }
        .background(colorScheme == .dark
                    ? Color.black.opacity(0.2)
                    : Color.gray.opacity(0.05))
    }

    @ViewBuilder
    private var compactPicker: some View {
        HStack(spacing: 0) {
            Text("Settings")
                .font(.headline)
                .padding(.leading, 16)

            Spacer()

            Picker("", selection: $selectedSection) {
                ForEach(SettingsSection.allCases) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 240)
            .padding(.trailing, 16)
        }
        .padding(.vertical, 10)
        .background(colorScheme == .dark
                    ? Color.black.opacity(0.2)
                    : Color.gray.opacity(0.05))
    }

    @ViewBuilder
    private var settingsContent: some View {
        switch selectedSection {
        case .passwords:
            // PasswordsSettingsView has its own List — don't wrap in ScrollView
            PasswordsSettingsView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch selectedSection {
                    case .general:
                        GeneralSettingsView()
                    case .privacy:
                        PrivacySettingsView()
                    case .focus:
                        FocusModeSettingsView()
                    case .about:
                        AboutSettingsView()
                    case .passwords:
                        EmptyView() // handled above
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}
