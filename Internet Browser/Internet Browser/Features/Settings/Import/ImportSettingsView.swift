//
//  ImportSettingsView.swift
//  Cherry Browser
//
//  Settings → Import: pick an installed browser (and profile), choose what
//  to bring over, and run the import with progress + a result summary.
//

import SwiftUI
import UniformTypeIdentifiers

struct ImportSettingsView: View {
    @State private var service = BrowserImportService()
    @State private var selectedBrowserID: SourceBrowser.ID?
    @State private var selectedProfileID: SourceProfile.ID?
    @State private var selectedTypes: Set<ImportableDataType> = [.bookmarks, .history, .favorites]

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
        SettingsStack {
            sourcesCard
            if selectedSource != nil {
                optionsCard
            }
            csvCard
            if let result = service.lastResult {
                resultCard(result)
            }
        }
        .task {
            await service.detectSources()
            if selectedBrowserID == nil {
                selectBrowser(service.sources.first)
            }
        }
    }

    // MARK: - Source list

    private var sourcesCard: some View {
        SettingsCard(
            icon: "square.and.arrow.down",
            title: "Import From",
            subtitle: "Browsers found on this Mac with importable data"
        ) {
            if service.isDetecting && service.sources.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for installed browsers…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } else if service.sources.isEmpty {
                Text("No other browsers with importable data were found on this Mac.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 4) {
                    ForEach(service.sources) { source in
                        sourceRow(source)
                    }
                }
            }
        }
    }

    private func sourceRow(_ source: DetectedSource) -> some View {
        let isSelected = source.id == selectedBrowserID
        return Button {
            selectBrowser(source)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: source.browser.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? accent : Color.secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 1) {
                    Text(source.browser.displayName)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    Text(source.profiles.count == 1
                         ? source.profiles[0].displayName
                         : "\(source.profiles.count) profiles")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(accent)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? accent.opacity(0.12) : Color.primary.opacity(0.03))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(service.isImporting)
    }

    // MARK: - Options

    private var optionsCard: some View {
        SettingsCard(
            icon: "checklist",
            title: "What to Import",
            subtitle: selectedSource.map { "From \($0.browser.displayName)" }
        ) {
            if let source = selectedSource, source.profiles.count > 1 {
                SettingsLabeledRow(title: "Profile") {
                    CherryPicker(
                        selection: profileBinding,
                        options: source.profiles.map { .init($0.id, $0.displayName) }
                    )
                    .disabled(service.isImporting)
                }
                Divider()
            }

            ForEach(ImportableDataType.allCases) { type in
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
            subtitle: subtitle(for: type, isAvailable: isAvailable),
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

    /// Per-row hint text. Passwords get the Keychain-prompt heads-up when
    /// available, and a nudge toward CSV for browsers we can't decrypt directly.
    private func subtitle(for type: ImportableDataType, isAvailable: Bool) -> String? {
        if type == .passwords {
            if isAvailable {
                let name = selectedSource?.browser.displayName ?? "the browser"
                return "macOS will ask permission to read \(name)’s saved passwords."
            }
            return "Direct import isn’t available here — use “Import Passwords from CSV” below."
        }
        if type == .favorites, isAvailable {
            let name = selectedSource?.browser.displayName ?? "the browser"
            return "Adds \(name)’s bookmarks bar to Cherry’s home screen (first \(BrowserImportService.favoritesImportCap))."
        }
        return isAvailable ? nil : "Not found in this profile"
    }

    private var profileBinding: Binding<SourceProfile.ID> {
        Binding(
            get: { selectedProfile?.id ?? "" },
            set: { selectedProfileID = $0 }
        )
    }

    // MARK: - CSV import

    private var csvCard: some View {
        SettingsCard(
            icon: "doc.text",
            title: "Import Passwords from CSV",
            subtitle: "Works with any browser, including Firefox and Safari"
        ) {
            Text("Export saved passwords to a .csv file from another browser, then choose it here. Cherry reads the url, username, and password columns and skips duplicates.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button {
                    chooseCSVFile()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.badge.plus")
                        Text("Choose CSV File…")
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(accent, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .foregroundStyle(.white)
                    .opacity(service.isImporting ? 0.5 : 1)
                }
                .buttonStyle(.plain)
                .disabled(service.isImporting)

                Spacer(minLength: 0)
            }
        }
    }

    private func chooseCSVFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .text]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose a passwords CSV file exported from another browser"
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await service.importCSV(from: url) }
    }

    // MARK: - Result

    private func resultCard(_ result: ImportResult) -> some View {
        SettingsCard(
            icon: result.errors.isEmpty ? "checkmark.circle" : "exclamationmark.triangle",
            title: result.errors.isEmpty ? "Import Complete" : "Import Finished with Issues",
            subtitle: result.browserName
        ) {
            ForEach(result.summaryLines, id: \.self) { line in
                Label(line, systemImage: "checkmark")
                    .font(.system(size: 12.5))
                    .labelStyle(ImportResultLabelStyle(color: .green))
            }

            ForEach(result.errors, id: \.self) { error in
                Label(error, systemImage: "xmark.octagon")
                    .font(.system(size: 12.5))
                    .labelStyle(ImportResultLabelStyle(color: .orange))
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

    // MARK: - Actions

    private func selectBrowser(_ source: DetectedSource?) {
        selectedBrowserID = source?.id
        selectedProfileID = source?.profiles.first?.id
    }

    private func startImport() {
        guard let source = selectedSource, let profile = selectedProfile else { return }
        let types = importableSelection
        Task {
            await service.runImport(browser: source.browser, profile: profile, types: types)
        }
    }
}

private struct ImportResultLabelStyle: LabelStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            configuration.icon
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
            configuration.title
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
