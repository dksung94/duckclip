import AppKit
import DuckClipCore
import SwiftUI

struct PaletteView: View {
    @ObservedObject var model: AppModel
    let onActivate: (ClipItem) -> Void
    let onPaste: (ClipItem) -> Void
    let onCopy: (ClipItem) -> Void
    let onDismiss: () -> Void

    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                itemList
                    .frame(minWidth: 330, idealWidth: 390)
                preview
                    .frame(minWidth: 300)
            }
            Divider()
            footer
        }
        .frame(minWidth: 680, minHeight: 420)
        .background(.ultraThinMaterial)
        .onAppear {
            searchFocused = true
            model.reload()
        }
        .onMoveCommand { direction in
            switch direction {
            case .up: model.moveSelection(by: -1, orderedIDs: visibleItemIDs)
            case .down: model.moveSelection(by: 1, orderedIDs: visibleItemIDs)
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

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search clipboard and agent responses", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($searchFocused)
                    .onSubmit {
                        if let item = model.selectedItem { onActivate(item) }
                    }
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
                        Text(filter.displayName).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)

                if model.sourceFilter != .clipboard {
                    Picker("Project", selection: $model.projectFilter) {
                        Text("All projects").tag(String?.none)
                        ForEach(model.projects, id: \.self) { path in
                            Text(projectLabel(path)).tag(String?.some(path))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 170)

                    Picker("Agent or session", selection: $model.conversationFilter) {
                        Text("All agents & sessions").tag(String?.none)
                        ForEach(model.filteredSessions) { session in
                            Text(conversationLabel(session)).tag(String?.some(session.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 210)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
    }

    private var itemList: some View {
        Group {
            if missingAgentIntegrations && model.items.isEmpty {
                ContentUnavailableView {
                    Label("Agent integrations are not installed", systemImage: "link.badge.plus")
                } description: {
                    Text("Install the Claude and Codex hooks before DuckClip can collect new responses.")
                } actions: {
                    Button("Install integrations") { model.installHooks() }
                }
            } else if model.items.isEmpty {
                ContentUnavailableView(
                    "Nothing found",
                    systemImage: "doc.on.clipboard",
                    description: Text("Copy something or adjust the filters.")
                )
            } else {
                List(selection: $model.selectedItemID) {
                    ForEach(itemGroups) { group in
                        Section {
                            ForEach(group.items) { item in
                                ItemRow(item: item)
                                    .tag(item.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        model.selectedItemID = item.id
                                    }
                                    .simultaneousGesture(
                                        TapGesture(count: 2)
                                            .onEnded { onActivate(item) }
                                    )
                                    .accessibilityAction(.default) { onActivate(item) }
                                    .accessibilityAction(named: Text("Copy")) { onCopy(item) }
                                    .accessibilityAction(named: Text("Paste")) { onPaste(item) }
                                    .contextMenu {
                                        Button("Paste") { onPaste(item) }
                                        Button("Copy") { onCopy(item) }
                                        Button(item.isPinned ? String(localized: "Unpin") : String(localized: "Pin")) {
                                            model.togglePinned(item)
                                        }
                                        Divider()
                                        Button("Delete", role: .destructive) { model.delete(item) }
                                    }
                            }
                        } header: {
                            ItemGroupHeader(group: group)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var missingAgentIntegrations: Bool {
        model.sourceFilter == .agents
            && !model.hookStatus.claudeInstalled
            && !model.hookStatus.codexInstalled
    }

    private var itemGroups: [ItemGroup] {
        if !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [ItemGroup(id: "search-results", items: model.items, title: String(localized: "Search results"))]
        }
        var groups: [String: ItemGroup] = [:]
        var order: [String] = []
        for item in model.items {
            let key: String
            if item.source == .clipboard {
                key = "clipboard"
            } else {
                key = [
                    item.source.rawValue,
                    item.projectPath ?? "",
                    item.agentIdentityID ?? "unassigned"
                ].joined(separator: ":")
            }
            if groups[key] == nil {
                order.append(key)
                groups[key] = ItemGroup(id: key, items: [])
            }
            groups[key]?.items.append(item)
        }
        return order.compactMap { groups[$0] }
    }

    private var visibleItemIDs: [String] {
        itemGroups.flatMap { $0.items.map(\.id) }
    }

    private func projectLabel(_ path: String) -> String {
        let components = URL(fileURLWithPath: path).standardized.pathComponents
        return components.suffix(2).joined(separator: "/")
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

                HStack(spacing: 8) {
                    if let project = item.projectName {
                        Text(project).badgeStyle()
                    }
                    if let agent = item.agentID {
                        Text("Agent \(agent.prefix(10))").badgeStyle()
                    }
                    if let session = item.sessionID {
                        Text("Session \(session.prefix(8))").badgeStyle()
                    }
                    Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                switch item.kind {
                case .image:
                    if let path = item.payloadPath, let image = NSImage(contentsOfFile: path) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityLabel(item.title)
                    } else {
                        ContentUnavailableView("Image unavailable", systemImage: "photo.badge.exclamationmark")
                    }
                default:
                    ScrollView {
                        Text(item.text)
                            .font(.system(.body, design: item.source == .clipboard ? .default : .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(.trailing, 8)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(16)
        } else {
            ContentUnavailableView("Select an item", systemImage: "cursorarrow.click")
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            if let deletedTitle = model.recentlyDeletedTitle {
                HStack(spacing: 10) {
                    Image(systemName: "trash")
                    Text("Deleted “\(deletedTitle)”")
                        .lineLimit(1)
                    Spacer()
                    Button("Undo") { model.undoDelete() }
                        .keyboardShortcut("z", modifiers: .command)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.12))
                Divider()
            }
            HStack(spacing: 14) {
                HStack(spacing: 14) {
                    Text("\(model.settings.globalShortcut.displayName) Open")
                    Text("↑↓ Navigate")
                    Text(model.settings.autoPaste
                        ? LocalizedStringKey("↩ Paste")
                        : LocalizedStringKey("↩ Copy"))
                }
                .foregroundStyle(.secondary)
                Spacer()
                if let item = model.selectedItem {
                    Button(item.isPinned ? String(localized: "Unpin") : String(localized: "Pin")) {
                        model.togglePinned(item)
                    }
                    Button("Copy") { onCopy(item) }
                    Button("Paste") { onPaste(item) }
                }
                Button("Close") { onDismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .font(.caption)
    }
}

private struct ItemGroup: Identifiable {
    let id: String
    var items: [ClipItem]
    var title: String?

    init(id: String, items: [ClipItem], title: String? = nil) {
        self.id = id
        self.items = items
        self.title = title
    }

    var representative: ClipItem? { items.first }
}

private struct ItemGroupHeader: View {
    let group: ItemGroup

    var body: some View {
        if let item = group.representative {
            HStack(spacing: 6) {
                if let title = group.title {
                    Text(title)
                } else if item.source == .clipboard {
                    Label("Clipboard", systemImage: "doc.on.clipboard")
                } else {
                    let kind = item.agentID == nil ? String(localized: "Session") : String(localized: "Agent")
                    let identity = item.agentIdentityID ?? String(localized: "Unassigned")
                    Text("\(kind) \(identity.prefix(12))")
                    Text(item.source.displayName)
                        .providerBadge(item.source)
                    if let project = item.projectName {
                        Text(project)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Text("\(group.items.count)")
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .textCase(nil)
        }
    }
}

private struct ItemRow: View {
    let item: ClipItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: Self.icon(for: item))
                .frame(width: 20)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(item.source.displayName)
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
    }

    static func icon(for item: ClipItem) -> String {
        switch item.source {
        case .claude: "sparkles"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .clipboard:
            switch item.kind {
            case .url: "link"
            case .image: "photo"
            case .file: "doc"
            default: "doc.on.clipboard"
            }
        }
    }

    private var color: Color {
        switch item.source {
        case .claude: .orange
        case .codex: .green
        case .clipboard: .blue
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

    func providerBadge(_ source: ItemSource) -> some View {
        self
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(source == .claude ? Color.orange.opacity(0.18) : Color.green.opacity(0.18), in: Capsule())
    }
}
