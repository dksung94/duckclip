import Combine
import Foundation

public enum NotificationPreviewMode: String, CaseIterable, Identifiable, Sendable {
    case metadataOnly
    case firstLine
    case hidden

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .metadataOnly: String(localized: "Status only")
        case .firstLine: String(localized: "Response preview")
        case .hidden: String(localized: "Hidden")
        }
    }
}

public enum GlobalShortcut: String, CaseIterable, Identifiable, Sendable {
    case commandShiftV
    case commandOptionV
    case controlOptionV

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .commandShiftV: "⇧⌘V"
        case .commandOptionV: "⌥⌘V"
        case .controlOptionV: "⌃⌥V"
        }
    }
}

@MainActor
public final class DuckClipSettings: ObservableObject {
    private enum Key {
        static let captureEnabled = "captureEnabled"
        static let autoPaste = "autoPaste"
        static let retentionDays = "retentionDays"
        static let notificationsEnabled = "notificationsEnabled"
        static let completionNotifications = "completionNotifications"
        static let inputNotifications = "inputNotifications"
        static let approvalNotifications = "approvalNotifications"
        static let failureNotifications = "failureNotifications"
        static let notificationPreviewMode = "notificationPreviewMode"
        static let excludedApps = "excludedApps"
        static let excludedProjects = "excludedProjects"
        static let globalShortcut = "globalShortcut"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
    }

    private let defaults: UserDefaults

    @Published public var captureEnabled: Bool { didSet { save() } }
    @Published public var autoPaste: Bool { didSet { save() } }
    @Published public var retentionDays: Int { didSet { save() } }
    @Published public var notificationsEnabled: Bool { didSet { save() } }
    @Published public var completionNotifications: Bool { didSet { save() } }
    @Published public var inputNotifications: Bool { didSet { save() } }
    @Published public var approvalNotifications: Bool { didSet { save() } }
    @Published public var failureNotifications: Bool { didSet { save() } }
    @Published public var notificationPreviewMode: NotificationPreviewMode { didSet { save() } }
    @Published public var excludedAppsText: String { didSet { save() } }
    @Published public var excludedProjectsText: String { didSet { save() } }
    @Published public var globalShortcut: GlobalShortcut { didSet { save() } }
    @Published public var hasCompletedOnboarding: Bool { didSet { save() } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.captureEnabled: true,
            Key.autoPaste: false,
            Key.retentionDays: 30,
            Key.notificationsEnabled: false,
            Key.completionNotifications: true,
            Key.inputNotifications: true,
            Key.approvalNotifications: true,
            Key.failureNotifications: true,
            Key.notificationPreviewMode: NotificationPreviewMode.metadataOnly.rawValue,
            Key.excludedApps: [
                "com.1password.1password",
                "com.agilebits.onepassword7",
                "com.bitwarden.desktop",
                "com.apple.keychainaccess"
            ].joined(separator: "\n"),
            Key.excludedProjects: "",
            Key.globalShortcut: GlobalShortcut.commandShiftV.rawValue,
            Key.hasCompletedOnboarding: false
        ])
        captureEnabled = defaults.bool(forKey: Key.captureEnabled)
        autoPaste = defaults.bool(forKey: Key.autoPaste)
        retentionDays = max(1, defaults.integer(forKey: Key.retentionDays))
        notificationsEnabled = defaults.bool(forKey: Key.notificationsEnabled)
        completionNotifications = defaults.bool(forKey: Key.completionNotifications)
        inputNotifications = defaults.bool(forKey: Key.inputNotifications)
        approvalNotifications = defaults.bool(forKey: Key.approvalNotifications)
        failureNotifications = defaults.bool(forKey: Key.failureNotifications)
        notificationPreviewMode = NotificationPreviewMode(
            rawValue: defaults.string(forKey: Key.notificationPreviewMode) ?? ""
        ) ?? .metadataOnly
        excludedAppsText = defaults.string(forKey: Key.excludedApps) ?? ""
        excludedProjectsText = defaults.string(forKey: Key.excludedProjects) ?? ""
        globalShortcut = GlobalShortcut(rawValue: defaults.string(forKey: Key.globalShortcut) ?? "") ?? .commandShiftV
        hasCompletedOnboarding = defaults.bool(forKey: Key.hasCompletedOnboarding)
    }

    public var excludedAppBundleIDs: Set<String> {
        Set(Self.lines(excludedAppsText))
    }

    public var excludedProjectPaths: [String] {
        Self.lines(excludedProjectsText).map { NSString(string: $0).expandingTildeInPath }
    }

    public func isProjectExcluded(_ path: String?) -> Bool {
        guard let path else { return false }
        return excludedProjectPaths.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private func save() {
        defaults.set(captureEnabled, forKey: Key.captureEnabled)
        defaults.set(autoPaste, forKey: Key.autoPaste)
        defaults.set(retentionDays, forKey: Key.retentionDays)
        defaults.set(notificationsEnabled, forKey: Key.notificationsEnabled)
        defaults.set(completionNotifications, forKey: Key.completionNotifications)
        defaults.set(inputNotifications, forKey: Key.inputNotifications)
        defaults.set(approvalNotifications, forKey: Key.approvalNotifications)
        defaults.set(failureNotifications, forKey: Key.failureNotifications)
        defaults.set(notificationPreviewMode.rawValue, forKey: Key.notificationPreviewMode)
        defaults.set(excludedAppsText, forKey: Key.excludedApps)
        defaults.set(excludedProjectsText, forKey: Key.excludedProjects)
        defaults.set(globalShortcut.rawValue, forKey: Key.globalShortcut)
        defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding)
    }

    private static func lines(_ text: String) -> [String] {
        text
            .components(separatedBy: .newlines)
            .flatMap { $0.split(separator: ",").map(String.init) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
