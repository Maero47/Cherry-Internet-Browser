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
    case extensions = "Extensions"
    case importData = "Import"
    case connections = "Connections"
    case about = "About"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: "gear"
        case .privacy: "lock.shield"
        case .passwords: "key.fill"
        case .focus: "brain.head.profile"
        case .extensions: "puzzlepiece.extension"
        case .importData: "square.and.arrow.down"
        case .connections: "point.3.connected.trianglepath.dotted"
        case .about: "info.circle"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Search, theme, downloads, and tabs"
        case .privacy: "Content blocking, cookies, and tracking"
        case .passwords: "Saved credentials and AutoFill"
        case .focus: "Block distracting sites while you work"
        case .extensions: "Manage installed WebExtensions"
        case .importData: "Bring bookmarks and history from another browser"
        case .connections: "Let Claude Code use this browser over MCP"
        case .about: "About Cherry"
        }
    }

}

/// Asks Settings to open on a particular section.
///
/// Set by the MCP connection indicator: when the toolbar says an outside
/// program is reading this browser, the switch that stops it has to be one
/// click away, not four.
///
/// ## Why a serial and not just a stored section
///
/// The first version stored a `pendingSelection` consumed in `.onAppear`, which
/// broke in the case that matters most. `Tab.openInternalPage` only re-sets
/// `internalPage = .settings`, so when the tab is ALREADY showing Settings the
/// page is not recreated and `onAppear` never fires. The click did nothing —
/// and worse, the request stayed set and hijacked the next Settings open onto
/// Connections when the user had asked for General.
///
/// `@Observable` plus a monotonic serial fixes both halves: an already-open
/// pane reacts to the serial changing, a not-yet-created one picks the request
/// up on appear, and whichever gets there first clears it so nothing lingers.
@Observable
final class SettingsNavigator {

    static let shared = SettingsNavigator()

    private(set) var requestedSection: SettingsSection?

    /// Bumped on every request, so asking twice for the same section is still
    /// two events. Without it, clicking the indicator while Settings already
    /// shows Connections would publish no change at all.
    private(set) var requestSerial = 0

    func request(_ section: SettingsSection) {
        requestedSection = section
        requestSerial += 1
    }

    /// Takes the outstanding request, if there is one. Clearing on take is what
    /// stops a stale request from redirecting an unrelated Settings open later.
    func takeRequestedSection() -> SettingsSection? {
        defer { requestedSection = nil }
        return requestedSection
    }
}

struct SettingsPageView: View {
    @State private var selectedSection: SettingsSection = .general
    @State private var navigator = SettingsNavigator.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            let showSidebar = geo.size.width > 500

            if showSidebar {
                // Wide layout: sidebar + content
                HStack(spacing: 0) {
                    settingsSidebar
                        .frame(width: 192)

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
        // Both hooks are needed and neither is redundant: `onAppear` catches a
        // request made before this page existed (the usual case — clicking the
        // indicator is what opens Settings), `onChange` catches one made while
        // it is already on screen, where nothing is recreated.
        .onAppear { applyRequestedSection() }
        .onChange(of: navigator.requestSerial) { _, _ in applyRequestedSection() }
    }

    private func applyRequestedSection() {
        guard let section = navigator.takeRequestedSection() else { return }
        selectedSection = section
    }

    @ViewBuilder
    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Settings")
                .font(.system(size: 20, weight: .bold))
                .padding(.horizontal, 20)
                .padding(.top, 22)
                .padding(.bottom, 14)

            ForEach(SettingsSection.allCases) { section in
                SettingsSidebarItem(section: section, isSelected: selectedSection == section) {
                    selectedSection = section
                }
            }

            Spacer()
        }
        .frame(maxHeight: .infinity)
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
                    Label(section.rawValue, systemImage: section.icon).tag(section)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
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
        case .about:
            // Centered when there's room, scrollable when the window is small
            GeometryReader { proxy in
                ScrollView {
                    AboutSettingsView()
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                }
            }
        default:
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sectionHeader

                    switch selectedSection {
                    case .general:
                        GeneralSettingsView()
                    case .privacy:
                        PrivacySettingsView()
                    case .focus:
                        FocusModeSettingsView()
                    case .extensions:
                        ExtensionsSettingsView()
                    case .importData:
                        ImportSettingsView()
                    case .connections:
                        MCPSettingsView()
                    case .passwords, .about:
                        EmptyView() // handled above
                    }
                }
                .padding(24)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var sectionHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(selectedSection.rawValue)
                .font(.system(size: 22, weight: .bold))
            Text(selectedSection.subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}

private struct SettingsSidebarItem: View {
    let section: SettingsSection
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false
    private var accent: Color { SettingsManager.shared.accentColor }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: section.icon)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? accent : Color.secondary)
                    .frame(width: 21)

                Text(section.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected
                          ? accent.opacity(0.14)
                          : (isHovering ? Color.primary.opacity(0.05) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
