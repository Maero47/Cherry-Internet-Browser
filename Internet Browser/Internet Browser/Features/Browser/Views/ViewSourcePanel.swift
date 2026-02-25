//
//  ViewSourcePanel.swift
//  Cherry Browser
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ViewSourcePanel: View {
    let html: String
    let pageTitle: String
    let onDismiss: () -> Void

    @State private var searchQuery   = ""
    @State private var matchIndex    = 0
    @State private var fontSize: CGFloat = 11
    @State private var wordWrap      = false
    @State private var copied        = false
    @State private var showGoToLine  = false
    @State private var goToLineText  = ""

    // MARK: - Derived

    private var lines: [String] { html.components(separatedBy: "\n") }

    private var matchingLineIndices: [Int] {
        guard !searchQuery.isEmpty else { return [] }
        return lines.indices.filter { lines[$0].localizedCaseInsensitiveContains(searchQuery) }
    }

    private var activeLineIndex: Int? {
        guard !matchingLineIndices.isEmpty else { return nil }
        return matchingLineIndices[matchIndex % matchingLineIndices.count]
    }

    private var statsLabel: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(html.utf8.count), countStyle: .file)
        return "\(lines.count) lines  ·  \(html.count) chars  ·  \(size)"
    }

    private var gutterWidth: CGFloat {
        CGFloat(max(3, String(lines.count).count)) * (fontSize * 0.62) + 16
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            searchBar
            if showGoToLine { goToLineBar }
            Divider()
            codeScroller
            footerBar
        }
        .frame(width: 580)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 0.5)
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SettingsManager.shared.accentColor)

            VStack(alignment: .leading, spacing: 0) {
                Text("View Source")
                    .font(.system(size: 12, weight: .semibold))
                Text(pageTitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            fontSizeStepper
            iconBtn("text.word.spacing",  on: wordWrap,     tip: wordWrap ? "Disable word wrap" : "Enable word wrap") { wordWrap.toggle() }
            iconBtn("arrow.right.to.line", on: showGoToLine, tip: "Go to line") { showGoToLine.toggle(); if !showGoToLine { goToLineText = "" } }
            iconBtn("arrow.down.doc",      on: false,        tip: "Save source to file") { saveToFile() }
            iconBtn(copied ? "checkmark" : "doc.on.doc", on: copied, tint: copied ? .green : nil, tip: "Copy all source") { copySource() }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(height: 50)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var fontSizeStepper: some View {
        HStack(spacing: 2) {
            Button { fontSize = max(8, fontSize - 1) } label: {
                Image(systemName: "minus")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Decrease font size")

            Text("\(Int(fontSize))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            Button { fontSize = min(20, fontSize + 1) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Increase font size")
        }
        .padding(.horizontal, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .controlBackgroundColor)))
    }

    @ViewBuilder
    private func iconBtn(
        _ icon: String,
        on active: Bool,
        tint: Color? = nil,
        tip: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(tint ?? (active ? SettingsManager.shared.accentColor : .secondary))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tip)
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            TextField("Search source…", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .onChange(of: searchQuery) { _, _ in matchIndex = 0 }

            if !searchQuery.isEmpty {
                if matchingLineIndices.isEmpty {
                    Text("No results")
                        .font(.system(size: 10))
                        .foregroundStyle(.red.opacity(0.8))
                } else {
                    Text("\(matchIndex + 1) of \(matchingLineIndices.count)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()

                    HStack(spacing: 0) {
                        Button {
                            matchIndex = (matchIndex - 1 + matchingLineIndices.count) % matchingLineIndices.count
                        } label: {
                            Image(systemName: "chevron.up")
                                .font(.system(size: 9, weight: .semibold))
                                .frame(width: 22, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button {
                            matchIndex = (matchIndex + 1) % matchingLineIndices.count
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .frame(width: 22, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .background(RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: .controlBackgroundColor)))
                }

                Button { searchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.7))
    }

    // MARK: - Go-to-line bar

    private var goToLineBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.right.to.line")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Text("Go to line:")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            TextField("", text: $goToLineText)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 60)
                .onSubmit { showGoToLine = false }

            Text("of \(lines.count)")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            Spacer()

            Button("Done") { showGoToLine = false; goToLineText = "" }
                .buttonStyle(.plain)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    // MARK: - Code Scroller

    private var codeScroller: some View {
        ScrollViewReader { proxy in
            ScrollView(wordWrap ? [.vertical] : [.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                        codeRow(idx: idx, line: line)
                            .id("L\(idx)")
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: activeLineIndex) { _, newIdx in
                if let n = newIdx {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo("L\(n)", anchor: .center)
                    }
                }
            }
            .onChange(of: goToLineText) { _, text in
                if let n = Int(text), n >= 1, n <= lines.count {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo("L\(n - 1)", anchor: .center)
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder
    private func codeRow(idx: Int, line: String) -> some View {
        let isActive  = idx == activeLineIndex
        let isMatch   = !searchQuery.isEmpty
                     && line.localizedCaseInsensitiveContains(searchQuery)
                     && !isActive
        let isGoTo    = Int(goToLineText).map { $0 - 1 == idx } ?? false

        HStack(alignment: .top, spacing: 0) {
            // Line number gutter
            Text("\(idx + 1)")
                .font(.system(size: max(9, fontSize - 1), design: .monospaced))
                .foregroundStyle(isActive ? AnyShapeStyle(SettingsManager.shared.accentColor) : AnyShapeStyle(.quaternary))
                .fontWeight(isActive ? .semibold : .regular)
                .frame(width: gutterWidth, alignment: .trailing)
                .padding(.trailing, 10)

            // Source content
            let attr = styledLine(line, isActive: isActive)
            if wordWrap {
                Text(attr)
                    .font(.system(size: fontSize, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, 16)
            } else {
                Text(attr)
                    .font(.system(size: fontSize, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.trailing, 16)
            }
        }
        .padding(.vertical, 0.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(isActive: isActive, isMatch: isMatch, isGoTo: isGoTo))
    }

    private func rowBackground(isActive: Bool, isMatch: Bool, isGoTo: Bool) -> Color {
        if isActive { return SettingsManager.shared.accentColor.opacity(0.14) }
        if isGoTo   { return Color.yellow.opacity(0.16) }
        if isMatch  { return SettingsManager.shared.accentColor.opacity(0.06) }
        return .clear
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack {
            Text(statsLabel)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Spacer()

            if !searchQuery.isEmpty {
                Text(
                    matchingLineIndices.isEmpty
                        ? "No matches"
                        : "\(matchingLineIndices.count) match\(matchingLineIndices.count == 1 ? "" : "es")"
                )
                .font(.system(size: 10))
                .foregroundStyle(
                    matchingLineIndices.isEmpty
                        ? AnyShapeStyle(.red.opacity(0.8))
                        : AnyShapeStyle(SettingsManager.shared.accentColor)
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
        }
    }

    // MARK: - Actions

    private func copySource() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(html, forType: .string)
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { copied = false }
        }
    }

    private func saveToFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = "source.html"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? html.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Syntax Highlighting

    /// Builds an `AttributedString` with token-level HTML syntax colours
    /// and overlaid search highlights, all via `NSMutableAttributedString`.
    private func styledLine(_ line: String, isActive: Bool) -> AttributedString {
        let display = line.isEmpty ? " " : line
        let mutable = syntaxColoredMutableString(display)

        // Overlay search matches
        if !searchQuery.isEmpty {
            let ns   = display as NSString
            var loc  = 0
            while loc < ns.length {
                let searchRange = NSRange(location: loc, length: ns.length - loc)
                let found = ns.range(of: searchQuery, options: .caseInsensitive, range: searchRange)
                guard found.location != NSNotFound else { break }

                mutable.addAttribute(.foregroundColor,
                    value: isActive ? NSColor.white : NSColor.systemOrange,
                    range: found)
                mutable.addAttribute(.backgroundColor,
                    value: isActive
                        ? NSColor.controlAccentColor
                        : NSColor.systemOrange.withAlphaComponent(0.22),
                    range: found)

                loc = found.upperBound
            }
        }

        return (try? AttributedString(mutable, including: \.appKit)) ?? AttributedString(display)
    }

    private func syntaxColoredMutableString(_ text: String) -> NSMutableAttributedString {
        let ns   = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let mutable = NSMutableAttributedString(
            string: text,
            attributes: [.foregroundColor: NSColor.labelColor]
        )

        // Rules applied in priority order (later rules win for overlapping ranges)
        let rules: [(pattern: String, color: NSColor)] = [
            // HTML comments   <!-- ... -->
            (#"<!--.*?-->"#,                    NSColor.secondaryLabelColor),
            // DOCTYPE
            (#"<!DOCTYPE[^>]*>"#,               NSColor.systemPurple),
            // CDATA sections
            (#"<!\[CDATA\[.*?\]\]>"#,           NSColor.secondaryLabelColor),
            // Closing tags   </foo>
            (#"</[\w:.-]+\s*>"#,                NSColor.systemBlue),
            // Opening tag name   <foo
            (#"(?<=<)[\w:.-]+"#,                NSColor.systemBlue),
            // Double-quoted attribute values
            (#""[^"]*""#,                       NSColor.systemGreen),
            // Single-quoted attribute values
            (#"'[^']*'"#,                       NSColor.systemGreen),
            // Attribute names (word immediately before =)
            (#"\b[\w:.-]+(?=\s*=)"#,            NSColor.systemTeal),
            // Angle brackets / slashes (subtle)
            (#"</?|/?>"#,                       NSColor.tertiaryLabelColor),
            // HTML entities   &amp;  &#160;
            (#"&(?:[a-zA-Z]+|#\d+|#x[\da-fA-F]+);"#, NSColor.systemOrange),
            // Inline CSS property names   color:
            (#"\b[\w-]+(?=\s*:)"#,              NSColor.systemTeal),
            // Inline CSS values (after colon, up to ; or })
            (#"(?<=:)\s*[^;}{>\"']+(?=[;}{])"#, NSColor.systemGreen),
            // JS strings inside attributes/scripts
            (#"`[^`]*`"#,                       NSColor.systemGreen),
        ]

        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { continue }
            for match in regex.matches(in: text, range: full) {
                mutable.addAttribute(.foregroundColor, value: rule.color, range: match.range)
            }
        }

        return mutable
    }
}
