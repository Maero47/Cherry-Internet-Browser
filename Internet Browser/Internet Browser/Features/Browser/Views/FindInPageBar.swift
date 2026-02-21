//
//  FindInPageBar.swift
//  Cherry Browser
//

import SwiftUI

struct FindInPageBar: View {
    @Binding var query: String
    let currentMatch: Int
    let totalMatches: Int
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onDismiss: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))

                TextField("Find in page", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($isFocused)
                    .onSubmit { onNext() }
                    .frame(minWidth: 120)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )

            if !query.isEmpty {
                Text(totalMatches > 0 ? "\(currentMatch)/\(totalMatches)" : "No matches")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Button(action: onPrevious) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .disabled(totalMatches == 0)

            Button(action: onNext) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .disabled(totalMatches == 0)

            Divider()
                .frame(height: 16)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .onAppear {
            isFocused = true
        }
    }
}
