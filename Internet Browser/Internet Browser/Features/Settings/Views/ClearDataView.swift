//
//  ClearDataView.swift
//  Cherry Browser
//

import SwiftUI

struct ClearDataView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var clearHistory = true
    @State private var clearCookies = true
    @State private var clearCache = true
    @State private var timeRange: TimeRange = .allTime
    @State private var isClearing = false

    enum TimeRange: String, CaseIterable, Identifiable {
        case lastHour = "Last Hour"
        case last24Hours = "Last 24 Hours"
        case allTime = "All Time"

        var id: String { rawValue }

        var date: Date? {
            switch self {
            case .lastHour: return Calendar.current.date(byAdding: .hour, value: -1, to: Date())
            case .last24Hours: return Calendar.current.date(byAdding: .day, value: -1, to: Date())
            case .allTime: return nil
            }
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Clear Browsing Data")
                .font(.headline)

            Form {
                Picker("Time Range", selection: $timeRange) {
                    ForEach(TimeRange.allCases) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .pickerStyle(.menu)

                Toggle("Browsing History", isOn: $clearHistory)
                Toggle("Cookies & Site Data", isOn: $clearCookies)
                Toggle("Cached Files", isOn: $clearCache)
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Clear Data") {
                    isClearing = true
                    Task {
                        await SettingsManager.shared.clearBrowsingData(
                            history: clearHistory,
                            cookies: clearCookies,
                            cache: clearCache,
                            since: timeRange.date
                        )
                        isClearing = false
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isClearing || (!clearHistory && !clearCookies && !clearCache))
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal)
        }
        .padding()
        .frame(width: 380, height: 320)
    }
}
