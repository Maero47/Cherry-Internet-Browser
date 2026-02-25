//
//  FocusModeSettingsView.swift
//  Cherry Browser
//

import SwiftUI

struct FocusModeSettingsView: View {
    @State private var manager = FocusModeManager.shared
    @State private var newDomain: String = ""
    @State private var showAddField: Bool = false
    @FocusState private var addFieldFocused: Bool

    private let quickAddSites: [(String, String)] = [
        ("Twitter / X", "twitter.com"),
        ("Reddit", "reddit.com"),
        ("YouTube", "youtube.com"),
        ("Instagram", "instagram.com"),
        ("Facebook", "facebook.com"),
        ("TikTok", "tiktok.com"),
        ("Netflix", "netflix.com"),
        ("LinkedIn", "linkedin.com")
    ]

    var body: some View {
        Form {
            // MARK: Status
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(manager.focusModeEnabled ? "Focus Mode is On" : "Focus Mode is Off")
                            .font(.system(size: 13, weight: .medium))
                        Text(manager.focusModeEnabled
                             ? "Blocked sites are inaccessible."
                             : "Enable to block distracting sites.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { manager.focusModeEnabled },
                        set: { _ in manager.toggleFocusMode() }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }

                if manager.focusModeEnabled {
                    Button(role: .destructive) {
                        manager.stopFocusMode()
                    } label: {
                        Label("End Focus Session", systemImage: "stop.circle")
                    }
                } else {
                    Button {
                        manager.startFocusMode()
                    } label: {
                        Label("Start Focus Session", systemImage: "play.circle")
                    }
                }
            } header: {
                Text("Focus Mode")
            }

            // MARK: Timer
            Section {
                Toggle("Session Timer", isOn: $manager.timerEnabled)

                if manager.timerEnabled {
                    Picker("Duration", selection: $manager.timerDurationMinutes) {
                        Text("15 minutes").tag(15)
                        Text("25 minutes").tag(25)
                        Text("30 minutes").tag(30)
                        Text("45 minutes").tag(45)
                        Text("60 minutes").tag(60)
                        Text("90 minutes").tag(90)
                        Text("2 hours").tag(120)
                    }
                    .pickerStyle(.menu)
                }

                if manager.focusModeEnabled && manager.sessionEndDate != nil {
                    HStack {
                        Image(systemName: "clock")
                            .foregroundStyle(SettingsManager.shared.accentColor)
                        Text("Time remaining: \(manager.timeRemainingFormatted)")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Timer")
            } footer: {
                Text("Focus mode will automatically stop when the timer ends.")
            }

            // MARK: Blocked Sites
            Section {
                if manager.blockedDomains.isEmpty {
                    Text("No sites blocked yet. Add sites below.")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                } else {
                    ForEach(manager.blockedDomains, id: \.self) { domain in
                        HStack {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red.opacity(0.7))
                                .font(.system(size: 13))
                            Text(domain)
                                .font(.system(size: 13, design: .monospaced))
                            Spacer()
                            Button {
                                manager.removeDomain(domain)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.secondary)
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Add domain row
                if showAddField {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(SettingsManager.shared.accentColor)
                            .font(.system(size: 13))
                        TextField("e.g. reddit.com", text: $newDomain)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .focused($addFieldFocused)
                            .onSubmit { commitNewDomain() }
                        Button("Add") {
                            commitNewDomain()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(newDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Cancel") {
                            newDomain = ""
                            showAddField = false
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .controlSize(.small)
                    }
                } else {
                    Button {
                        showAddField = true
                        addFieldFocused = true
                    } label: {
                        Label("Add a site to block", systemImage: "plus")
                    }
                }
            } header: {
                Text("Blocked Sites")
            }

            // MARK: Quick Add
            Section {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(quickAddSites, id: \.1) { name, domain in
                        let isBlocked = manager.blockedDomains.contains(domain)
                        Button {
                            if isBlocked {
                                manager.removeDomain(domain)
                            } else {
                                manager.addDomain(domain)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: isBlocked ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isBlocked ? SettingsManager.shared.accentColor : .secondary)
                                    .font(.system(size: 13))
                                Text(name)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(isBlocked
                                          ? SettingsManager.shared.accentColor.opacity(0.1)
                                          : Color.primary.opacity(0.04))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text("Quick Block")
            } footer: {
                Text("Tap to toggle a site on or off your block list.")
            }
        }
        .formStyle(.grouped)
    }

    private func commitNewDomain() {
        let trimmed = newDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            manager.addDomain(trimmed)
        }
        newDomain = ""
        showAddField = false
    }
}
