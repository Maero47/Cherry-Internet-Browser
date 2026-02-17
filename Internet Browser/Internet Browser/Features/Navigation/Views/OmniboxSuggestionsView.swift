//
//  OmniboxSuggestionsView.swift
//  Internet Browser
//

import SwiftUI

struct OmniboxSuggestionsView: View {
    let suggestions: [SuggestionItem]
    var selectedIndex: Int?
    let onSelect: (SuggestionItem) -> Void

    @State private var hoveredIndex: Int?

    private func isHighlighted(_ index: Int) -> Bool {
        if let hoveredIndex { return hoveredIndex == index }
        if let selectedIndex { return selectedIndex == index }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.prefix(8).enumerated()), id: \.element.id) { index, item in
                Button {
                    onSelect(item)
                } label: {
                    suggestionRow(item: item, isHighlighted: isHighlighted(index))
                }
                .buttonStyle(.plain)
                .onHover { isHovered in
                    hoveredIndex = isHovered ? index : nil
                }
            }
        }
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.ultraThickMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }

    @ViewBuilder
    private func suggestionRow(item: SuggestionItem, isHighlighted: Bool) -> some View {
        HStack(spacing: 8) {
            switch item {
            case .history(_, let url):
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.displayText)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .foregroundStyle(.primary)

                    Text(url.absoluteString)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .foregroundStyle(.tertiary)
                }

            case .search:
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)

                Text(item.displayText)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHighlighted ? Color.gray.opacity(0.15) : Color.clear)
        )
        .contentShape(Rectangle())
    }
}
