import AppKit
import DuckClipCore
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: DuckClipSettings
    @State private var confirmClear = false
    @State private var confirmRemoveIntegrations = false

    init(model: AppModel) {
        self.model = model
        _settings = ObservedObject(wrappedValue: model.settings)
    }

    var body: some View {
        TabView {
            Form {
                Toggle("Record clipboard history", isOn: $settings.captureEnabled)
                Toggle("Paste immediately after choosing an item", isOn: Binding(
                    get: { settings.autoPaste },
                    set: { model.setAutoPaste($0) }
                ))
                if settings.autoPaste {
                    HStack {
                        Label(
                            model.accessibilityTrusted
                                ? String(localized: "Automatic paste is ready")
                                : String(localized: "Accessibility permission is required"),
                            systemImage: model.accessibilityTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(model.accessibilityTrusted ? .green : .orange)
                        Spacer()
                        if !model.accessibilityTrusted {
                            Button("Open System Settings") { model.openAccessibilitySettings() }
                        }
                    }
                    .font(.caption)
                }
                Toggle("Launch DuckClip at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                Stepper("Keep unpinned items for \(settings.retentionDays) days", value: $settings.retentionDays, in: 1...365)

                Picker("Global shortcut", selection: $settings.globalShortcut) {
                    ForEach(GlobalShortcut.allCases) { shortcut in
                        Text(shortcut.displayName).tag(shortcut)
                    }
                }
                if !model.shortcutRegistrationSucceeded {
                    Label(
                        "This shortcut is unavailable. Choose another shortcut.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                Button("Clear all unpinned history", role: .destructive) {
                    confirmClear = true
                }
            }
            .padding(20)
            .tabItem { Label("General", systemImage: "gear") }

            Form {
                Toggle("Agent notifications", isOn: Binding(
                    get: { settings.notificationsEnabled },
                    set: { model.setNotificationsEnabled($0) }
                ))
                HStack {
                    Label(notificationStatusText, systemImage: notificationStatusIcon)
                        .foregroundStyle(notificationStatusColor)
                    Spacer()
                    if model.notificationAuthorizationStatus == .denied {
                        Button("Open System Settings") { model.openNotificationSettings() }
                    }
                }
                .font(.caption)
                Toggle("Response and input notifications", isOn: $settings.completionNotifications)
                    .disabled(!settings.notificationsEnabled)
                Toggle("Approval and failure notifications", isOn: $settings.approvalNotifications)
                    .disabled(!settings.notificationsEnabled)
                Picker("Notification preview", selection: $settings.notificationPreviewMode) {
                    ForEach(NotificationPreviewMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .disabled(!settings.notificationsEnabled)

                integrationRow(model.hookStatus.claude)
                integrationRow(model.hookStatus.codex)

                HStack {
                    Button("Install integrations") { model.installHooks() }
                    Button("Remove integrations", role: .destructive) { confirmRemoveIntegrations = true }
                }

                Text("Codex may ask you to trust a newly installed hook. Run /hooks in Codex if capture does not start immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Managed helper") {
                    Text(model.hookStatus.managedHelperPath)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                if !model.integrationTestStatus.isEmpty {
                    Text(model.integrationTestStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                HStack {
                    Button("Import Claude history") { model.importHistory(provider: .claude) }
                    Button("Import Codex history") { model.importHistory(provider: .codex) }
                    Button("Import both") { model.importHistory() }
                }
                .disabled(model.isImporting)
                if model.isImporting {
                    ProgressView(model.importStatus)
                } else if !model.importStatus.isEmpty {
                    Text(model.importStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .tabItem { Label("Agents", systemImage: "sparkles") }

            Form {
                Section("Excluded applications") {
                    Text("Clipboard changes copied from these applications are not recorded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if excludedApps.isEmpty {
                        Text("No excluded applications")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(excludedApps, id: \.self) { bundleID in
                            HStack(spacing: 10) {
                                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                        .resizable()
                                        .frame(width: 24, height: 24)
                                        .accessibilityHidden(true)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(applicationName(bundleID))
                                    Text(bundleID)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                Spacer()
                                Button {
                                    removeExcludedApp(bundleID)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .help("Allow clipboard recording from this application")
                                .accessibilityLabel("Remove \(applicationName(bundleID)) from exclusions")
                            }
                        }
                    }
                    Button("Choose Applications…") { chooseApplications() }
                }

                Section("Excluded project folders") {
                    Text("Agent responses from these folders and their descendants are ignored.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if excludedProjects.isEmpty {
                        Text("No excluded project folders")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(excludedProjects, id: \.self) { path in
                            HStack {
                                Image(systemName: "folder")
                                    .accessibilityHidden(true)
                                Text(path)
                                    .font(.caption.monospaced())
                                    .lineLimit(2)
                                    .textSelection(.enabled)
                                Spacer()
                                Button {
                                    removeExcludedProject(path)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .help("Include this project folder")
                                .accessibilityLabel("Remove project folder from exclusions")
                            }
                        }
                    }
                    Button("Choose Project Folders…") { chooseProjectFolders() }
                }
            }
            .padding(20)
            .tabItem { Label("Privacy", systemImage: "hand.raised") }
        }
        .frame(width: 680, height: 520)
        .onAppear {
            model.refreshIntegrationStatus()
            model.refreshNotificationAuthorization()
            model.refreshAccessibilityPermission()
        }
        .confirmationDialog(
            "Clear all unpinned history?",
            isPresented: $confirmClear,
            titleVisibility: .visible
        ) {
            Button("Clear history", role: .destructive) { model.clearUnpinned() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Pinned items are kept. This cannot be undone.")
        }
        .confirmationDialog(
            "Remove DuckClip integrations?",
            isPresented: $confirmRemoveIntegrations,
            titleVisibility: .visible
        ) {
            Button("Remove Claude and Codex integrations", role: .destructive) { model.uninstallHooks() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("DuckClip hooks will be removed from both Claude and Codex. Existing clipboard history is kept.")
        }
        .alert("DuckClip", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.dismissError() } }
        )) {
            Button("OK", role: .cancel) { model.dismissError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func integrationRow(_ status: ProviderHookStatus) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(status.provider.displayName)
                    .font(.headline)
                Spacer()
                statusLabel(status.installed)
                Button("Test") { model.testHook(status.provider) }
                    .disabled(!status.installed)
            }
            if !status.helperExecutable {
                Text("Managed helper is missing or not executable.")
                    .foregroundStyle(.red)
            } else if !status.missingEvents.isEmpty {
                Text("Missing events: \(status.missingEvents.joined(separator: ", "))")
                    .foregroundStyle(.orange)
            }
            if let health = model.providerHealth[status.provider], let date = health.lastEventAt {
                Text("Last event: \(health.lastEventKind?.rawValue ?? "unknown") · \(date.formatted(date: .abbreviated, time: .standard))")
                    .foregroundStyle(.secondary)
            } else {
                Text("No event received yet.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    private func statusLabel(_ installed: Bool) -> some View {
        Label(
            installed ? String(localized: "Ready") : String(localized: "Needs setup"),
            systemImage: installed ? "checkmark.circle.fill" : "exclamationmark.circle"
        )
            .foregroundStyle(installed ? .green : .secondary)
    }

    private var excludedApps: [String] {
        settings.excludedAppBundleIDs.sorted()
    }

    private var excludedProjects: [String] {
        settings.excludedProjectPaths.sorted()
    }

    private var notificationStatusText: String {
        switch model.notificationAuthorizationStatus {
        case .authorized, .provisional: String(localized: "Allowed by macOS")
        case .denied: String(localized: "Blocked by macOS")
        case .notDetermined: String(localized: "Permission will be requested when enabled")
        @unknown default: String(localized: "Notification permission is unavailable")
        }
    }

    private var notificationStatusIcon: String {
        switch model.notificationAuthorizationStatus {
        case .authorized, .provisional: "checkmark.circle.fill"
        case .denied: "xmark.circle.fill"
        case .notDetermined: "bell.badge"
        @unknown default: "questionmark.circle"
        }
    }

    private var notificationStatusColor: Color {
        switch model.notificationAuthorizationStatus {
        case .authorized, .provisional: .green
        case .denied: .red
        case .notDetermined: .secondary
        @unknown default: .secondary
        }
    }

    private func applicationName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
    }

    private func chooseApplications() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose applications to exclude")
        panel.prompt = String(localized: "Exclude")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK else { return }
        let selected = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        let values = Set(excludedApps).union(selected).sorted()
        settings.excludedAppsText = values.joined(separator: "\n")
    }

    private func chooseProjectFolders() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose project folders to exclude")
        panel.prompt = String(localized: "Exclude")
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK else { return }
        let selected = panel.urls.map { $0.standardizedFileURL.path }
        let values = Set(excludedProjects).union(selected).sorted()
        settings.excludedProjectsText = values.joined(separator: "\n")
    }

    private func removeExcludedApp(_ bundleID: String) {
        settings.excludedAppsText = excludedApps.filter { $0 != bundleID }.joined(separator: "\n")
    }

    private func removeExcludedProject(_ path: String) {
        settings.excludedProjectsText = excludedProjects.filter { $0 != path }.joined(separator: "\n")
    }
}
