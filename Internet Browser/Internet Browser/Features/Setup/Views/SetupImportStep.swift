//
//  SetupImportStep.swift
//  Cherry Browser
//
//  The wizard's import step: bookmarks and history from another browser,
//  through the SAME `BrowserImportService` the Settings ▸ Import pane runs —
//  same detection, same readers, same repository writes, same result type.
//  Only the presentation is trimmed to wizard size; favorites, passwords and
//  CSV import stay where they were, one click away in Settings ▸ Import.
//
//  Failure and emptiness are first-class outcomes here, not surprises:
//  finding no browsers says so (and points at Settings ▸ Import for later),
//  a finished run reports exactly what was added, per-type errors are listed
//  the way the pane lists them, and a Safari read blocked by TCC surfaces
//  the same Full Disk Access guidance. Nothing blocks the wizard: the user
//  can Continue past a failed, empty or still-running import.
//

import SwiftUI

struct SetupImportStep: View {
    @State private var service = BrowserImportService()
    @State private var selectedBrowserID: SourceBrowser.ID?
    @State private var selectedProfileID: SourceProfile.ID?
    /// What this step offers; the wizard's remit is "bookmarks and history".
    @State private var selectedTypes: Set<ImportableDataType> = [.bookmarks, .history]

    private var accent: Color { SettingsManager.shared.accentColor }

    private var selectedSource: DetectedSource? {
        service.sources.first { $0.id == selectedBrowserID }
    }

    private var selectedProfile: SourceProfile? {
        guard let source = selectedSource else { return nil }
        return source.profiles.first { $0.id == selectedProfileID } ?? source.profiles.first
    }

    private var importableSelection: Set<ImportableDataType> {
        guard let profile = selectedProfile else { return [] }
        return selectedTypes.filter { $0.isSupported && profile.availableTypes.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SetupStepHeader(
                step: .importData,
                title: "Bring your stuff",
                subtitle: "Bookmarks and history from another browser on this Mac."
            )

            if service.isDetecting && service.sources.isEmpty {
                SettingsCard(icon: "square.and.arrow.down", title: "Import From") {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking for installed browsers…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            } else if service.sources.isEmpty {
                SettingsCard(icon: "square.and.arrow.down", title: "Import From") {
                    Text("No other browsers with importable data were found on this Mac.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("You can import any time later from Settings ▸ Import — including passwords from a CSV file.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else {
                importCard
            }

            if let result = service.lastResult {
                resultCard(result)
            }
        }
        .task {
            await service.detectSources()
            if selectedBrowserID == nil, let first = service.sources.first {
                selectedBrowserID = first.id
                selectedProfileID = first.profiles.first?.id
            }
        }
    }

    // MARK: - Source + options

    private var importCard: some View {
        SettingsCard(
            icon: "square.and.arrow.down",
            title: "Import From",
            subtitle: "Passwords and home-screen favorites can be imported later from Settings ▸ Import."
        ) {
            SettingsLabeledRow(title: "Browser") {
                CherryPicker(
                    selection: browserBinding,
                    options: service.sources.map { .init($0.id, $0.browser.displayName, systemImage: $0.browser.icon) }
                )
                .disabled(service.isImporting)
            }

            if let source = selectedSource, source.profiles.count > 1 {
                Divider()
                SettingsLabeledRow(title: "Profile") {
                    CherryPicker(
                        selection: profileBinding,
                        options: source.profiles.map { .init($0.id, $0.displayName) }
                    )
                    .disabled(service.isImporting)
                }
            }

            Divider()

            ForEach([ImportableDataType.bookmarks, .history], id: \.self) { type in
                dataTypeRow(type)
            }

            Divider()

            HStack(spacing: 12) {
                Button {
                    startImport()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.down")
                        Text("Import")
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(accent, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .foregroundStyle(.white)
                    .opacity(service.isImporting || importableSelection.isEmpty ? 0.5 : 1)
                }
                .buttonStyle(.plain)
                .disabled(service.isImporting || importableSelection.isEmpty)

                if service.isImporting {
                    ProgressView().controlSize(.small)
                    Text(service.statusText)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func dataTypeRow(_ type: ImportableDataType) -> some View {
        let isAvailable = selectedProfile?.availableTypes.contains(type) ?? false
        SettingsToggleRow(
            title: type.displayName,
            subtitle: isAvailable ? nil : "Not found in this profile",
            isOn: Binding(
                get: { selectedTypes.contains(type) && isAvailable },
                set: { isOn in
                    if isOn { selectedTypes.insert(type) } else { selectedTypes.remove(type) }
                }
            )
        )
        .disabled(!isAvailable || service.isImporting)
        .opacity(isAvailable ? 1 : 0.5)
    }

    private var browserBinding: Binding<SourceBrowser.ID> {
        Binding(
            get: { selectedBrowserID ?? "" },
            set: { newValue in
                selectedBrowserID = newValue
                selectedProfileID = service.sources.first { $0.id == newValue }?.profiles.first?.id
            }
        )
    }

    private var profileBinding: Binding<SourceProfile.ID> {
        Binding(
            get: { selectedProfile?.id ?? "" },
            set: { selectedProfileID = $0 }
        )
    }

    private func startImport() {
        guard let source = selectedSource, let profile = selectedProfile else { return }
        let types = importableSelection
        Task {
            await service.runImport(browser: source.browser, profile: profile, types: types)
        }
    }

    // MARK: - Result

    /// Same anatomy as the pane's result card: green lines for what arrived,
    /// orange lines for what failed, and the Full Disk Access door when
    /// that's what stood in the way. An import that found nothing new still
    /// reports honestly rather than pretending success.
    private func resultCard(_ result: ImportResult) -> some View {
        SettingsCard(
            icon: result.errors.isEmpty ? "checkmark.circle" : "exclamationmark.triangle",
            title: result.errors.isEmpty ? "Import Complete" : "Import Finished with Issues",
            subtitle: result.browserName
        ) {
            if result.summaryLines.isEmpty && result.errors.isEmpty {
                Text("Nothing new to import — everything was already in Cherry.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }

            ForEach(result.summaryLines, id: \.self) { line in
                Label(line, systemImage: "checkmark")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.green)
            }

            ForEach(result.errors, id: \.self) { error in
                Label(error, systemImage: "xmark.octagon")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.orange)
            }

            if result.needsFullDiskAccess {
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Open Full Disk Access Settings", systemImage: "lock.shield")
                        .font(.system(size: 12, weight: .medium))
                }
                .controlSize(.small)
            }
        }
    }
}
