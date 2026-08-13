import AppKit
import Combine
import DuckClipCore
import Foundation
import ServiceManagement
import UserNotifications

struct LibraryCounts: Equatable, Sendable {
    var all = 0
    var clipboard = 0
    var agents = 0

    subscript(_ filter: SourceFilter) -> Int {
        switch filter {
        case .all: all
        case .clipboard: clipboard
        case .agents: agents
        }
    }
}

struct PaletteNotice: Identifiable, Equatable {
    enum Action: Equatable {
        case showAll
        case resumeCapture
    }

    let id = UUID()
    let message: String
    let systemImage: String
    let action: Action?
}

struct AgentActivityNotice: Identifiable, Equatable {
    let id = UUID()
    let provider: ItemSource
    let kind: AgentEventKind
    let title: String
    let message: String
}

@MainActor
final class AppModel: ObservableObject {
    @Published var items: [ClipItem] = []
    @Published var sessions: [AgentSessionSummary] = []
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            resultLimit = 300
            reload(refreshSessions: false, debounce: true)
        }
    }
    @Published var sourceFilter: SourceFilter = .all {
        didSet {
            guard sourceFilter != oldValue else { return }
            resultLimit = 300
            projectFilter = nil
            conversationFilter = nil
            reload(refreshSessions: false)
        }
    }
    @Published var projectFilter: String? {
        didSet {
            guard projectFilter != oldValue else { return }
            resultLimit = 300
            conversationFilter = nil
            reload(refreshSessions: false)
        }
    }
    @Published var conversationFilter: String? {
        didSet {
            guard conversationFilter != oldValue else { return }
            resultLimit = 300
            if sourceFilter == .agents {
                selectedItemID = nil
            }
            reload(refreshSessions: false)
        }
    }
    @Published var selectedItemID: String? {
        didSet {
            guard selectedItemID != oldValue else { return }
            agentReplyDraft = ""
        }
    }
    @Published var agentReplyDraft = ""
    @Published var isSendingAgentReply = false
    @Published var errorMessage: String?
    @Published var passiveStatusMessage: String?
    @Published var paletteNotice: PaletteNotice?
    @Published var agentActivityNotice: AgentActivityNotice?
    @Published var itemCounts = LibraryCounts()
    @Published var resultsTruncated = false
    @Published var pasteTargetName: String?
    @Published var hookStatus = HookInstallationStatus.empty
    @Published var providerHealth: [ItemSource: ProviderHealth] = [:]
    @Published var integrationTestStatus = ""
    @Published var importStatus = ""
    @Published var isImporting = false
    @Published var shortcutRegistrationSucceeded = true
    @Published var quickPasteShortcutRegistrationSucceeded = true
    @Published var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published var notificationRequestInFlight = false
    @Published var accessibilityPermissionRequired = false
    @Published var accessibilityTrusted = false
    @Published var recentlyDeletedTitle: String?

    let settings: DuckClipSettings
    let store: SQLiteStore
    let paths: AppPaths

    private let blobStore: BlobStore
    private let pasteCoordinator = PasteCoordinator()
    private let clipboardMonitor: ClipboardMonitor
    private let inboxMonitor: AgentInboxMonitor
    private let hookInstaller: HookInstaller
    private let historyImporter: HistoryImporter
    private let agentReplyLauncher = AgentReplyLauncher()
    private let notifications = NotificationCoordinator()
    private var reloadTask: Task<Void, Never>?
    private var reloadGeneration = 0
    private var resultLimit = 300
    private var pendingDeletion: ClipItem?
    private var deletionTask: Task<Void, Never>?
    private var passiveStatusTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    var openPalette: ((String?) -> Void)? {
        didSet { notifications.onOpen = openPalette }
    }

    init() throws {
        paths = try AppPaths()
        store = try SQLiteStore(url: paths.database)
        settings = DuckClipSettings()
        blobStore = BlobStore(directory: paths.blobs)
        clipboardMonitor = ClipboardMonitor(blobStore: blobStore, settings: settings)
        inboxMonitor = AgentInboxMonitor(inbox: paths.inbox)
        hookInstaller = HookInstaller()
        historyImporter = HistoryImporter(store: store)

        clipboardMonitor.onCapture = { [weak self] item in self?.storeItem(item) }
        clipboardMonitor.onStatus = { [weak self] status in self?.handleClipboardStatus(status) }
        inboxMonitor.onEvent = { [weak self] event in self?.handle(event) }
        inboxMonitor.onError = { [weak self] error in self?.showPassiveStatus(error.localizedDescription) }
        notifications.onCopy = { [weak self] itemID in self?.copy(itemID: itemID) }
        notifications.onError = { [weak self] message in self?.showPassiveStatus(message) }
        hookStatus = hookInstaller.status()
        reloadProviderHealth()
        reload()
        settings.$retentionDays
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in self?.purgeExpiredItems() }
            .store(in: &cancellables)
    }

    func start() {
        clipboardMonitor.start()
        inboxMonitor.start()
        refreshNotificationAuthorization()
        refreshAccessibilityPermission()
        if let orphanedPaths = try? store.deleteSoftDeleted() {
            orphanedPaths.forEach { blobStore.deleteIfPresent(path: $0) }
        }
        purgeExpiredItems()
        backfillAgentQuestionsIfNeeded()
    }

    var projects: [String] {
        Array(Set(sessions.compactMap(\.projectPath))).sorted {
            URL(fileURLWithPath: $0).lastPathComponent.localizedCaseInsensitiveCompare(
                URL(fileURLWithPath: $1).lastPathComponent
            ) == .orderedAscending
        }
    }

    var filteredSessions: [AgentSessionSummary] {
        sessions.filter { session in
            projectFilter == nil || session.projectPath == projectFilter
        }
    }

    var selectedConversation: AgentSessionSummary? {
        guard let conversationFilter else { return nil }
        return sessions.first { $0.id == conversationFilter }
    }

    var selectedItem: ClipItem? {
        guard let selectedItemID else { return items.first }
        return items.first { $0.id == selectedItemID }
    }

    func recentClipboardItems(query: String, limit: Int = 9) -> [ClipItem] {
        do {
            return try store.search(query: query, source: .clipboard, limit: limit)
        } catch {
            showPassiveStatus(error.localizedDescription)
            return []
        }
    }

    func moveSelection(by offset: Int, orderedIDs: [String]? = nil) {
        let ids = orderedIDs ?? items.map(\.id)
        guard !ids.isEmpty else { return }
        let currentIndex = selectedItemID.flatMap(ids.firstIndex(of:)) ?? 0
        let nextIndex = min(max(currentIndex + offset, 0), ids.count - 1)
        selectedItemID = ids[nextIndex]
    }

    var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func reload(refreshSessions: Bool = true, debounce: Bool = false) {
        reloadTask?.cancel()
        reloadGeneration += 1
        let generation = reloadGeneration
        let store = store
        let query = query
        let sourceFilter = sourceFilter
        let projectFilter = projectFilter
        let conversationFilter = conversationFilter
        let cachedSessions = sessions
        let limit = resultLimit

        reloadTask = Task { [weak self] in
            if debounce {
                do {
                    try await Task.sleep(for: .milliseconds(150))
                } catch {
                    return
                }
            }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let sessions = refreshSessions ? try store.sessions() : cachedSessions
                    let conversation = conversationFilter.flatMap { id in
                        sessions.first { $0.id == id }
                    }
                    var items = try store.search(
                        query: query,
                        source: conversation?.provider,
                        sources: conversation == nil ? sourceFilter.itemSources : nil,
                        projectPath: projectFilter,
                        sessionID: conversation?.sessionID,
                        agentID: conversation?.agentID,
                        limit: limit + 1
                    )
                    let truncated = items.count > limit
                    if truncated { items.removeLast() }
                    let counts = LibraryCounts(
                        all: try store.count(),
                        clipboard: try store.count(sources: [.clipboard]),
                        agents: try store.count(sources: ItemSource.agentSources)
                    )
                    return (sessions, items, conversationFilter != nil && conversation == nil, truncated, counts)
                }.value
                guard let self, !Task.isCancelled, generation == self.reloadGeneration else { return }
                self.sessions = result.0
                if result.2 {
                    self.conversationFilter = nil
                    return
                }
                self.items = result.1
                self.resultsTruncated = result.3
                self.itemCounts = result.4
                if let selectedItemID, !result.1.contains(where: { $0.id == selectedItemID }) {
                    self.selectedItemID = sourceFilter == .agents ? nil : result.1.first?.id
                } else if selectedItemID == nil, sourceFilter != .agents {
                    self.selectedItemID = result.1.first?.id
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, generation == self.reloadGeneration else { return }
                self.showPassiveStatus(error.localizedDescription)
            }
        }
    }

    func loadMore() {
        resultLimit += 300
        reload(refreshSessions: false)
    }

    func resetFilters() {
        query = ""
        sourceFilter = .all
        projectFilter = nil
        conversationFilter = nil
        resultLimit = 300
        paletteNotice = nil
        reload(refreshSessions: false)
    }

    func performNoticeAction(_ notice: PaletteNotice) {
        switch notice.action {
        case .showAll: resetFilters()
        case .resumeCapture:
            settings.captureEnabled = true
            paletteNotice = nil
            showPassiveStatus(String(localized: "Clipboard recording resumed"))
        case nil:
            paletteNotice = nil
        }
    }

    func dismissPaletteNotice() {
        paletteNotice = nil
    }

    func dismissAgentActivityNotice() {
        agentActivityNotice = nil
    }

    func agentReplyUnavailableReason(for item: ClipItem) -> String? {
        agentReplyLauncher.unavailableReason(for: item)
    }

    func sendAgentReply(to item: ClipItem) {
        guard !isSendingAgentReply else { return }
        let prompt = agentReplyDraft
        isSendingAgentReply = true
        Task { [weak self] in
            guard let self else { return }
            defer { isSendingAgentReply = false }
            do {
                try await agentReplyLauncher.send(item: item, prompt: prompt)
                if selectedItemID == item.id {
                    agentReplyDraft = ""
                }
                showPassiveStatus(String(
                    format: String(
                        localized: "reply.sent",
                        defaultValue: "Sent the reply to the live %@ session."
                    ),
                    item.source.displayName
                ))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func refreshIntegrationStatus() {
        hookStatus = hookInstaller.status()
        reloadProviderHealth()
    }

    @discardableResult
    func copy(_ item: ClipItem) -> Bool {
        do {
            try pasteCoordinator.copy(item)
            clipboardMonitor.acknowledgeCurrentContents()
            try store.markUsed(id: item.id)
            reload()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func paste(_ item: ClipItem, target: NSRunningApplication?) -> Bool {
        guard let target, !target.isTerminated else {
            let copied = copy(item)
            if copied {
                showPassiveStatus(String(localized: "The destination app is unavailable, so the item was copied instead."))
            }
            return copied
        }
        guard pasteCoordinator.isAccessibilityTrusted else {
            accessibilityPermissionRequired = true
            _ = pasteCoordinator.requestAccessibilityPermission()
            errorMessage = PasteCoordinator.PasteError.accessibilityPermissionRequired.localizedDescription
            return false
        }
        do {
            try pasteCoordinator.paste(item, targetApplication: target)
            clipboardMonitor.acknowledgeCurrentContents()
            try store.markUsed(id: item.id)
            reload()
            accessibilityPermissionRequired = false
            return true
        } catch PasteCoordinator.PasteError.targetUnavailable {
            clipboardMonitor.acknowledgeCurrentContents()
            try? store.markUsed(id: item.id)
            reload()
            showPassiveStatus(String(localized: "The destination app is unavailable, so the item was copied instead."))
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func togglePinned(_ item: ClipItem) {
        do {
            try store.setPinned(id: item.id, pinned: !item.isPinned)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ item: ClipItem) {
        do {
            finalizePendingDeletion()
            try store.softDelete(id: item.id)
            pendingDeletion = item
            recentlyDeletedTitle = item.title
            deletionTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(8))
                } catch {
                    return
                }
                self?.finalizePendingDeletion(expectedID: item.id)
            }
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func undoDelete() {
        guard let item = pendingDeletion else { return }
        deletionTask?.cancel()
        do {
            try store.restore(id: item.id)
            pendingDeletion = nil
            recentlyDeletedTitle = nil
            selectedItemID = item.id
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearUnpinned() {
        do {
            finalizePendingDeletion()
            let orphanedPaths = try store.clearUnpinned()
            orphanedPaths.forEach { blobStore.deleteIfPresent(path: $0) }
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func installHooks() {
        do {
            try hookInstaller.install()
            hookStatus = hookInstaller.status()
            integrationTestStatus = String(localized: "Integrations installed. Use Test to verify event delivery.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func uninstallHooks() {
        do {
            try hookInstaller.uninstall()
            hookStatus = hookInstaller.status()
            integrationTestStatus = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func testHook(_ provider: ItemSource) {
        do {
            try hookInstaller.runSmokeTest(provider: provider)
            integrationTestStatus = String(
                format: String(localized: "integration.test.sent", defaultValue: "%@ test event sent. Waiting for DuckClip…"),
                provider.displayName
            )
            let startedAt = Date()
            Task { [weak self] in
                for _ in 0..<20 {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let self else { return }
                    self.reloadProviderHealth()
                    if let date = self.providerHealth[provider]?.lastEventAt, date >= startedAt {
                        self.integrationTestStatus = String(
                            format: String(localized: "integration.test.delivered", defaultValue: "%@ hook is delivering events."),
                            provider.displayName
                        )
                        return
                    }
                }
                self?.integrationTestStatus = String(
                    format: String(localized: "integration.test.timeout", defaultValue: "%@ test event was not received. Reinstall the integration and try again."),
                    provider.displayName
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importHistory(provider: ItemSource? = nil) {
        guard !isImporting else { return }
        isImporting = true
        importStatus = String(localized: "Scanning local sessions…")
        let importer = historyImporter
        Task { [weak self, importer] in
            do {
                let summary = try await Task.detached(priority: .userInitiated) {
                    try importer.importAll(provider: provider)
                }.value
                self?.isImporting = false
                self?.importStatus = String(
                    format: String(
                        localized: "history.import.complete",
                        defaultValue: "Imported %lld of %lld responses from %lld files."
                    ),
                    summary.itemsImported,
                    summary.itemsFound,
                    summary.filesScanned
                )
                self?.reload()
            } catch {
                self?.isImporting = false
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    private func backfillAgentQuestionsIfNeeded() {
        let defaults = UserDefaults.standard
        let key = "didBackfillAgentQuestionsV3"
        guard !defaults.bool(forKey: key) else { return }
        let importer = historyImporter
        Task { [weak self] in
            do {
                let updated = try await Task.detached(priority: .utility) {
                    try importer.backfillExistingUserPrompts()
                }.value
                defaults.set(true, forKey: key)
                if updated > 0 { self?.reload() }
            } catch {
                self?.showPassiveStatus(error.localizedDescription)
            }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            objectWillChange.send()
        } catch {
            errorMessage = String(
                format: String(
                    localized: "login_item.error",
                    defaultValue: "Login item could not be updated. This feature requires the packaged DuckClip.app. %@"
                ),
                error.localizedDescription
            )
        }
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        guard enabled else {
            settings.notificationsEnabled = false
            return
        }
        guard !notificationRequestInFlight else { return }
        notificationRequestInFlight = true
        Task { [weak self] in
            guard let self else { return }
            defer { notificationRequestInFlight = false }
            let current = await notifications.authorizationStatus()
            let granted: Bool
            if current == .notDetermined {
                granted = await notifications.requestAuthorization()
            } else {
                granted = current == .authorized || current == .provisional
            }
            notificationAuthorizationStatus = await notifications.authorizationStatus()
            settings.notificationsEnabled = granted
            if !granted {
                showPassiveStatus(String(localized: "Notifications are blocked by macOS."))
            }
        }
    }

    func sendTestNotification(kind: AgentEventKind) {
        let event = AgentEvent(
            provider: .codex,
            kind: kind,
            sessionID: "duckclip-notification-test",
            agentID: nil,
            turnID: nil,
            transcriptPath: nil,
            eventID: UUID().uuidString,
            projectPath: nil,
            response: kind == .responseCompleted ? String(localized: "This is a DuckClip notification test.") : nil,
            title: notificationTitle(for: kind),
            message: notificationMessage(for: kind),
            receivedAt: Date()
        )
        notifications.post(
            event: event,
            itemID: nil,
            enabled: settings.notificationsEnabled,
            previewMode: settings.notificationPreviewMode
        )
        showPassiveStatus(String(localized: "Test notification sent"))
    }

    func refreshNotificationAuthorization() {
        Task { [weak self] in
            guard let self else { return }
            notificationAuthorizationStatus = await notifications.authorizationStatus()
            if notificationAuthorizationStatus != .authorized && notificationAuthorizationStatus != .provisional {
                settings.notificationsEnabled = false
            }
        }
    }

    func setAutoPaste(_ enabled: Bool) {
        settings.autoPaste = enabled
        if enabled {
            accessibilityTrusted = pasteCoordinator.requestAccessibilityPermission()
        }
    }

    func refreshAccessibilityPermission() {
        accessibilityTrusted = pasteCoordinator.isAccessibilityTrusted
    }

    func openAccessibilitySettings() {
        accessibilityPermissionRequired = false
        errorMessage = nil
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func openNotificationSettings() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.dksung.duckclip"
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)") {
            NSWorkspace.shared.open(url)
        }
    }

    func dismissError() {
        errorMessage = nil
        accessibilityPermissionRequired = false
    }

    func showPassiveStatus(_ message: String) {
        passiveStatusTask?.cancel()
        passiveStatusMessage = message
        passiveStatusTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.passiveStatusMessage = nil
        }
    }

    private func storeItem(_ item: ClipItem) {
        do {
            let inserted = try store.insert(item)
            if inserted {
                let hiddenByFilter = sourceFilter == .agents
                    || projectFilter != nil
                    || conversationFilter != nil
                    || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                paletteNotice = PaletteNotice(
                    message: hiddenByFilter
                        ? String(localized: "Captured a clipboard item, but it is hidden by the current filter.")
                        : captureDescription(for: item),
                    systemImage: item.kind == .image ? "photo.fill" : "checkmark.circle.fill",
                    action: hiddenByFilter ? .showAll : nil
                )
            } else {
                paletteNotice = PaletteNotice(
                    message: String(localized: "An identical recent item was moved to the top."),
                    systemImage: "arrow.up.circle",
                    action: nil
                )
            }
            reload()
        } catch {
            showPassiveStatus(error.localizedDescription)
        }
    }

    private func handleClipboardStatus(_ status: ClipboardCaptureStatus) {
        switch status {
        case .paused:
            paletteNotice = PaletteNotice(
                message: String(localized: "Clipboard recording is paused."),
                systemImage: "pause.circle.fill",
                action: .resumeCapture
            )
        case .protectedContent:
            paletteNotice = PaletteNotice(
                message: String(localized: "Protected or temporary clipboard content was not recorded."),
                systemImage: "hand.raised.fill",
                action: nil
            )
        case .excludedApplication(let bundleID):
            let name = bundleID.flatMap(applicationName) ?? String(localized: "an excluded application")
            paletteNotice = PaletteNotice(
                message: String(format: String(localized: "Clipboard content from %@ was not recorded."), name),
                systemImage: "eye.slash.fill",
                action: nil
            )
        case .unsupportedContent:
            paletteNotice = PaletteNotice(
                message: String(localized: "This clipboard format is not supported yet."),
                systemImage: "questionmark.square.dashed",
                action: nil
            )
        case .imageStorageFailed(let message):
            showPassiveStatus(String(format: String(localized: "The image could not be saved: %@"), message))
        }
    }

    private func handle(_ event: AgentEvent) {
        do {
            try store.recordAgentEvent(event)
            reloadProviderHealth()
        } catch {
            errorMessage = error.localizedDescription
        }
        guard !settings.isProjectExcluded(event.projectPath) else { return }
        var itemID: String?
        var isNewResponse = true
        if let item = event.clipItem {
            do {
                if try store.insert(item) {
                    itemID = item.id
                    reload()
                } else {
                    isNewResponse = false
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        let enabled: Bool
        switch event.kind {
        case .responseCompleted:
            enabled = settings.notificationsEnabled && settings.completionNotifications && isNewResponse
        case .inputRequired:
            enabled = settings.notificationsEnabled && settings.inputNotifications
        case .approvalRequired:
            enabled = settings.notificationsEnabled && settings.approvalNotifications
        case .failed:
            enabled = settings.notificationsEnabled && settings.failureNotifications
        case .sessionStarted, .ignored:
            enabled = false
        }
        if event.kind == .inputRequired || event.kind == .approvalRequired || event.kind == .failed {
            agentActivityNotice = AgentActivityNotice(
                provider: event.provider,
                kind: event.kind,
                title: event.title,
                message: event.message
            )
        }
        notifications.post(
            event: event,
            itemID: itemID,
            enabled: enabled,
            previewMode: settings.notificationPreviewMode
        )
    }

    private func reloadProviderHealth() {
        do {
            providerHealth = Dictionary(uniqueKeysWithValues: try store.providerHealth().map { ($0.provider, $0) })
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func copy(itemID: String) {
        guard let item = try? store.item(id: itemID) else { return }
        copy(item)
    }

    private func purgeExpiredItems() {
        finalizePendingDeletion()
        let cutoff = Calendar.current.date(byAdding: .day, value: -settings.retentionDays, to: Date()) ?? Date.distantPast
        if let paths = try? store.purge(olderThan: cutoff) {
            paths.forEach { blobStore.deleteIfPresent(path: $0) }
        }
        reload()
    }

    private func finalizePendingDeletion(expectedID: String? = nil) {
        guard let item = pendingDeletion, expectedID == nil || item.id == expectedID else { return }
        deletionTask?.cancel()
        deletionTask = nil
        pendingDeletion = nil
        recentlyDeletedTitle = nil
        do {
            let orphanedPaths = try store.delete(id: item.id)
            orphanedPaths.forEach { blobStore.deleteIfPresent(path: $0) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func captureDescription(for item: ClipItem) -> String {
        switch item.kind {
        case .image: String(localized: "Image captured")
        case .file: String(localized: "Files captured")
        case .url: String(localized: "Link captured")
        case .text, .agentResponse: String(localized: "Clipboard item captured")
        }
    }

    private func applicationName(_ bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
    }

    private func notificationTitle(for kind: AgentEventKind) -> String {
        switch kind {
        case .responseCompleted: String(localized: "Codex response ready")
        case .inputRequired: String(localized: "Codex is waiting for input")
        case .approvalRequired: String(localized: "Codex needs approval")
        case .failed: String(localized: "Codex stopped with an error")
        case .sessionStarted, .ignored: "DuckClip"
        }
    }

    private func notificationMessage(for kind: AgentEventKind) -> String {
        switch kind {
        case .responseCompleted: String(localized: "This is a DuckClip notification test.")
        case .inputRequired: String(localized: "The agent is waiting for your response.")
        case .approvalRequired: String(localized: "The agent needs permission to continue.")
        case .failed: String(localized: "Open the agent session for details.")
        case .sessionStarted, .ignored: String(localized: "Open DuckClip to view details.")
        }
    }
}
