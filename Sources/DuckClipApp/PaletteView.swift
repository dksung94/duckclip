import AppKit
import DuckClipCore
import SwiftUI

struct PaletteView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: DuckClipSettings
    let onActivate: (ClipItem) -> Void
    let onPaste: (ClipItem) -> Void
    let onCopy: (ClipItem) -> Void
    let onDismiss: () -> Void

    @FocusState private var searchFocused: Bool
    @FocusState private var replyFocusedItemID: String?

    init(
        model: AppModel,
        onActivate: @escaping (ClipItem) -> Void,
        onPaste: @escaping (ClipItem) -> Void,
        onCopy: @escaping (ClipItem) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.model = model
        _settings = ObservedObject(wrappedValue: model.settings)
        self.onActivate = onActivate
        self.onPaste = onPaste
        self.onCopy = onCopy
        self.onDismiss = onDismiss
    }

    var body: some View {
        Group {
            if settings.hasCompletedOnboarding {
                palette
            } else {
                onboarding
            }
        }
        .frame(
            minWidth: PaletteLayoutMetrics.minimumWindowWidth,
            maxWidth: .infinity,
            minHeight: PaletteLayoutMetrics.minimumWindowHeight,
            maxHeight: .infinity
        )
        .background(.ultraThinMaterial)
        .onAppear {
            searchFocused = settings.hasCompletedOnboarding
            model.reload()
        }
        .onMoveCommand { direction in
            switch direction {
            case .up: model.moveSelection(by: -1, orderedIDs: model.items.map(\.id))
            case .down: model.moveSelection(by: 1, orderedIDs: model.items.map(\.id))
            default: break
            }
        }
        .alert("DuckClip", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.dismissError() } }
        )) {
            if model.accessibilityPermissionRequired {
                Button("Open Accessibility Settings") { model.openAccessibilitySettings() }
                if let item = model.selectedItem {
                    Button("Copy Instead") {
                        model.dismissError()
                        onCopy(item)
                    }
                }
            }
            Button("OK", role: .cancel) { model.dismissError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var palette: some View {
        VStack(spacing: 0) {
            header
            if let activity = model.agentActivityNotice {
                AgentActivityBanner(activity: activity) {
                    model.dismissAgentActivityNotice()
                }
                Divider()
            }
            if let notice = model.paletteNotice {
                NoticeBanner(notice: notice) {
                    model.performNoticeAction(notice)
                } onDismiss: {
                    model.dismissPaletteNotice()
                }
                Divider()
            }
            if let message = model.passiveStatusMessage {
                PassiveStatusBanner(message: message)
                Divider()
            }
            Divider()
            paletteContent
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var paletteContent: some View {
        Group {
            if model.sourceFilter == .agents {
                agentWorkspace
            } else {
                HSplitView {
                    itemList
                        .frame(
                            minWidth: PaletteLayoutMetrics.clipboardListMinimumWidth,
                            idealWidth: PaletteLayoutMetrics.clipboardListIdealWidth
                        )
                        .frame(maxHeight: .infinity)
                    preview
                        .frame(minWidth: PaletteLayoutMetrics.previewMinimumWidth)
                        .frame(maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var agentWorkspace: some View {
        Group {
            if missingAgentIntegrations && model.filteredSessions.isEmpty {
                ContentUnavailableView {
                    Label("Agent integrations are not installed", systemImage: "link.badge.plus")
                } description: {
                    Text("Install the Claude and Codex hooks before DuckClip can collect new responses.")
                } actions: {
                    Button("Install integrations") { model.installHooks() }
                }
            } else if model.filteredSessions.isEmpty {
                ContentUnavailableView {
                    Label("No agents yet", systemImage: "sparkles")
                } description: {
                    Text(hasActiveFilters ? "Try a broader search or reset the filters." : "Agent conversations will appear here after an integration sends a response.")
                } actions: {
                    if hasActiveFilters {
                        Button("Reset filters") { model.resetFilters() }
                    }
                }
            } else {
                HSplitView {
                    agentList
                        .frame(
                            minWidth: PaletteLayoutMetrics.agentListMinimumWidth,
                            idealWidth: PaletteLayoutMetrics.agentListIdealWidth,
                            maxWidth: PaletteLayoutMetrics.agentListMaximumWidth
                        )
                        .frame(maxHeight: .infinity)
                    conversationPane
                        .frame(
                            minWidth: PaletteLayoutMetrics.conversationMinimumWidth,
                            idealWidth: PaletteLayoutMetrics.conversationIdealWidth
                        )
                        .frame(maxHeight: .infinity)
                    preview
                        .frame(minWidth: PaletteLayoutMetrics.agentPreviewMinimumWidth)
                        .frame(maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var onboarding: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "doc.on.clipboard.fill")
                .font(.system(size: 54))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("Welcome to DuckClip")
                    .font(.largeTitle.bold())
                Text("Your clipboard and agent responses stay on this Mac.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 14) {
                OnboardingRow(
                    icon: "keyboard",
                    title: "Open from anywhere",
                    detail: String(format: String(localized: "Press %@ to open DuckClip."), settings.globalShortcut.displayName)
                )
                OnboardingRow(icon: "checkmark.shield", title: "Private by default", detail: "Password-manager and protected clipboard content is not recorded.")
                OnboardingRow(icon: "bell", title: "Agent alerts are optional", detail: "Enable completion, input, approval, and failure alerts in Settings.")
            }
            .frame(maxWidth: 470)
            HStack(spacing: 12) {
                Button("Set up notifications") {
                    model.setNotificationsEnabled(true)
                }
                .disabled(model.notificationRequestInFlight)
                Button("Get Started") {
                    settings.hasCompletedOnboarding = true
                    searchFocused = true
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            Spacer()
        }
        .padding(32)
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search clipboard and agent responses", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($searchFocused)
                if !model.query.isEmpty {
                    Button {
                        model.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Clear search")
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            HStack(spacing: 12) {
                Picker("Source", selection: $model.sourceFilter) {
                    ForEach(SourceFilter.allCases) { filter in
                        Text("\(filter.displayName) \(model.itemCounts[filter])").tag(filter)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 350)

                if model.sourceFilter != .clipboard {
                    Picker("Project", selection: $model.projectFilter) {
                        Text("All projects").tag(String?.none)
                        ForEach(model.projects, id: \.self) { path in
                            Text(projectLabel(path)).tag(String?.some(path))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 170)

                    if model.sourceFilter == .all {
                        Picker("Agent or session", selection: $model.conversationFilter) {
                            Text("All agents & sessions").tag(String?.none)
                            ForEach(model.filteredSessions) { session in
                                Text(conversationLabel(session)).tag(String?.some(session.id))
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 210)
                    }
                }
                Spacer(minLength: 0)
                if hasActiveFilters {
                    Button("Reset filters") { model.resetFilters() }
                        .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
    }

    private var agentList: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Agents", count: model.filteredSessions.count)
            Divider()
            List(selection: $model.conversationFilter) {
                ForEach(model.filteredSessions) { session in
                    AgentRow(session: session)
                        .tag(session.id)
                        .contentShape(Rectangle())
                        .onTapGesture { model.conversationFilter = session.id }
                }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private var conversationPane: some View {
        VStack(spacing: 0) {
            PaneHeader(
                title: "Conversations",
                count: model.conversationFilter == nil ? nil : model.items.count
            )
            Divider()
            if model.conversationFilter == nil {
                ContentUnavailableView {
                    Label("Select an agent", systemImage: "sidebar.left")
                } description: {
                    Text("Choose an agent to see its conversation history.")
                }
            } else {
                itemList
            }
        }
    }

    @ViewBuilder
    private var itemList: some View {
        if missingAgentIntegrations && model.items.isEmpty {
            ContentUnavailableView {
                Label("Agent integrations are not installed", systemImage: "link.badge.plus")
            } description: {
                Text("Install the Claude and Codex hooks before DuckClip can collect new responses.")
            } actions: {
                Button("Install integrations") { model.installHooks() }
            }
        } else if model.items.isEmpty, !settings.captureEnabled, model.sourceFilter != .agents {
            ContentUnavailableView {
                Label("Clipboard recording is paused", systemImage: "pause.circle")
            } description: {
                Text("Resume recording to collect new clipboard items.")
            } actions: {
                Button("Resume Clipboard Recording") { settings.captureEnabled = true }
            }
        } else if model.items.isEmpty {
            ContentUnavailableView {
                Label(hasActiveFilters ? "No matching items" : "Nothing found", systemImage: "doc.on.clipboard")
            } description: {
                Text(hasActiveFilters ? "Try a broader search or reset the filters." : "Copy something to add it to DuckClip.")
            } actions: {
                if hasActiveFilters {
                    Button("Reset filters") { model.resetFilters() }
                }
            }
        } else {
            List(selection: $model.selectedItemID) {
                ForEach(model.items) { item in
                    ItemRow(item: item)
                        .tag(item.id)
                        .contentShape(Rectangle())
                        .onTapGesture { model.selectedItemID = item.id }
                        .simultaneousGesture(TapGesture(count: 2).onEnded { onActivate(item) })
                        .accessibilityAction(.default) { onActivate(item) }
                        .accessibilityAction(named: Text("Copy")) { onCopy(item) }
                        .accessibilityAction(named: Text("Paste")) { onPaste(item) }
                        .contextMenu {
                            Button(pasteActionLabel) { onPaste(item) }
                            Button("Copy") { onCopy(item) }
                            Button(item.isPinned ? String(localized: "Unpin") : String(localized: "Pin")) {
                                model.togglePinned(item)
                            }
                            Divider()
                            Button("Delete", role: .destructive) { model.delete(item) }
                        }
                }
                if model.resultsTruncated {
                    HStack {
                        Spacer()
                        Button("Load 300 more") { model.loadMore() }
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.inset)
        }
    }

    private var missingAgentIntegrations: Bool {
        model.sourceFilter == .agents
            && model.hookStatus.providers.allSatisfy { !$0.installed }
    }

    private var hasActiveFilters: Bool {
        model.sourceFilter != .all
            || model.projectFilter != nil
            || model.conversationFilter != nil
            || !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func projectLabel(_ path: String) -> String {
        URL(fileURLWithPath: path).standardized.pathComponents.suffix(2).joined(separator: "/")
    }

    private func conversationLabel(_ session: AgentSessionSummary) -> String {
        let project = session.projectPath.map(projectLabel) ?? String(localized: "No project")
        let relative = RelativeDateTimeFormatter().localizedString(for: session.lastSeenAt, relativeTo: Date())
        return String(
            format: String(localized: "session.filter.format", defaultValue: "%@ · %@ %@ · %@ · %lld items · %@"),
            session.provider.displayName,
            session.identityKind,
            String(session.identityID.prefix(10)),
            project,
            session.itemCount,
            relative
        )
    }

    @ViewBuilder
    private var preview: some View {
        if let item = model.selectedItem {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(item.source.displayName, systemImage: ItemRow.icon(for: item))
                        .font(.headline)
                    Spacer()
                    if item.isPinned {
                        Image(systemName: "pin.fill")
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Pinned")
                    }
                }

                ViewThatFits(in: .horizontal) {
                    metadata(for: item)
                    VStack(alignment: .leading, spacing: 6) {
                        metadataBadges(for: item)
                        Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                switch item.kind {
                case .image:
                    ImagePreview(item: item)
                case .file:
                    FilePreview(item: item)
                case .url:
                    URLPreview(item: item)
                case .agentResponse:
                    VStack(spacing: 10) {
                        if let prompt = item.userPrompt {
                            agentQuestion(prompt)
                            Divider()
                        }
                        ScrollView {
                            MarkdownPreview(markdown: item.text)
                                .padding(.trailing, 8)
                        }
                        Divider()
                        agentReplyComposer(for: item)
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                case .text:
                    ScrollView {
                        Text(item.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(.trailing, 8)
                    }
                }
                if item.kind != .agentResponse {
                    Spacer(minLength: 0)
                }
            }
            .padding(16)
        } else {
            ContentUnavailableView(
                model.sourceFilter == .agents ? "Select a conversation" : "Select an item",
                systemImage: "cursorarrow.click"
            )
        }
    }

    private func agentQuestion(_ prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("You asked", systemImage: "person.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            AdaptiveQuestionText(text: prompt)
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .contain)
    }

    private func agentReplyComposer(for item: ClipItem) -> some View {
        let unavailableReason = model.agentReplyUnavailableReason(for: item)
        let hasPrompt = !model.agentReplyDraft
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty

        return VStack(alignment: .leading, spacing: 8) {
            Label("Reply to this session", systemImage: "arrowshape.turn.up.left.fill")
                .font(.subheadline.weight(.semibold))

            TextField("Write a follow-up…", text: $model.agentReplyDraft, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.plain)
                .focused($replyFocusedItemID, equals: item.id)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
                .disabled(model.isSendingAgentReply)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(unavailableReason ?? String(localized: "Sends directly to the terminal tab that owns this live session."))
                    .font(.caption)
                    .foregroundStyle(unavailableReason == nil ? Color.secondary : Color.orange)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button {
                    model.sendAgentReply(to: item)
                } label: {
                    if model.isSendingAgentReply {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Send to Session", systemImage: "paperplane.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(replyFocusedItemID == item.id ? .defaultAction : nil)
                .disabled(unavailableReason != nil || !hasPrompt || model.isSendingAgentReply)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func metadata(for item: ClipItem) -> some View {
        HStack(spacing: 8) {
            metadataBadges(for: item)
            Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func metadataBadges(for item: ClipItem) -> some View {
        HStack(spacing: 8) {
            if let app = ApplicationMetadata(bundleID: item.sourceAppBundleID) {
                Label(app.name, systemImage: "app")
                    .badgeStyle()
            }
            if let project = item.projectName { Text(project).badgeStyle() }
            if let agent = item.agentID { Text("Agent \(agent.prefix(10))").badgeStyle() }
            if let session = item.sessionID { Text("Session \(session.prefix(8))").badgeStyle() }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            if let deletedTitle = model.recentlyDeletedTitle {
                HStack(spacing: 10) {
                    Image(systemName: "trash")
                    Text("Deleted “\(deletedTitle)”").lineLimit(1)
                    Spacer()
                    Button("Undo") { model.undoDelete() }
                        .keyboardShortcut("z", modifiers: .command)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.12))
                Divider()
            }
            HStack(spacing: 12) {
                HStack(spacing: 12) {
                    Text("\(settings.globalShortcut.displayName) Open")
                    Text("↑↓ Navigate")
                    Text("⌘C Copy")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                if let item = model.selectedItem {
                    Button {
                        model.togglePinned(item)
                    } label: {
                        Label(item.isPinned ? "Unpin" : "Pin", systemImage: item.isPinned ? "pin.slash" : "pin")
                    }
                    .labelStyle(.iconOnly)
                    .help(item.isPinned ? "Unpin" : "Pin")

                    Button("Delete", role: .destructive) { model.delete(item) }
                        .keyboardShortcut(.delete, modifiers: [])

                    if settings.autoPaste {
                        Button("Copy") { onCopy(item) }
                            .keyboardShortcut("c", modifiers: .command)
                    } else {
                        Button(action: { onCopy(item) }) { EmptyView() }
                            .keyboardShortcut("c", modifiers: .command)
                            .frame(width: 0, height: 0)
                            .accessibilityHidden(true)
                    }

                    if !settings.autoPaste, model.pasteTargetName != nil {
                        Button(pasteActionLabel) { onPaste(item) }
                    }

                    Button(primaryActionLabel) { onActivate(item) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(replyFocusedItemID == nil ? .defaultAction : nil)
                }
                Button("Close") { onDismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .controlSize(.regular)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
    }

    private var primaryActionLabel: String {
        guard settings.autoPaste, let target = model.pasteTargetName else { return String(localized: "Copy") }
        return String(format: String(localized: "Paste to %@"), target)
    }

    private var pasteActionLabel: String {
        guard let target = model.pasteTargetName else { return String(localized: "Copy (no destination app)") }
        return String(format: String(localized: "Paste to %@"), target)
    }
}

private struct OnboardingRow: View {
    let icon: String
    let title: LocalizedStringKey
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary)
            }
        }
    }
}

private struct PaneHeader: View {
    let title: LocalizedStringKey
    let count: Int?

    init(title: LocalizedStringKey, count: Int? = nil) {
        self.title = title
        self.count = count
    }

    var body: some View {
        HStack(spacing: 7) {
            Text(title)
                .font(.headline)
            if let count {
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(.bar)
    }
}

private struct AgentRow: View {
    let session: AgentSessionSummary

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: providerIcon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(providerColor)
                .frame(width: 28, height: 28)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.provider.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(identityLabel)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let project = session.projectPath {
                    Text(URL(fileURLWithPath: project).lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 4) {
                    Text("\(session.itemCount) responses")
                    Text("·")
                    Text(session.lastSeenAt, style: .relative)
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }

    private var identityLabel: String {
        let prefix = session.agentID == nil ? String(localized: "Session") : String(localized: "Agent")
        return "\(prefix) \(session.identityID.prefix(10))"
    }

    private var providerIcon: String {
        switch session.provider {
        case .claude: "sparkles"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .gajae: "shippingbox.fill"
        case .gemini: "diamond.fill"
        case .copilot: "infinity"
        case .cursor: "cursorarrow.rays"
        case .opencode: "terminal.fill"
        case .clipboard: "doc.on.clipboard"
        }
    }

    private var providerColor: Color {
        switch session.provider {
        case .claude: .orange
        case .codex: .green
        case .gajae: .pink
        case .gemini: .blue
        case .copilot: .purple
        case .cursor: .cyan
        case .opencode: .mint
        case .clipboard: .secondary
        }
    }
}

private struct NoticeBanner: View {
    let notice: PaletteNotice
    let onAction: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: notice.systemImage).foregroundStyle(.tint)
            Text(notice.message).lineLimit(2)
            Spacer()
            if let action = notice.action {
                Button(action == .showAll ? "Show all" : "Resume") { onAction() }
            }
            Button(action: onDismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.1))
    }
}

private struct PassiveStatusBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "info.circle.fill")
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.1))
    }
}

private struct AdaptiveQuestionText: View {
    let text: String

    @State private var contentHeight: CGFloat = 18

    private let maximumHeight: CGFloat = 140

    var body: some View {
        ScrollView(.vertical) {
            Text(text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: QuestionTextHeightKey.self,
                            value: geometry.size.height
                        )
                    }
                }
                .padding(.trailing, contentHeight > maximumHeight ? 8 : 0)
        }
        .frame(height: min(max(contentHeight, 18), maximumHeight))
        .scrollIndicators(contentHeight > maximumHeight ? .visible : .hidden)
        .onPreferenceChange(QuestionTextHeightKey.self) { measuredHeight in
            guard measuredHeight > 0, abs(contentHeight - measuredHeight) > 0.5 else { return }
            contentHeight = measuredHeight
        }
    }
}

private struct QuestionTextHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 18

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct AgentActivityBanner: View {
    let activity: AgentActivityNotice
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: activity.kind == .failed ? "exclamationmark.triangle.fill" : "person.wave.2.fill")
                .foregroundStyle(activity.kind == .failed ? .red : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.title).font(.headline)
                Text(activity.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button(action: onDismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }
}

private struct ItemRow: View {
    let item: ClipItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ItemThumbnail(item: item)
            VStack(alignment: .leading, spacing: 4) {
                Text(rowTitle).lineLimit(2)
                HStack(spacing: 5) {
                    Text(item.source.displayName)
                    if let app = ApplicationMetadata(bundleID: item.sourceAppBundleID) { Text("· \(app.name)") }
                    if let project = item.projectName { Text("· \(project)") }
                    Spacer()
                    Text(item.createdAt, style: .relative)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Pinned")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var rowTitle: String {
        guard item.kind == .image, let info = ImageMetadata(item: item) else { return item.title }
        return "\(info.dimensions) · \(info.size)"
    }

    static func icon(for item: ClipItem) -> String {
        switch item.source {
        case .claude: "sparkles"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .gajae: "shippingbox.fill"
        case .gemini: "diamond.fill"
        case .copilot: "infinity"
        case .cursor: "cursorarrow.rays"
        case .opencode: "terminal.fill"
        case .clipboard:
            switch item.kind {
            case .url: "link"
            case .image: "photo"
            case .file: "doc"
            default: "doc.on.clipboard"
            }
        }
    }
}

private struct ItemThumbnail: View {
    let item: ClipItem

    var body: some View {
        Group {
            if item.kind == .image, let path = item.payloadPath, let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipped()
            } else if let app = ApplicationMetadata(bundleID: item.sourceAppBundleID) {
                Image(nsImage: app.icon)
                    .resizable()
                    .scaledToFit()
                    .padding(5)
            } else {
                Image(systemName: ItemRow.icon(for: item))
                    .foregroundStyle(color)
            }
        }
        .frame(width: 42, height: 42)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .accessibilityHidden(true)
    }

    private var color: Color {
        switch item.source {
        case .claude: .orange
        case .codex: .green
        case .gajae: .pink
        case .gemini: .blue
        case .copilot: .purple
        case .cursor: .cyan
        case .opencode: .mint
        case .clipboard: .blue
        }
    }
}

private struct ImagePreview: View {
    let item: ClipItem

    var body: some View {
        if let path = item.payloadPath, let image = NSImage(contentsOfFile: path) {
            VStack(alignment: .leading, spacing: 8) {
                if let info = ImageMetadata(item: item) {
                    Text("\(info.dimensions) · \(info.format.uppercased()) · \(info.size)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(item.title)
            }
        } else {
            ContentUnavailableView("Image unavailable", systemImage: "photo.badge.exclamationmark")
        }
    }
}

private struct FilePreview: View {
    let item: ClipItem

    private var urls: [URL] {
        item.text.components(separatedBy: .newlines).filter { !$0.isEmpty }.map(URL.init(fileURLWithPath:))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(urls, id: \.path) { url in
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            .resizable().frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(url.lastPathComponent).lineLimit(1)
                            Text(url.deletingLastPathComponent().path)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Open") { NSWorkspace.shared.open(url) }
                        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}

private struct URLPreview: View {
    let item: ClipItem

    var body: some View {
        if let url = URL(string: item.text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            VStack(alignment: .leading, spacing: 14) {
                Label(url.host ?? url.absoluteString, systemImage: "link")
                    .font(.title3.bold())
                Text(url.absoluteString)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                Link("Open Link", destination: url)
                    .buttonStyle(.borderedProminent)
                Spacer()
            }
        } else {
            Text(item.text).textSelection(.enabled)
        }
    }
}

private struct ApplicationMetadata {
    let name: String
    let icon: NSImage

    init?(bundleID: String?) {
        guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        name = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        icon = NSWorkspace.shared.icon(forFile: url.path)
    }
}

private struct ImageMetadata {
    let dimensions: String
    let size: String
    let format: String

    init?(item: ClipItem) {
        guard let path = item.payloadPath, let image = NSImage(contentsOfFile: path) else { return nil }
        let representation = image.representations.max { lhs, rhs in
            lhs.pixelsWide * lhs.pixelsHigh < rhs.pixelsWide * rhs.pixelsHigh
        }
        let width = representation?.pixelsWide ?? Int(image.size.width)
        let height = representation?.pixelsHigh ?? Int(image.size.height)
        dimensions = "\(width)×\(height)"
        format = URL(fileURLWithPath: path).pathExtension
        let bytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
        size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct MarkdownPreview: View {
    let markdown: String

    private var lines: [String] {
        markdown.components(separatedBy: .newlines)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 7) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                MarkdownLine(line: line)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct MarkdownLine: View {
    let line: String

    var body: some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            Color.clear.frame(height: 3)
        } else if let heading = heading {
            Text(inlineMarkdown: heading.text)
                .font(heading.font)
                .padding(.top, heading.level == 1 ? 4 : 1)
        } else if let bullet = bulletText {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•")
                    .foregroundStyle(.secondary)
                Text(inlineMarkdown: bullet)
            }
            .padding(.leading, 4)
        } else {
            Text(inlineMarkdown: line)
        }
    }

    private var heading: (level: Int, text: String, font: Font)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let marker = trimmed.prefix(while: { $0 == "#" })
        guard (1...3).contains(marker.count), trimmed.dropFirst(marker.count).first == " " else { return nil }
        let text = trimmed.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        let font: Font = switch marker.count {
        case 1: .title2.bold()
        case 2: .title3.bold()
        default: .headline
        }
        return (marker.count, text, font)
    }

    private var bulletText: String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") else { return nil }
        return String(trimmed.dropFirst(2))
    }
}

private extension Text {
    init(inlineMarkdown: String) {
        if let attributed = try? AttributedString(
            markdown: inlineMarkdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            self.init(attributed)
        } else {
            self.init(inlineMarkdown)
        }
    }
}

private extension View {
    func badgeStyle() -> some View {
        self
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
    }
}
