//
//  PasswordAutoFillPopup.swift
//  Cherry Browser
//

import SwiftUI
import AppKit

struct PasswordAutoFillPopup: View {
    let credentials: [PasswordItem]
    let onSelect: (PasswordItem) -> Void
    let onGenerate: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "key.fill")
                    .foregroundStyle(SettingsManager.shared.accentColor)
                Text("Auto-Fill Password")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if credentials.isEmpty {
                Text("No saved passwords for this site")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else {
                // Use VStack for few items, ScrollView only when needed
                credentialsList
            }

            Divider()

            // Generate password option
            Button {
                onGenerate()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 11))
                    Text("Generate Password")
                        .font(.system(size: 11))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(SettingsManager.shared.accentColor)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 240)
        .background(.ultraThickMaterial)
        .cornerRadius(8)
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
    }

    @ViewBuilder
    private var credentialsList: some View {
        let items = VStack(spacing: 0) {
            ForEach(credentials) { credential in
                credentialRow(credential)
            }
        }

        if credentials.count > 4 {
            ScrollView {
                items
            }
            .frame(maxHeight: 150)
        } else {
            items
        }
    }

    private func credentialRow(_ credential: PasswordItem) -> some View {
        Button {
            onSelect(credential)
        } label: {
            HStack(spacing: 8) {
                if let data = credential.faviconData, let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: 14, height: 14)
                        .cornerRadius(2)
                } else {
                    Image(systemName: "globe")
                        .frame(width: 14, height: 14)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 0) {
                    Text(credential.domain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(credential.username)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
