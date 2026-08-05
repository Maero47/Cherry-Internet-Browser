//
//  CherryPicker.swift
//  Cherry Browser
//

import SwiftUI
import AppKit

/// The Cherry-drawn replacement for `Picker(...).pickerStyle(.menu)`.
///
/// A `Picker` in menu style is an `NSPopUpButton`, so its list is an `NSMenu`
/// and its highlight was cherry red like every other menu in the app. This
/// draws the same control, opens `CherryMenuController` for the list, and marks
/// the current value with a checkmark.
///
/// It keeps the popup-button *keyboard contract*, not just the menu's: with the
/// control focused and the list shut, ↑/↓ step through the values the way
/// `NSPopUpButton` does, and Space or Return opens the list. Without that, a
/// keyboard user would have lost something in the conversion.
struct CherryPicker<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let title: String
        var systemImage: String?

        init(_ value: Value, _ title: String, systemImage: String? = nil) {
            self.value = value
            self.title = title
            self.systemImage = systemImage
        }

        var id: Value { value }
    }

    @Binding var selection: Value
    let options: [Option]

    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isFocused: Bool
    @State private var isOpen = false
    @State private var anchor = CherryMenuAnchor()

    private var current: Option? { options.first { $0.value == selection } }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 7) {
                if let symbol = current?.systemImage {
                    Image(systemName: symbol).font(.system(size: 12))
                }
                Text(current?.title ?? "")
                    .font(.system(size: 13))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 9)
            .padding(.trailing, 7)
            .frame(height: 22)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .controlColor))
                    .shadow(color: .black.opacity(0.12), radius: 0.5, y: 0.5)
            }
            .overlay {
                // `SettingsManager.accentColor`, not `Color.accentColor`: the
                // latter reads the `AccentColor` asset, which is deliberately
                // neutral so that what macOS draws for us does not clash with
                // the user's choice. A ring drawn by Cherry follows the choice.
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        isFocused ? SettingsManager.shared.accentColor : Color.primary.opacity(0.10),
                        lineWidth: isFocused ? 2 : 0.5
                    )
            }
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(isEnabled)
        .focused($isFocused)
        .onKeyPress(.upArrow) { step(-1) }
        .onKeyPress(.downArrow) { step(1) }
        .onKeyPress(.space) { open(); return .handled }
        .onKeyPress(.return) { open(); return .handled }
        .background { CherryPickerAccessibility(title: current?.title ?? "", onPress: open) }
        .background { CherryMenuAnchorReader(anchor: anchor) }
    }

    private func open() {
        guard isEnabled, let frame = anchor.screenFrame, !options.isEmpty else { return }
        isOpen = true
        CherryMenuController.shared.present(
            options.map { option in
                CherryMenuItem.action(option.title, systemImage: option.systemImage, on: option.value == selection) {
                    selection = option.value
                }
            },
            placement: .below(frame),
            parentWindow: anchor.window
        ) {
            isOpen = false
        }
    }

    /// ↑/↓ with the list shut, exactly as `NSPopUpButton` behaves: it moves the
    /// value, and it stops at the ends rather than wrapping.
    private func step(_ delta: Int) -> KeyPress.Result {
        guard let index = options.firstIndex(where: { $0.value == selection }) else { return .ignored }
        let next = index + delta
        guard options.indices.contains(next) else { return .handled }
        selection = options[next].value
        return .handled
    }
}

/// Publishes the control as an `AXPopUpButton` whose value is the chosen row —
/// what `NSPopUpButton` publishes, and what an assistive client needs in order
/// to say "Search Engine, Google, pop up button" rather than describing a
/// generic button with some text in it.
private struct CherryPickerAccessibility: NSViewRepresentable {
    let title: String
    let onPress: () -> Void

    func makeNSView(context: Context) -> PopUpAXView {
        let view = PopUpAXView()
        view.title = title
        view.onPress = onPress
        return view
    }

    func updateNSView(_ view: PopUpAXView, context: Context) {
        view.title = title
        view.onPress = onPress
    }

    final class PopUpAXView: NSView {
        var title: String = ""
        var onPress: (() -> Void)?

        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .popUpButton }
        override func accessibilityValue() -> Any? { title }
        override func accessibilityPerformPress() -> Bool { onPress?(); return true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
