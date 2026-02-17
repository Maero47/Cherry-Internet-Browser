//
//  SavePasswordBanner.swift
//  Cherry Browser
//

import SwiftUI

struct SavePasswordBanner: View {
    let domain: String
    let username: String
    let onSave: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "key.fill")
                .font(.system(size: 16))
                .foregroundStyle(SettingsManager.shared.accentColor)

            VStack(alignment: .leading, spacing: 1) {
                Text("Save password for \(domain)?")
                    .font(.system(size: 12, weight: .medium))
                if !username.isEmpty {
                    Text(username)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button("Save") {
                onSave()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}
