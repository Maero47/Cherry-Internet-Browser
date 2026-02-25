//
//  FocusBlockView.swift
//  Cherry Browser
//

import SwiftUI

struct FocusBlockView: View {
    let blockedHost: String
    let onOverride: () -> Void
    let onDisableFocus: () -> Void
    let onDismiss: () -> Void

    @State private var manager = FocusModeManager.shared
    @State private var timerTick: Bool = false

    var body: some View {
        ZStack {
            // Dark glass background
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            Color.black.opacity(0.55)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Brain icon
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 88, height: 88)
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 38, weight: .light))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .padding(.bottom, 28)

                // Title
                Text("Stay Focused")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.bottom, 10)

                // Blocked domain badge
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.red.opacity(0.8))
                    Text(blockedHost)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.07))
                        .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                )
                .padding(.bottom, 32)

                // Timer or info
                if manager.sessionEndDate != nil {
                    VStack(spacing: 5) {
                        Text("Focus session ends in")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.4))
                            .textCase(.uppercase)
                            .kerning(0.8)
                        Text(manager.timeRemainingFormatted)
                            .font(.system(size: 44, weight: .thin, design: .monospaced))
                            .foregroundStyle(.white)
                            .id(manager.timeRemainingFormatted) // force redraw each second
                    }
                    .padding(.bottom, 44)
                } else {
                    Text("This site is blocked while focus mode is active.")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.45))
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 44)
                }

                // Action buttons
                VStack(spacing: 10) {
                    // Override button
                    Button(action: onOverride) {
                        HStack(spacing: 8) {
                            Image(systemName: "clock.arrow.2.circlepath")
                            Text("Allow for 5 minutes")
                        }
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 280, height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 11)
                                .fill(Color.white.opacity(0.11))
                                .stroke(Color.white.opacity(0.14), lineWidth: 0.5)
                        )
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)

                    // Disable focus mode button
                    Button(action: onDisableFocus) {
                        HStack(spacing: 8) {
                            Image(systemName: "xmark.circle")
                            Text("Turn off Focus Mode")
                        }
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 280, height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 11)
                                .fill(Color.red.opacity(0.18))
                                .stroke(Color.red.opacity(0.25), lineWidth: 0.5)
                        )
                        .foregroundStyle(Color.red.opacity(0.85))
                    }
                    .buttonStyle(.plain)

                    // Go back
                    Button(action: onDismiss) {
                        Text("Go back")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
