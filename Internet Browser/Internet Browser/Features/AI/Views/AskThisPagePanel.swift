//
//  AskThisPagePanel.swift
//  Cherry Browser
//

import SwiftUI

/// Trailing side panel for on-device page summaries, key points, and Q&A.
/// Mirrors `ViewSourcePanel`'s shape (fixed-width trailing panel with a
/// header bar + dismiss button) since it's the closest existing precedent
/// for a panel driven by pre-fetched page content.
struct AskThisPagePanel: View {
    let pageTitle: String
    let pageText: String
    let onDismiss: () -> Void

    private enum Segment: String, CaseIterable {
        case summary = "Summary"
        case ask = "Ask"
    }

    @State private var segment: Segment = .summary

    @State private var isSummarizing = false
    @State private var summaryResult: PageSummaryResult?
    @State private var summaryError: String?

    @StateObject private var chatSession = PageChatSession()
    @State private var draft: String = ""

    private let availability = PageAIService.availability

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if !availability.isAvailable {
                unavailableView
            } else if pageText.isEmpty {
                noContentView
            } else {
                segmentPicker
                Divider()
                switch segment {
                case .summary:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            summaryContent
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .ask:
                    chatContent
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
            chatSession.configure(pageTitle: pageTitle, pageText: pageText, summary: summaryResult)
        }
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

    // MARK: - Segment picker

    private var segmentPicker: some View {
        Picker("", selection: $segment) {
            ForEach(Segment.allCases, id: \.self) { seg in
                Text(seg.rawValue).tag(seg)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Summary

    @ViewBuilder
    private var summaryContent: some View {
        if let result = summaryResult {
            VStack(alignment: .leading, spacing: 14) {
                if result.wasTruncated {
                    truncationNotice
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Summary")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(result.summary)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Key Points")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ForEach(Array(result.keyPoints.enumerated()), id: \.offset) { _, point in
                        HStack(alignment: .top, spacing: 6) {
                            Text("•").foregroundStyle(.secondary)
                            Text(point)
                                .font(.system(size: 13))
                                .textSelection(.enabled)
                        }
                    }
                }

                Button("Regenerate") { runSummarize() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsManager.shared.accentColor)
            }
        } else if isSummarizing {
            loadingRow(text: "Reading the page…")
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if let error = summaryError {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.red.opacity(0.85))
                }
                Text("Get a concise summary and the key points of this page, generated entirely on-device.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Button("Summarize Page") { runSummarize() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
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
            HStack(spacing: 0) {
                Group {
                    if turn.isStreaming && turn.text.isEmpty {
                        TypingDotsView()
                    } else {
                        Text(turn.text)
                            .font(.system(size: 13))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Spacer(minLength: 40)
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
        VStack(spacing: 8) {
            if chatSession.isBlockedByContextLimit {
                Button {
                    chatSession.startNewChat()
                } label: {
                    Label("Start New Chat", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            HStack(spacing: 8) {
                TextField("Ask about this page…", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                    .onSubmit(sendDraft)
                    .disabled(!chatSession.canSend)

                Button(action: sendDraft) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(
                            draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !chatSession.canSend
                                ? AnyShapeStyle(.secondary)
                                : AnyShapeStyle(SettingsManager.shared.accentColor)
                        )
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !chatSession.canSend)
            }
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

    // MARK: - Shared bits

    private func loadingRow(text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 20)
    }

    private var truncationNotice: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text("This page is long — only part of it was used.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func runSummarize() {
        guard !isSummarizing else { return }
        isSummarizing = true
        summaryError = nil
        Task { @MainActor in
            let result = await PageAIService.summarize(pageText: pageText, pageTitle: pageTitle)
            isSummarizing = false
            switch result {
            case .success(let value): summaryResult = value
            case .failure(let error): summaryError = error.errorDescription
            }
        }
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
