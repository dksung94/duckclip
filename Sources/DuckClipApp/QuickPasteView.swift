import AppKit
import DuckClipCore
import SwiftUI

struct QuickPasteView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: QuickPastePanelState
    let onPaste: (ClipItem) -> Void
    let onCopy: (ClipItem) -> Void
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var items: [ClipItem] = []
    @State private var selectedItemID: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            results
            Divider()
            footer
            keyboardActions
        }
        .frame(width: 560, height: 510)
        .background(.ultraThinMaterial)
        .onAppear {
            query = ""
            selectedItemID = nil
            refresh()
            searchFocused = true
        }
        .onChange(of: query) { _, _ in refresh() }
        .onChange(of: state.refreshToken) { _, _ in
            query = ""
            selectedItemID = nil
            refresh()
            searchFocused = true
        }
        .onMoveCommand { direction in
            switch direction {
            case .up: moveSelection(by: -1)
            case .down: moveSelection(by: 1)
            default: break
            }
        }
        .onExitCommand(perform: onDismiss)
        .alert("DuckClip", isPresented: Binding(
            get: { state.isPresented && model.errorMessage != nil },
            set: { if !$0 { model.dismissError() } }
        )) {
            if model.accessibilityPermissionRequired {
                Button("Open Accessibility Settings") { model.openAccessibilitySettings() }
                if let item = selectedItem {
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

    private var searchBar: some View {
        HStack(spacing: 12) {
            Text("DuckClip")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                TextField("Search recent copies", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($searchFocused)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
        }
        .padding(.horizontal, 16)
        .padding(.top, 13)
        .padding(.bottom, 11)
    }

    @ViewBuilder
    private var results: some View {
        if items.isEmpty {
            ContentUnavailableView {
                Label("No matching copies", systemImage: "doc.on.clipboard")
            } description: {
                Text(query.isEmpty ? "Copy something to add it to DuckClip." : "Try a different search.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            QuickPasteRow(item: item, shortcutNumber: index + 1, isSelected: item.id == selectedItemID)
                                .id(item.id)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedItemID = item.id }
                                .simultaneousGesture(TapGesture(count: 2).onEnded { onPaste(item) })
                            if index < items.count - 1 {
                                Divider().padding(.leading, 60)
                            }
                        }
                    }
                    .padding(.vertical, 5)
                }
                .onChange(of: selectedItemID) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("⌘1–9 Paste")
            Text("↑↓ Navigate")
            Spacer()
            if let targetName = state.targetName {
                Text("Paste to \(targetName)")
                    .lineLimit(1)
            } else {
                Text("Copy (no destination app)")
            }
            Button("Close", action: onDismiss)
                .keyboardShortcut(.cancelAction)
            Button("Paste") {
                if let selectedItem { onPaste(selectedItem) }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(selectedItem == nil)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 48)
    }

    private var keyboardActions: some View {
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            Button(action: { onPaste(item) }) { Text("\(index + 1)") }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private var selectedItem: ClipItem? {
        selectedItemID.flatMap { id in items.first { $0.id == id } }
    }

    private func refresh() {
        items = model.recentClipboardItems(query: query, limit: 9)
        if let selectedItemID, items.contains(where: { $0.id == selectedItemID }) {
            return
        }
        selectedItemID = items.first?.id
    }

    private func moveSelection(by offset: Int) {
        guard !items.isEmpty else { return }
        let current = selectedItemID.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
        selectedItemID = items[min(max(current + offset, 0), items.count - 1)].id
    }
}

private struct QuickPasteRow: View {
    let item: ClipItem
    let shortcutNumber: Int
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 11) {
            thumbnail
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(kindLabel)
                    if let appName { Text("· \(appName)") }
                    Text("·")
                    Text(item.createdAt, style: .relative)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text("⌘\(shortcutNumber)")
                .font(.body.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
    }

    @ViewBuilder
    private var thumbnail: some View {
        Group {
            if item.kind == .image, let path = item.payloadPath, let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipped()
            } else if let icon = appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .padding(4)
            } else {
                Image(systemName: systemImage)
                    .foregroundStyle(.blue)
            }
        }
        .frame(width: 34, height: 34)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .accessibilityHidden(true)
    }

    private var title: String {
        if item.kind == .file {
            return item.text.components(separatedBy: .newlines).first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? item.title
        }
        return item.title
    }

    private var kindLabel: String {
        switch item.kind {
        case .text: String(localized: "Text")
        case .url: "URL"
        case .image: String(localized: "Image")
        case .file: String(localized: "File")
        case .agentResponse: String(localized: "Agent response")
        }
    }

    private var systemImage: String {
        switch item.kind {
        case .url: "link"
        case .image: "photo"
        case .file: "doc"
        default: "doc.on.clipboard"
        }
    }

    private var appURL: URL? {
        item.sourceAppBundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }

    private var appIcon: NSImage? {
        appURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    private var appName: String? {
        guard let appURL else { return nil }
        return Bundle(url: appURL)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle(url: appURL)?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? appURL.deletingPathExtension().lastPathComponent
    }
}
