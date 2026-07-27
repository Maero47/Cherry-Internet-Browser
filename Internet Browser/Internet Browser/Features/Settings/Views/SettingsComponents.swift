//
//  SettingsComponents.swift
//  Cherry Browser
//
//  Shared building blocks for the settings surfaces: rounded cards with
//  SF Symbol headers, labeled/toggle rows, and accent-aware swatches.
//

import SwiftUI

/// Vertical stack of settings cards with a consistent column width.
struct SettingsStack<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .frame(maxWidth: 620, alignment: .leading)
    }
}

/// A rounded settings card with an accent-tinted SF Symbol header.
struct SettingsCard<Content: View>: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content

    private var accent: Color { SettingsManager.shared.accentColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 28, height: 28)
                    .background(accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Divider()
                .padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 12) { content }
                .padding(16)
        }
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        }
    }
}

/// Title (+ optional subtitle) on the left, an accent-tinted switch on the right.
struct SettingsToggleRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

/// Title (+ optional subtitle) on the left, any control on the right.
struct SettingsLabeledRow<Control: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
    }
}

/// One customisable navigation-bar button in General ▸ Toolbar: its icon and
/// name, ↑/↓ to move it, and an eye button to take it off the bar.
///
/// The eye is a button rather than a `Toggle` switch because the state it
/// reports is "shown / hidden", which the eye and `eye.slash` symbols say at a
/// glance and in one control the row already has room for.
struct ToolbarItemRow: View {
    let item: ToolbarItem
    let isHidden: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onToggleHidden: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    private var accent: Color { SettingsManager.shared.accentColor }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.systemImage)
                .font(.system(size: 12))
                .foregroundStyle(isHidden ? Color.secondary : accent)
                .frame(width: 20)

            Text(item.title)
                .font(.system(size: 13))
                .foregroundStyle(isHidden ? .secondary : .primary)

            Spacer(minLength: 12)

            HStack(spacing: 2) {
                Button(action: onMoveUp) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(!canMoveUp)
                .help("Move \(item.title) left")
                .accessibilityLabel("Move \(item.title) left")

                Button(action: onMoveDown) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(!canMoveDown)
                .help("Move \(item.title) right")
                .accessibilityLabel("Move \(item.title) right")
            }

            Button(action: onToggleHidden) {
                Image(systemName: isHidden ? "eye.slash" : "eye")
                    .font(.system(size: 12))
                    .foregroundStyle(isHidden ? Color.secondary : accent)
                    .frame(width: 26, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(isHidden
                  ? "\(item.title) is hidden — click to show it in the toolbar"
                  : "Hide \(item.title) from the toolbar (it stays in the ⋯ menu)")
            .accessibilityLabel(isHidden ? "Show \(item.title)" : "Hide \(item.title)")
        }
    }
}

/// Circular accent-color swatch with hover scale, selection ring and checkmark.
struct AccentSwatch: View {
    let option: AccentColorOption
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(option.color)
                    .frame(width: 26, height: 26)
                    .shadow(color: option.color.opacity(isSelected || isHovering ? 0.5 : 0), radius: 5, y: 1)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }

                Circle()
                    .strokeBorder(option.color.opacity(isSelected ? 0.9 : 0), lineWidth: 2)
                    .frame(width: 34, height: 34)
            }
            .frame(width: 34, height: 34)
            .scaleEffect(isHovering ? 1.12 : 1)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .help(option.name)
        .accessibilityLabel(option.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// What a `HomepageSwatch` shows in its tile — the same three background
/// kinds the homepage itself can paint, so a swatch always previews what the
/// user will actually get.
enum HomepageSwatchPreview {
    /// A mini version of a mesh-gradient background.
    case gradient([Color])
    /// A thumbnail of the real wallpaper image the homepage would draw.
    case wallpaper(assetName: String)
    /// A flat fill — an imported Firefox theme's `ntp_background`.
    case flat(Color)
}

/// Homepage-background tile: a preview of the actual background with a
/// caption, an accent selection ring, and an optional overlay icon (used by
/// "Auto").
struct HomepageSwatch: View {
    let name: String
    let preview: HomepageSwatchPreview
    let isSelected: Bool
    var icon: String? = nil
    let action: () -> Void

    @State private var isHovering = false
    private var accent: Color { SettingsManager.shared.accentColor }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                previewTile
                    .frame(height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        if let icon {
                            Image(systemName: icon)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.92))
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(
                                isSelected ? accent : Color.primary.opacity(isHovering ? 0.25 : 0.08),
                                lineWidth: isSelected ? 2 : 1
                            )
                    }
                    .shadow(color: isSelected ? accent.opacity(0.35) : .clear, radius: 5, y: 1)

                Text(name)
                    .font(.system(size: 10.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
            .scaleEffect(isHovering ? 1.03 : 1)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Each case draws what the homepage draws, *including* the wash or scrim
    /// the homepage lays on top — a swatch showing the raw gradient or the raw
    /// wallpaper reads far more saturated than the background it stands for.
    /// The flat case is the one that gets neither, because an imported theme's
    /// absolute `ntp_background` gets neither on the homepage either.
    @ViewBuilder
    private var previewTile: some View {
        switch preview {
        case .gradient(let colors):
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay { HomepageGradientWash() }
        case .wallpaper(let assetName):
            Image(assetName)
                .resizable()
                .scaledToFill()
                .overlay { HomepageWallpaperScrim(startRadius: 8, endRadius: 72) }
        case .flat(let color):
            color
        }
    }
}
