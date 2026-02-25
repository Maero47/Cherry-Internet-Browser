//
//  DevToolsPanelView.swift
//  Cherry Browser
//

import SwiftUI

struct DevToolsPanelView: View {
    @State private var devTools = DevToolsManager.shared
    @State private var selectedTab: DevToolsTab = .console
    @State private var consoleFilter: ConsoleLevel? = nil
    @State private var networkFilter: String = ""

    // REPL state
    @State private var replInput: String = ""
    @State private var replHistory: [String] = []
    @State private var replHistoryIndex: Int = -1
    @FocusState private var replFocused: Bool

    // Elements state
    @State private var editedHTML: String = ""
    @State private var applyFeedback: String = ""

    // Closures provided by BrowserViewModel
    var onEvaluateJS: ((String, @escaping (String?) -> Void) -> Void)? = nil
    var onHighlightElement: ((String) -> Void)? = nil
    var onApplyHTML: ((String, String, @escaping (String?) -> Void) -> Void)? = nil
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            tabContent
        }
        .frame(height: 300)
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            selectedTab = devTools.activeDevToolsTab
        }
        .onChange(of: devTools.activeDevToolsTab) { _, tab in
            selectedTab = tab
        }
        .onChange(of: devTools.inspectedElement?.outerHTML) { _, html in
            editedHTML = html ?? ""
            applyFeedback = ""
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 0) {
            // Tab switcher
            HStack(spacing: 0) {
                ForEach(DevToolsTab.allCases, id: \.self) { tab in
                    Button { selectedTab = tab } label: {
                        Label(tab.rawValue, systemImage: tab.icon)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(selectedTab == tab
                                ? SettingsManager.shared.accentColor.opacity(0.12)
                                : Color.clear)
                            .foregroundStyle(selectedTab == tab ? .primary : .secondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()

            // Level filter pills (console tab)
            if selectedTab == .console {
                HStack(spacing: 4) {
                    levelPill(nil, label: "All")
                    ForEach(ConsoleLevel.filterCases, id: \.self) { level in
                        levelPill(level, label: level.rawValue.capitalized)
                    }
                }
                .padding(.trailing, 8)
            }

            // URL filter (network tab)
            if selectedTab == .network {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    TextField("Filter URL", text: $networkFilter)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .frame(width: 140)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(Color(nsColor: .controlBackgroundColor)))
                .padding(.trailing, 8)
            }

            // Clear button
            Button {
                switch selectedTab {
                case .console:  devTools.clearConsole()
                case .network:  devTools.clearNetwork()
                case .elements: devTools.inspectedElement = nil; editedHTML = ""
                }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Clear")
            .padding(.trailing, 6)

            // Close
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
        }
        .padding(.leading, 8)
        .frame(height: 36)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Level Pill

    @ViewBuilder
    private func levelPill(_ level: ConsoleLevel?, label: String) -> some View {
        Button {
            consoleFilter = (consoleFilter == level) ? nil : level
        } label: {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(
                    consoleFilter == level
                        ? (level?.color ?? Color.primary).opacity(0.18)
                        : Color(nsColor: .controlBackgroundColor)
                ))
                .foregroundStyle(level?.color ?? .primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .console:  consolePane
        case .network:  networkPane
        case .elements: elementsPane
        }
    }

    // =========================================================
    // MARK: - Console Pane
    // =========================================================

    private var filteredConsole: [ConsoleEntry] {
        guard let f = consoleFilter else { return devTools.consoleEntries }
        return devTools.consoleEntries.filter { $0.level == f }
    }

    @ViewBuilder
    private var consolePane: some View {
        VStack(spacing: 0) {
            // Log list
            if devTools.consoleEntries.isEmpty {
                emptyState(icon: "terminal", message: "No console output yet")
            } else {
                ScrollViewReader { proxy in
                    List(filteredConsole) { entry in
                        consoleRow(entry)
                            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                            .listRowBackground(
                                entry.level == .error  ? Color.red.opacity(0.06)
                                : entry.level == .warn ? Color.orange.opacity(0.06)
                                : entry.level == .repl ? Color(nsColor: .systemPurple).opacity(0.04)
                                : Color.clear
                            )
                    }
                    .listStyle(.plain)
                    .onChange(of: devTools.consoleEntries.count) { _, _ in
                        if let last = devTools.consoleEntries.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
            }

            // REPL input bar
            replInputBar
        }
    }

    @ViewBuilder
    private func consoleRow(_ entry: ConsoleEntry) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(entry.timestampString)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 82, alignment: .leading)

            Image(systemName: entry.level.icon)
                .font(.system(size: 10))
                .foregroundStyle(entry.level.color)
                .frame(width: 14)

            Text(entry.message)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(entry.level.color)
                .textSelection(.enabled)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
    }

    // MARK: REPL Input

    private var replInputBar: some View {
        HStack(spacing: 6) {
            Text("▶")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(SettingsManager.shared.accentColor)

            TextField("Run JavaScript…", text: $replInput)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .focused($replFocused)
                .onSubmit { runREPL() }

            if !replInput.isEmpty {
                Button { runREPL() } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(SettingsManager.shared.accentColor)
                }
                .buttonStyle(.plain)
                .help("Run (↵)")
            }

            // History navigation
            if !replHistory.isEmpty {
                HStack(spacing: 2) {
                    Button {
                        let newIdx = min(replHistoryIndex + 1, replHistory.count - 1)
                        replHistoryIndex = newIdx
                        replInput = replHistory[replHistory.count - 1 - newIdx]
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Previous command")

                    Button {
                        if replHistoryIndex <= 0 {
                            replHistoryIndex = -1
                            replInput = ""
                        } else {
                            replHistoryIndex -= 1
                            replInput = replHistory[replHistory.count - 1 - replHistoryIndex]
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Next command")
                }
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: .controlBackgroundColor)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
        }
    }

    private func runREPL() {
        let command = replInput.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else { return }

        // Log the command
        devTools.appendConsole(ConsoleEntry(level: .repl, message: command))

        // Save to history
        replHistory.append(command)
        replHistoryIndex = -1
        replInput = ""

        // Execute
        onEvaluateJS?(command) { result in
            let output = result ?? "undefined"
            devTools.appendConsole(ConsoleEntry(level: .result, message: output))
        }
    }

    // =========================================================
    // MARK: - Network Pane
    // =========================================================

    private var filteredNetwork: [NetworkEntry] {
        guard !networkFilter.isEmpty else { return devTools.networkEntries }
        return devTools.networkEntries.filter {
            $0.url.localizedCaseInsensitiveContains(networkFilter)
        }
    }

    @ViewBuilder
    private var networkPane: some View {
        if devTools.networkEntries.isEmpty {
            emptyState(icon: "network", message: "No network requests captured yet.\nNavigate to a page to see traffic.")
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("Method").frame(width: 58, alignment: .leading)
                    Text("Status").frame(width: 52, alignment: .leading)
                    Text("URL").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Time").frame(width: 64, alignment: .trailing)
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color(nsColor: .windowBackgroundColor))

                Divider()

                List(filteredNetwork) { entry in
                    networkRow(entry)
                        .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                        .listRowBackground(entry.isError ? Color.red.opacity(0.06) : Color.clear)
                }
                .listStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func networkRow(_ entry: NetworkEntry) -> some View {
        HStack(spacing: 0) {
            Text(entry.method)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(entry.methodColor)
                .frame(width: 58, alignment: .leading)

            Group {
                if let code = entry.statusCode {
                    Text("\(code)").foregroundStyle(entry.statusColor)
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .frame(width: 52, alignment: .leading)

            Text(entry.displayURL)
                .font(.system(size: 11))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(entry.url)

            Group {
                if let ms = entry.responseTimeMs {
                    Text(ms < 1000
                         ? String(format: "%.0fms", ms)
                         : String(format: "%.2fs", ms / 1000))
                        .foregroundStyle(ms > 2000 ? .orange : .secondary)
                } else {
                    Text("…").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .frame(width: 64, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    // =========================================================
    // MARK: - Elements Pane
    // =========================================================

    @ViewBuilder
    private var elementsPane: some View {
        if devTools.inspectedElement == nil {
            emptyState(
                icon: "rectangle.3.offgrid",
                message: "Right-click any element and choose\n\"Inspect Element\" to inspect it."
            )
        } else {
            elementsPaneContent
        }
    }

    @ViewBuilder
    private var elementsPaneContent: some View {
        if let el = devTools.inspectedElement {
            VStack(spacing: 0) {
                // Top bar: element name + actions
                elementsTopBar(el)
                Divider()

                // Split: HTML editor | Computed Styles
                HStack(spacing: 0) {
                    htmlEditor(el)
                    Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 0.5)
                    computedStyles(el)
                }
            }
            .onAppear {
                if editedHTML.isEmpty { editedHTML = el.outerHTML }
            }
        }
    }

    private func elementsTopBar(_ el: InspectedElement) -> some View {
        HStack(spacing: 8) {
            // Tag badge
            Text("<\(el.tag)>")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(nsColor: .systemBlue))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color(nsColor: .systemBlue).opacity(0.1)))

            // ID
            if !el.id.isEmpty {
                Text("#\(el.id)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(nsColor: .systemOrange))
            }

            // Classes (first two)
            let classTokens = el.classes.split(separator: " ").prefix(2)
            ForEach(Array(classTokens.enumerated()), id: \.offset) { _, cls in
                Text(".\(cls)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(nsColor: .systemGreen))
            }

            Spacer()

            // Feedback
            if !applyFeedback.isEmpty {
                Text(applyFeedback)
                    .font(.system(size: 10))
                    .foregroundStyle(applyFeedback.hasPrefix("✓") ? .green : .red)
            }

            // Highlight button
            Button {
                guard !el.selector.isEmpty else { return }
                onHighlightElement?(el.selector)
            } label: {
                Label("Highlight", systemImage: "scope")
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsManager.shared.accentColor)
            }
            .buttonStyle(.plain)
            .help("Flash element outline on page")
            .padding(.trailing, 4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func htmlEditor(_ el: InspectedElement) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("HTML")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    applyHTMLChange(selector: el.selector)
                } label: {
                    Label("Apply", systemImage: "checkmark.circle")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(SettingsManager.shared.accentColor)
                }
                .buttonStyle(.plain)
                .help("Apply HTML changes to live page")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))

            TextEditor(text: $editedHTML)
                .font(.system(size: 11, design: .monospaced))
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func computedStyles(_ el: InspectedElement) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Computed Styles")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(sortedStyles(el.styles), id: \.key) { item in
                        styleRow(property: item.key, value: item.value)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .frame(width: 240)
    }

    @ViewBuilder
    private func styleRow(property: String, value: String) -> some View {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty && trimmed != "none" && trimmed != "auto" || isLayoutProp(property) else {
            return AnyView(EmptyView())
        }
        return AnyView(
            HStack(alignment: .top, spacing: 4) {
                Text(property)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color(nsColor: .systemTeal))
                    .frame(minWidth: 0, maxWidth: 130, alignment: .leading)
                    .lineLimit(1)
                Text(trimmed)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(styleValueColor(property: property, value: trimmed))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
        )
    }

    private func isLayoutProp(_ p: String) -> Bool {
        ["display", "position", "width", "height", "overflow", "box-sizing"].contains(p)
    }

    private func styleValueColor(property: String, value: String) -> Color {
        if value.hasPrefix("rgb") || value.hasPrefix("#") { return Color(nsColor: .systemGreen) }
        if value.hasPrefix("url") { return Color(nsColor: .systemOrange) }
        if let _ = Double(value.replacingOccurrences(of: "px", with: "")
            .replacingOccurrences(of: "em", with: "")
            .replacingOccurrences(of: "%", with: "")) {
            return Color(nsColor: .systemOrange)
        }
        return .primary
    }

    private func sortedStyles(_ styles: [String: String]) -> [(key: String, value: String)] {
        // Layout properties first, then alpha
        let priority = ["display", "position", "width", "height", "overflow",
                        "margin-top", "margin-right", "margin-bottom", "margin-left",
                        "padding-top", "padding-right", "padding-bottom", "padding-left",
                        "color", "background-color", "font-size", "font-family",
                        "font-weight", "border-radius", "opacity", "z-index"]
        var result = styles.map { (key: $0.key, value: $0.value) }
        result.sort { a, b in
            let ai = priority.firstIndex(of: a.key) ?? 999
            let bi = priority.firstIndex(of: b.key) ?? 999
            if ai != bi { return ai < bi }
            return a.key < b.key
        }
        return result
    }

    private func applyHTMLChange(selector: String) {
        let base64 = Data(editedHTML.utf8).base64EncodedString()
        onApplyHTML?(selector, base64) { result in
            if result == "ok" {
                applyFeedback = "✓ Applied"
            } else {
                applyFeedback = "✗ \(result ?? "error")"
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { applyFeedback = "" }
        }
    }

    // =========================================================
    // MARK: - Empty State
    // =========================================================

    @ViewBuilder
    private func emptyState(icon: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
