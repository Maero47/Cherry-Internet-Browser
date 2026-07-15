//
//  AskThisPagePanel.swift
//  Cherry Browser
//

import SwiftUI

/// Which set of tabs "Ask This Page" answers from.
enum AskThisPageMode: String, CaseIterable, Identifiable {
    case thisPage = "This Page"
    case allTabs = "All Tabs"

    var id: String { rawValue }
}

/// Trailing side panel for on-device page Q&A, and (in All Tabs mode) cited
/// research over every eligible open tab. Mirrors `ViewSourcePanel`'s shape
/// (fixed-width trailing panel with a header bar + dismiss button) since
/// it's the closest existing precedent for a panel driven by pre-fetched
/// page content.
struct AskThisPagePanel: View {
    let pageTitle: String
    let pageText: String
    let tabManager: TabManager
    let onDismiss: () -> Void

    @StateObject private var chatSession = PageChatSession()
    @StateObject private var researchSession = TabsResearchSession()
    @State private var mode: AskThisPageMode = .thisPage
    @State private var draft: String = ""

    private let availability = PageAIService.availability

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if !availability.isAvailable {
                unavailableView
            } else {
                modePicker
                Divider()
                switch mode {
                case .thisPage:
                    if pageText.isEmpty { noContentView } else { chatContent }
                case .allTabs:
                    researchContent
                }
            }
        }
        .frame(width: 380)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 0.5)
        }
        .task(id: pageText) {
            guard availability.isAvailable, !pageText.isEmpty else { return }
            chatSession.configure(pageTitle: pageTitle, pageText: pageText, summary: nil)
        }
        // Re-gather whenever All Tabs mode is active AND the set of open tabs
        // changes (a tab opened/closed), so the research index and the tab-count
        // status stay live instead of frozen on the first snapshot. Keyed on the
        // tab-ID set: switching INTO All Tabs, or opening/closing a tab while in
        // it, both change the key and re-run prepare (a no-op when the content
        // snapshot is unchanged, since buildIndex caches by content equality).
        .task(id: allTabsGatherKey) {
            guard mode == .allTabs, availability.isAvailable else { return }
            await researchSession.prepare(tabManager: tabManager)
        }
    }

    /// Empty outside All Tabs mode (so the gather task stays idle); otherwise the
    /// current open-tab ID set, so opening/closing a tab retriggers the gather.
    private var allTabsGatherKey: String {
        guard mode == .allTabs else { return "" }
        // Sorted so it's a stable set key: reordering tabs (same set) must not
        // retrigger a re-gather, only opening/closing a tab should.
        return tabManager.tabs.map { $0.id.uuidString }.sorted().joined(separator: ",")
    }

    private var modePicker: some View {
        Picker("Mode", selection: $mode) {
            ForEach(AskThisPageMode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SettingsManager.shared.accentColor)

            VStack(alignment: .leading, spacing: 0) {
                Text("Ask This Page")
                    .font(.system(size: 12, weight: .semibold))
                Text(pageTitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

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

    // MARK: - Fallback states

    private var unavailableMessage: String {
        switch availability {
        case .available: return ""
        case .unsupportedOS: return "Ask This Page requires macOS 26 or later."
        case .unavailable(let reason): return reason
        }
    }

    private var unavailableView: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(unavailableMessage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noContentView: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("Couldn't find readable content on this page.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Ask (chat)

    private var chatContent: some View {
        VStack(spacing: 0) {
            if !chatSession.turns.isEmpty {
                chatToolbar
                Divider()
            }
            if chatSession.turns.isEmpty {
                chatEmptyState
            } else {
                chatScrollView
            }
            Divider()
            chatInputRow
        }
        .frame(maxHeight: .infinity)
    }

    private var chatToolbar: some View {
        HStack {
            Spacer()
            Button {
                chatSession.startNewChat()
            } label: {
                Label("New Chat", systemImage: "square.and.pencil")
                    .font(.system(size: 10.5, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(!chatSession.canSend)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var chatScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(chatSession.turns) { turn in
                        chatBubble(for: turn)
                            .id(turn.id)
                    }
                }
                .padding(14)
            }
            .onChange(of: chatSession.turns) { _, turns in
                guard let last = turns.last else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onAppear {
                if let last = chatSession.turns.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func chatBubble(for turn: PageChatTurn) -> some View {
        switch turn.role {
        case .user:
            HStack(spacing: 0) {
                Spacer(minLength: 40)
                Text(turn.text)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(SettingsManager.shared.accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 0) {
                    Group {
                        if turn.isStreaming && turn.text.isEmpty {
                            TypingDotsView()
                        } else {
                            Text(Self.assistantMarkdown(turn.text))
                                .font(.system(size: 13))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    Spacer(minLength: 40)
                }
                if !turn.sources.isEmpty {
                    sourcesFooter(turn.sources)
                }
            }

        case .error:
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11))
                Text(turn.text)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
            }
            .foregroundStyle(.red.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Renders assistant text as markdown (so `**bold**`, headings, lists,
    /// etc. show as formatting instead of literal asterisks) while
    /// preserving newlines/whitespace as typed. Falls back to plain text if
    /// parsing throws, since the model's output isn't guaranteed valid markdown.
    private static func assistantMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    private let examplePrompts = [
        "Summarize the key points",
        "What are the downsides?",
        "Explain simply",
    ]

    private var chatEmptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text("Ask anything about this page")
                .font(.system(size: 13, weight: .semibold))
            Text("Answers are grounded in this page's content and generated entirely on-device.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            VStack(spacing: 6) {
                ForEach(examplePrompts, id: \.self) { prompt in
                    Button {
                        chatSession.send(prompt)
                    } label: {
                        Text(prompt)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!chatSession.canSend)
                }
            }
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
    }

    private var chatInputRow: some View {
        inputRow(placeholder: "Ask about this page…", canSend: chatSession.canSend, onSend: sendDraft)
    }

    /// Shared input row for both modes: same visuals as before, parameterized
    /// by which session is currently active so This Page and All Tabs modes
    /// don't need two near-identical copies of the text field + send button.
    private func inputRow(placeholder: String, canSend: Bool, onSend: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                .onSubmit(onSend)
                .disabled(!canSend)

            Button(action: onSend) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(
                        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !canSend
                            ? AnyShapeStyle(.secondary)
                            : AnyShapeStyle(SettingsManager.shared.accentColor)
                    )
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !canSend)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func sendDraft() {
        let text = draft
        guard chatSession.canSend, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        chatSession.send(text)
    }

    /// A citation chip list shown under an assistant bubble that cited
    /// sources: `[N] Tab Title`, clickable to switch to that tab.
    private func sourcesFooter(_ sources: [ResearchSource]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sources")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.tertiary)
            ForEach(sources) { source in
                Button {
                    focusTab(id: source.tabID)
                } label: {
                    Text("[\(source.index)] \(source.title)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func focusTab(id: UUID) {
        guard let tab = tabManager.tabs.first(where: { $0.id == id }) else { return }
        tabManager.selectTab(tab)
    }

    // MARK: - Research (All Tabs)

    private var researchContent: some View {
        VStack(spacing: 0) {
            // Full-screen "reading tabs" only on the FIRST gather (no conversation
            // yet). A background re-gather triggered by opening/closing a tab must
            // NOT hide an existing conversation/streaming answer — the toolbar shows
            // a subtle "refreshing" hint instead (see researchToolbar).
            if researchSession.turns.isEmpty && (!researchSession.hasPrepared || researchSession.isPreparing) {
                researchPreparingView
            } else if !researchSession.canSend && researchSession.turns.isEmpty && !researchSession.isPreparing {
                researchUnavailableView
            } else {
                if !researchSession.turns.isEmpty {
                    researchToolbar
                    Divider()
                }
                if researchSession.turns.isEmpty {
                    researchEmptyState
                } else {
                    researchScrollView
                }
                Divider()
                inputRow(placeholder: "Ask across open tabs…", canSend: researchSession.canSend, onSend: sendResearchDraft)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var researchStatusLine: String {
        let included = researchSession.includedTabCount
        let skipped = researchSession.skippedTabCount
        let tabsPart = "\(included) tab\(included == 1 ? "" : "s") included"
        guard skipped > 0 else { return tabsPart }
        return "\(tabsPart) · \(skipped) skipped"
    }

    private var researchPreparingView: some View {
        VStack(spacing: 10) {
            Spacer()
            ProgressView()
            Text("Reading open tabs…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var researchUnavailableView: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No open tabs available for research.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            if researchSession.skippedTabCount > 0 {
                Text("\(researchSession.skippedTabCount) tab\(researchSession.skippedTabCount == 1 ? "" : "s") skipped (private, internal, home, or sleeping).")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            Button("Try Again") {
                Task { await researchSession.prepare(tabManager: tabManager) }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(SettingsManager.shared.accentColor)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var researchToolbar: some View {
        HStack(spacing: 10) {
            Text(researchStatusLine)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            if researchSession.isPreparing {
                // Background re-gather (a tab opened/closed) while a conversation
                // is on screen — subtle hint instead of hiding the conversation.
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            }
            Spacer()
            Button {
                Task {
                    await researchSession.prepare(tabManager: tabManager)
                    researchSession.startNewChat()
                }
            } label: {
                Label("New Chat", systemImage: "square.and.pencil")
                    .font(.system(size: 10.5, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(!researchSession.canSend)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private let researchExamplePrompts = [
        "Compare these tabs",
        "What do they have in common?",
        "Summarize each one",
    ]

    private var researchEmptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text("Ask across your open tabs")
                .font(.system(size: 13, weight: .semibold))
            Text(researchStatusLine)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Text("Answers cite which tab each fact came from, generated entirely on-device.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            VStack(spacing: 6) {
                ForEach(researchExamplePrompts, id: \.self) { prompt in
                    Button {
                        researchSession.send(prompt)
                    } label: {
                        Text(prompt)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!researchSession.canSend)
                }
            }
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
    }

    private var researchScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(researchSession.turns) { turn in
                        chatBubble(for: turn)
                            .id(turn.id)
                    }
                }
                .padding(14)
            }
            .onChange(of: researchSession.turns) { _, turns in
                guard let last = turns.last else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onAppear {
                if let last = researchSession.turns.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private func sendResearchDraft() {
        let text = draft
        guard researchSession.canSend, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        researchSession.send(text)
    }
}

/// Three dots that pulse in sequence, shown while an assistant reply hasn't
/// produced any text yet.
private struct TypingDotsView: View {
    @State private var animate = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.secondary.opacity(0.6))
                    .frame(width: 6, height: 6)
                    .scaleEffect(animate ? 1.0 : 0.5)
                    .opacity(animate ? 1.0 : 0.4)
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.15),
                        value: animate
                    )
            }
        }
        .frame(height: 14)
        .onAppear { animate = true }
    }
}
