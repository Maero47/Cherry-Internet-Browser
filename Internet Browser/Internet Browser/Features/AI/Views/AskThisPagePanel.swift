//
//  AskThisPagePanel.swift
//  Cherry Browser
//

import SwiftUI

/// Trailing side panel for on-device page Q&A, (when more than the current
/// page is selected in the tab picker) cited research over the chosen open
/// tabs, and (when the tab selection is empty) a general ungrounded chat
/// with the current engine. Mirrors `ViewSourcePanel`'s shape (fixed-width
/// trailing panel with a header bar + dismiss button) since it's the closest
/// existing precedent for a panel driven by pre-fetched page content.
struct AskThisPagePanel: View {
    let pageTitle: String
    let pageText: String
    let tabManager: TabManager
    let onDismiss: () -> Void

    @StateObject private var chatSession = PageChatSession()
    @StateObject private var researchSession = TabsResearchSession()
    @State private var draft: String = ""
    /// Turn IDs whose reasoning ("Thoughts") disclosure is expanded. Kept on
    /// the panel (not inside the row builder) because rows live in a ForEach —
    /// a `@State` in the row would reset on every turns-array mutation.
    @State private var expandedReasoning: Set<UUID> = []
    /// The assistant turn currently hovered, whose copy affordance is shown.
    @State private var hoveredTurnID: UUID?
    /// Briefly holds the turn just copied so its icon flips to a checkmark.
    @State private var copiedTurnID: UUID?
    /// The tabs the conversation answers from. Defaults to just the active
    /// tab (this-page parity); adding more switches to the research session
    /// over exactly this set. EMPTY is a valid state: it means general chat —
    /// a direct, ungrounded conversation with the current engine.
    @State private var selectedTabIDs: Set<UUID>
    /// The tab whose `pageTitle`/`pageText` snapshot was passed in when the
    /// panel opened. `@State` (captured once) rather than recomputed: the
    /// snapshot doesn't follow later tab switches, so neither should this.
    @State private var activeTabID: UUID?

    init(pageTitle: String, pageText: String, tabManager: TabManager, onDismiss: @escaping () -> Void) {
        self.pageTitle = pageTitle
        self.pageText = pageText
        self.tabManager = tabManager
        self.onDismiss = onDismiss
        let active = tabManager.selectedTabID
        _activeTabID = State(initialValue: active)
        // An active tab with no readable content (blank/new tab, home page)
        // can't ground a chat — start with an EMPTY selection, i.e. general
        // chat, instead of a dead "no readable content" state.
        if let active, !pageText.isEmpty {
            _selectedTabIDs = State(initialValue: [active])
        } else {
            _selectedTabIDs = State(initialValue: [])
        }
    }

    private var availability: PageAIAvailability { PageAIService.availability }

    /// Exactly the active tab selected → the fast single-page chat path
    /// (identical to the old "This Page" mode). Anything else answers via the
    /// research session over the selected set — unless the selection is
    /// general-chat-shaped (see `isGeneralChat`).
    private var isSinglePageSelection: Bool {
        selectedTabIDs.count == 1 && selectedTabIDs.first == activeTabID
    }

    /// Nothing usable to ground on → general chat: a direct conversation
    /// with the current engine, answering from the model's own knowledge.
    /// Covers an empty selection (the user removed every chip, or the panel
    /// opened on a contentless tab) and the active tab being selected while
    /// its page snapshot has no readable text.
    private var isGeneralChat: Bool {
        selectedTabIDs.isEmpty || (isSinglePageSelection && pageText.isEmpty)
    }

    /// The selection shapes that answer via the research session: two or
    /// more tabs, or a single tab that isn't the active one.
    private var isResearchSelection: Bool {
        !isGeneralChat && !isSinglePageSelection
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            // The unavailable state only replaces the content when there is
            // genuinely nothing usable to show. A conversation already on
            // screen keeps running on the engine it was BUILT with (streams
            // route by concrete engine type), so switching to an unavailable
            // engine mid-conversation must not hide or kill it — the
            // "Applies to your next chat." hint covers that case, and the
            // next New Chat surfaces the unavailable view naturally.
            if !availability.isAvailable && !activePathHasTurns {
                unavailableView
            } else {
                if showsEngineSwitchHint {
                    engineSwitchHint
                    Divider()
                }
                TabSelectorBar(
                    tabManager: tabManager,
                    activeTabID: activeTabID,
                    activePageTitle: pageTitle,
                    selectedTabIDs: $selectedTabIDs
                )
                Divider()
                // General chat and this-page chat are both `chatSession` —
                // they differ only in how the session was configured
                // (see the configure task below) and in the empty-state copy.
                if isGeneralChat || isSinglePageSelection {
                    chatContent
                } else {
                    researchContent
                }
            }
        }
        .frame(width: 380)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 0.5)
        }
        // Keyed on availability AS WELL as the page and the routed mode: if
        // the panel opened while the chosen engine was unavailable, the first
        // run failed its guard and `pageText` never changes for the panel's
        // life — switching to a working engine from the header menu must
        // re-run configure so the chat works without closing/reopening the
        // panel. The mode token makes general↔page transitions re-fire this
        // task; both `configure` and `configureGeneral` no-op when the
        // session is already in that exact state, so a re-fire never resets
        // a live conversation whose grounding didn't actually change (e.g.
        // general → research → general keeps the general chat).
        .task(id: chatConfigureKey) {
            guard availability.isAvailable else { return }
            if isGeneralChat {
                chatSession.configureGeneral()
            } else if isSinglePageSelection {
                chatSession.configure(pageTitle: pageTitle, pageText: pageText, summary: nil)
            }
        }
        // Re-gather whenever a research-shaped selection is active and the
        // selected set changes, so the index always covers exactly the chosen
        // tabs. Re-running with an unchanged content snapshot stays cheap,
        // since buildIndex caches by content equality.
        .task(id: researchGatherKey) {
            guard isResearchSelection, availability.isAvailable else { return }
            await researchSession.prepare(tabManager: tabManager, includeTabIDs: selectedTabIDs)
        }
        // A selected tab can be CLOSED while the panel is open: prune it from
        // the selection (which also retriggers the gather via the key above)
        // instead of silently keeping its stale content in the index. All
        // selected tabs closing leaves the selection empty — general chat —
        // rather than snapping back to the active tab.
        .onChange(of: openTabIDs) { _, openIDs in
            let pruned = selectedTabIDs.intersection(openIDs)
            guard pruned != selectedTabIDs else { return }
            selectedTabIDs = pruned
        }
    }

    /// Identity for the chat configure task: re-fires when the page snapshot
    /// changes, when availability flips (e.g. the user switches from an
    /// unavailable engine to a working one in the header menu), or when the
    /// routed mode changes (general ↔ page ↔ research), so entering or
    /// leaving general chat reconfigures the session.
    private struct ChatConfigureKey: Equatable {
        enum Mode { case general, page, research }
        let isAvailable: Bool
        let mode: Mode
        let pageText: String
    }

    private var chatConfigureKey: ChatConfigureKey {
        ChatConfigureKey(
            isAvailable: availability.isAvailable,
            mode: isGeneralChat ? .general : (isSinglePageSelection ? .page : .research),
            pageText: pageText
        )
    }

    /// Empty for the single-page and general-chat selections (so the gather
    /// task stays idle); otherwise a stable key for the selected tab set —
    /// sorted, so only real membership changes retrigger a re-gather.
    /// Prefixed with an availability token for the same reason as
    /// `ChatConfigureKey`: a gather skipped while the engine was unavailable
    /// must re-run once a working engine is chosen.
    private var researchGatherKey: String {
        guard isResearchSelection else { return "" }
        let ids = selectedTabIDs.map(\.uuidString).sorted().joined(separator: ",")
        return "\(availability.isAvailable)|\(ids)"
    }

    /// Whether the currently routed path already has a conversation on
    /// screen — if so, the unavailable view must never replace it.
    private var activePathHasTurns: Bool {
        (isGeneralChat || isSinglePageSelection) ? !chatSession.turns.isEmpty : !researchSession.turns.isEmpty
    }

    private var openTabIDs: Set<UUID> {
        Set(tabManager.tabs.map(\.id))
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
                Text(isGeneralChat ? "General chat" : pageTitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            engineMenu

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

    /// Compact engine switcher in the header. Reflects and sets the app-wide
    /// `aiEngine` setting; the switch takes effect on the NEXT new chat (the
    /// open conversation keeps the engine it was built with — see
    /// `showsEngineSwitchHint`). Selecting Qwen while its model isn't
    /// downloaded is allowed: the panel then shows the normal
    /// "not downloaded" availability fallback, pointing at Settings.
    private var engineMenu: some View {
        Menu {
            ForEach(AIEngine.allCases) { engine in
                Button {
                    SettingsManager.shared.aiEngine = engine
                } label: {
                    if engine == SettingsManager.shared.aiEngine {
                        Label(engine.rawValue, systemImage: "checkmark")
                    } else {
                        Text(engine.rawValue)
                    }
                }
            }
            if !LLMModelManager.shared.isDownloaded {
                Divider()
                Text("Qwen model not downloaded — download it in Settings")
            }
        } label: {
            HStack(spacing: 3) {
                Text(SettingsManager.shared.aiEngine.rawValue)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// True when the live engine setting differs from the engine the visible
    /// conversation was built with — i.e. the moment to tell the user the
    /// switch only applies to their next chat.
    private var showsEngineSwitchHint: Bool {
        let current = SettingsManager.shared.aiEngine
        if isGeneralChat || isSinglePageSelection {
            guard let built = chatSession.conversationEngine, !chatSession.turns.isEmpty else { return false }
            return built != current
        }
        guard let built = researchSession.conversationEngine, !researchSession.turns.isEmpty else { return false }
        return built != current
    }

    private var engineSwitchHint: some View {
        Text("Applies to your next chat.")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .trailing)
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
                if let reasoning = turn.reasoning, !reasoning.isEmpty {
                    reasoningDisclosure(reasoning: reasoning, for: turn)
                }
                HStack(alignment: .bottom, spacing: 4) {
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
                    if !turn.isStreaming && !turn.text.isEmpty {
                        copyButton(for: turn)
                            .opacity(hoveredTurnID == turn.id || copiedTurnID == turn.id ? 1 : 0)
                    }
                    Spacer(minLength: 36)
                }
                .onHover { hovering in
                    if hovering {
                        hoveredTurnID = turn.id
                    } else if hoveredTurnID == turn.id {
                        hoveredTurnID = nil
                    }
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

    /// Copies the turn's ANSWER (never its reasoning) to the pasteboard,
    /// flipping to a checkmark briefly as feedback. Hidden until the bubble
    /// row is hovered, to stay unobtrusive.
    private func copyButton(for turn: PageChatTurn) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(turn.text, forType: .string)
            let copiedID = turn.id
            copiedTurnID = copiedID
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                if copiedTurnID == copiedID { copiedTurnID = nil }
            }
        } label: {
            Image(systemName: copiedTurnID == turn.id ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy answer")
    }

    /// Collapsible chain-of-thought control shown above a reasoning model's
    /// answer bubble. While the model is still inside its think block (no
    /// answer text yet) it reads "Thinking…" with the animated dots; once the
    /// answer starts (or the stream ends) it becomes a collapsed-by-default
    /// "Thoughts" disclosure. Engines without a think block (`reasoning ==
    /// nil`) never reach this view.
    private func reasoningDisclosure(reasoning: String, for turn: PageChatTurn) -> some View {
        let isThinking = turn.isStreaming && turn.text.isEmpty
        let isExpanded = expandedReasoning.contains(turn.id)
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                if isExpanded {
                    expandedReasoning.remove(turn.id)
                } else {
                    expandedReasoning.insert(turn.id)
                }
            } label: {
                HStack(spacing: 5) {
                    if isThinking {
                        Text("Thinking…")
                        TypingDotsView()
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                        Text("Thoughts")
                    }
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(reasoning)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.25))
                            .frame(width: 2)
                    }
            }
        }
        .padding(.leading, 2)
    }

    /// Renders assistant text as FULL markdown (headings, lists, code blocks,
    /// plus the inline styles) instead of inline-only. SwiftUI's `Text`
    /// ignores block-level `PresentationIntent`, so after parsing, the block
    /// structure is rebuilt as literal characters + inline attributes:
    /// paragraph breaks, `• ` / `N. ` list markers, semibold headings, and a
    /// monospaced font for code blocks. Falls back to plain text if parsing
    /// throws, since the model's output isn't guaranteed valid markdown.
    private static func assistantMarkdown(_ text: String) -> AttributedString {
        guard let parsed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) else {
            return AttributedString(text)
        }

        var result = AttributedString()
        var previousBlockKey: [Int]? = nil
        var previousTopIdentity: Int? = nil
        var previousListItemIdentity: Int? = nil

        // `runs[\.presentationIntent]` coalesces consecutive runs sharing an
        // intent, so each iteration is one block (inline styles inside it are
        // preserved by slicing the parsed string).
        for (intent, range) in parsed.runs[\.presentationIntent] {
            var segment = AttributedString(parsed[range])
            segment.presentationIntent = nil

            let components = intent?.components ?? []
            let blockKey = components.map(\.identity)
            let topIdentity = blockKey.last

            if blockKey != previousBlockKey {
                if !result.characters.isEmpty {
                    // Blocks sharing their outermost container (items of the
                    // same list) sit one line apart; unrelated blocks get a
                    // blank line between them.
                    let sameContainer = topIdentity != nil && topIdentity == previousTopIdentity
                    result += AttributedString(sameContainer ? "\n" : "\n\n")
                }
                // The bullet/number is printed once per list ITEM: an item
                // with several blocks (a second paragraph, a code block)
                // changes blockKey while keeping the same listItem identity —
                // its continuation blocks get matching indentation only.
                let list = listContext(for: components)
                if let itemIdentity = list.itemIdentity {
                    if itemIdentity != previousListItemIdentity {
                        result += AttributedString(list.indent + list.marker)
                    } else {
                        result += AttributedString(list.indent + String(repeating: " ", count: list.marker.count))
                    }
                }
                previousListItemIdentity = list.itemIdentity
            }

            // Components are ordered innermost-first; the LAST style found
            // (outermost) must not override an inner one, so first match wins.
            for component in components {
                switch component.kind {
                case .header(let level):
                    segment.font = .system(size: level <= 1 ? 15 : level == 2 ? 14 : 13.5, weight: .semibold)
                case .codeBlock:
                    segment.font = .system(size: 12, design: .monospaced)
                default:
                    continue
                }
                break
            }

            result += segment
            previousBlockKey = blockKey
            previousTopIdentity = topIdentity
        }
        return result
    }

    /// For a list-item block: the identity of the (innermost) `listItem` the
    /// block belongs to — distinct per item, shared by all of one item's
    /// blocks — plus its `• ` / `N. ` marker and a two-spaces-per-nesting-
    /// level indent. `itemIdentity == nil` for any non-list block. Components
    /// are ordered innermost-first, so the list container FOLLOWING a
    /// `listItem` is the one that owns it and decides bullet vs number.
    private static func listContext(
        for components: [PresentationIntent.IntentType]
    ) -> (itemIdentity: Int?, marker: String, indent: String) {
        var itemIdentity: Int? = nil
        var marker = ""
        var pendingOrdinal: Int? = nil
        var listDepth = 0
        for component in components {
            switch component.kind {
            case .listItem(let ordinal):
                if itemIdentity == nil {
                    itemIdentity = component.identity
                    pendingOrdinal = ordinal
                }
            case .unorderedList:
                listDepth += 1
                if pendingOrdinal != nil, marker.isEmpty {
                    marker = "• "
                    pendingOrdinal = nil
                }
            case .orderedList:
                listDepth += 1
                if let ordinal = pendingOrdinal, marker.isEmpty {
                    marker = "\(ordinal). "
                    pendingOrdinal = nil
                }
            default:
                break
            }
        }
        let indent = String(repeating: "  ", count: max(0, listDepth - 1))
        return (itemIdentity, marker, indent)
    }

    private let examplePrompts = [
        "Summarize the key points",
        "What are the downsides?",
        "Explain simply",
    ]

    private let generalExamplePrompts = [
        "Explain a concept",
        "Draft an email",
        "Brainstorm ideas",
    ]

    private var chatEmptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text(isGeneralChat ? "Ask anything" : "Ask anything about this page")
                .font(.system(size: 13, weight: .semibold))
            Text(isGeneralChat
                ? "Chats on-device with the selected engine. Add a tab to ground answers in a page."
                : "Answers are grounded in this page's content and generated entirely on-device.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            VStack(spacing: 6) {
                ForEach(isGeneralChat ? generalExamplePrompts : examplePrompts, id: \.self) { prompt in
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
        inputRow(
            placeholder: isGeneralChat ? "Ask anything…" : "Ask about this page…",
            canSend: chatSession.canSend,
            isResponding: chatSession.isResponding,
            onSend: sendDraft,
            onStop: { chatSession.stop() }
        )
    }

    /// Shared input row for both paths: same visuals as before, parameterized
    /// by which session is currently active so the single-page and research
    /// paths don't need two near-identical copies of the text field + send
    /// button. While a reply is streaming, the send button becomes a Stop
    /// control that cancels the generation, keeping the partial answer.
    private func inputRow(
        placeholder: String,
        canSend: Bool,
        isResponding: Bool,
        onSend: @escaping () -> Void,
        onStop: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                .onSubmit(onSend)
                .disabled(!canSend)

            if isResponding {
                Button(action: onStop) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(AnyShapeStyle(SettingsManager.shared.accentColor))
                }
                .buttonStyle(.plain)
                .help("Stop generating")
            } else {
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
                inputRow(
                    placeholder: "Ask across these tabs…",
                    canSend: researchSession.canSend,
                    isResponding: researchSession.isResponding,
                    onSend: sendResearchDraft,
                    onStop: { researchSession.stop() }
                )
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
                Task { await researchSession.prepare(tabManager: tabManager, includeTabIDs: selectedTabIDs) }
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
                    await researchSession.prepare(tabManager: tabManager, includeTabIDs: selectedTabIDs)
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
            Text("Ask across the selected tabs")
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

/// The row of selected-tab chips plus a `＋` menu of every eligible open tab,
/// replacing the old This Page / All Tabs segmented picker. The selected set
/// drives which session answers (see `isSinglePageSelection`); the active
/// tab is just a normal, default-selected member of the set.
private struct TabSelectorBar: View {
    let tabManager: TabManager
    let activeTabID: UUID?
    /// Title of the page snapshot the panel opened with — used for the active
    /// tab's chip so it reads as "the current page" even if the tab's live
    /// title has since changed.
    let activePageTitle: String
    @Binding var selectedTabIDs: Set<UUID>

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(selectedTabs) { tab in
                        chip(for: tab)
                    }
                }
            }
            addTabMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Selected tabs in tab-strip order, active tab first so the chip that
    /// reads as "this page" stays anchored at the leading edge.
    private var selectedTabs: [Tab] {
        let selected = tabManager.tabs.filter { selectedTabIDs.contains($0.id) }
        return selected.filter { $0.id == activeTabID } + selected.filter { $0.id != activeTabID }
    }

    /// Same eligibility as `TabsResearchSession.performPrepare`: private,
    /// internal, home-page, and sleeping (no webView) tabs can't be indexed.
    private var eligibleTabs: [Tab] {
        tabManager.tabs.filter { tab in
            !tab.isPrivate && tab.internalPage == nil && !tab.showHomePage && tab.webView != nil
        }
    }

    private func chipTitle(for tab: Tab) -> String {
        if tab.id == activeTabID, !activePageTitle.isEmpty {
            return activePageTitle
        }
        return tab.title.isEmpty ? (tab.url?.host() ?? "Untitled") : tab.title
    }

    private func chip(for tab: Tab) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(SettingsManager.shared.accentColor)
                .frame(width: 5, height: 5)
            Text(chipTitle(for: tab))
                .font(.system(size: 10.5))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 110, alignment: .leading)
            Button {
                remove(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }

    private var addTabMenu: some View {
        Menu {
            ForEach(eligibleTabs) { tab in
                Toggle(isOn: membershipBinding(for: tab.id)) {
                    Text(chipTitle(for: tab))
                        .lineLimit(1)
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(Color.primary.opacity(0.06), in: Circle())
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func membershipBinding(for tabID: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedTabIDs.contains(tabID) },
            set: { isSelected in
                if isSelected {
                    selectedTabIDs.insert(tabID)
                } else {
                    remove(tabID)
                }
            }
        )
    }

    /// Removing the last chip leaves the selection EMPTY — that's the valid
    /// general-chat state, not an error. The chips row and ＋ menu stay
    /// visible so the user can add a tab to ground the chat again.
    private func remove(_ tabID: UUID) {
        selectedTabIDs.remove(tabID)
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
