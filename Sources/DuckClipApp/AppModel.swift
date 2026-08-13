import AppKit
import Combine
import DuckClipCore
import Foundation
import ServiceManagement
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    @Published var items: [ClipItem] = []
    @Published var sessions: [AgentSessionSummary] = []
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            reload(refreshSessions: false, debounce: true)
        }
    }
    @Published var sourceFilter: SourceFilter = .all {
        didSet {
            guard sourceFilter != oldValue else { return }
            projectFilter = nil
            conversationFilter = nil
            reload(refreshSessions: false)
        }
    }
    @Published var projectFilter: String? {
        didSet {
            guard projectFilter != oldValue else { return }
            conversationFilter = nil
            reload(refreshSessions: false)
        }
    }
    @Published var conversationFilter: String? {
        didSet {
            guard conversationFilter != oldValue else { return }
            reload(refreshSessions: false)
        }
    }
    @Published var selectedItemID: String?
    @Published var errorMessage: String?
    @Published var hookStatus = HookInstallationStatus.empty
    @Published var providerHealth: [ItemSource: ProviderHealth] = [:]
    @Published var integrationTestStatus = ""
    @Published var importStatus = ""
    @Published var isImporting = false
    @Published var shortcutRegistrationSucceeded = true
    @Published var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
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
    private let notifications = NotificationCoordinator()
    private var reloadTask: Task<Void, Never>?
    private var reloadGeneration = 0
    private var pendingDeletion: ClipItem?
    private var deletionTask: Task<Void, Never>?
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
        inboxMonitor.onEvent = { [weak self] event in self?.handle(event) }
        inboxMonitor.onError = { [weak self] error in self?.errorMessage = error.localizedDescription }
        notifications.onCopy = { [weak self] itemID in self?.copy(itemID: itemID) }
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
                    let items = try store.search(
                        query: query,
                        source: conversation?.provider,
                        sources: conversation == nil ? sourceFilter.itemSources : nil,
                        projectPath: projectFilter,
                        sessionID: conversation?.sessionID,
                        agentID: conversation?.agentID
                    )
                    return (sessions, items, conversationFilter != nil && conversation == nil)
                }.value
                guard let self, !Task.isCancelled, generation == self.reloadGeneration else { return }
                self.sessions = result.0
                if result.2 {
                    self.conversationFilter = nil
                    return
                }
                self.items = result.1
                if let selectedItemID, !result.1.contains(where: { $0.id == selectedItemID }) {
                    self.selectedItemID = result.1.first?.id
                } else if selectedItemID == nil {
                    self.selectedItemID = result.1.first?.id
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, generation == self.reloadGeneration else { return }
                self.errorMessage = error.localizedDescription
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
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(700))
                self?.reloadProviderHealth()
                if self?.providerHealth[provider]?.lastEventKind == .sessionStarted {
                    self?.integrationTestStatus = String(
                        format: String(localized: "integration.test.delivered", defaultValue: "%@ hook is delivering events."),
                        provider.displayName
                    )
                }
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
        Task { [weak self] in
            guard let self else { return }
            let current = await notifications.authorizationStatus()
            let granted: Bool
            if current == .notDetermined {
                granted = await notifications.requestAuthorization()
            } else {
                granted = current == .authorized || current == .provisional
            }
            notificationAuthorizationStatus = await notifications.authorizationStatus()
            settings.notificationsEnabled = granted
        }
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

    private func storeItem(_ item: ClipItem) {
        do {
            _ = try store.insert(item)
            reload()
        } catch {
            errorMessage = error.localizedDescription
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
        if let item = event.clipItem {
            do {
                if try store.insert(item) {
                    itemID = item.id
                    reload()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        let enabled: Bool
        switch event.kind {
        case .responseCompleted, .inputRequired:
            enabled = settings.notificationsEnabled && settings.completionNotifications
        case .approvalRequired, .failed:
            enabled = settings.notificationsEnabled && settings.approvalNotifications
        case .sessionStarted, .ignored:
            enabled = false
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
}
