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

    @State private var question: String = ""
    @State private var isAnswering = false
    @State private var lastQuestion: String = ""
    @State private var lastAnswer: PageAnswerResult?
    @State private var answerError: String?

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
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        switch segment {
                        case .summary: summaryContent
                        case .ask: askContent
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(width: 380)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 0.5)
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

    // MARK: - Ask

    @ViewBuilder
    private var askContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("Ask a question about this page…", text: $question)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
                    .onSubmit { runAsk() }
                    .disabled(isAnswering)

                Button {
                    runAsk()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(
                            question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? AnyShapeStyle(.secondary)
                                : AnyShapeStyle(SettingsManager.shared.accentColor)
                        )
                }
                .buttonStyle(.plain)
                .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAnswering)
            }

            if isAnswering {
                loadingRow(text: "Thinking…")
            } else if let error = answerError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red.opacity(0.85))
            } else if let answer = lastAnswer {
                VStack(alignment: .leading, spacing: 6) {
                    if answer.wasTruncated {
                        truncationNotice
                    }
                    Text(lastQuestion)
                        .font(.system(size: 12, weight: .semibold))
                    Text(answer.answer)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                }
                .padding(.top, 4)
            }
        }
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

    private func runAsk() {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAnswering else { return }
        isAnswering = true
        answerError = nil
        lastQuestion = trimmed
        Task { @MainActor in
            let result = await PageAIService.answer(question: trimmed, pageText: pageText, pageTitle: pageTitle)
            isAnswering = false
            switch result {
            case .success(let value): lastAnswer = value
            case .failure(let error): answerError = error.errorDescription
            }
        }
    }
}
