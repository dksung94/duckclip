import Foundation

public struct ProviderHookStatus: Identifiable, Sendable {
    public var id: String { provider.rawValue }
    public let provider: ItemSource
    public let expectedEvents: [String]
    public let installedEvents: [String]
    public let helperExecutable: Bool

    public var missingEvents: [String] {
        expectedEvents.filter { !installedEvents.contains($0) }
    }

    public var installed: Bool {
        helperExecutable && missingEvents.isEmpty
    }
}

public struct HookInstallationStatus: Sendable {
    public let claude: ProviderHookStatus
    public let codex: ProviderHookStatus
    public let managedHelperPath: String

    public var claudeInstalled: Bool { claude.installed }
    public var codexInstalled: Bool { codex.installed }

    public static let empty = HookInstallationStatus(
        claude: ProviderHookStatus(
            provider: .claude,
            expectedEvents: ["Stop", "PermissionRequest", "Notification", "StopFailure"],
            installedEvents: [],
            helperExecutable: false
        ),
        codex: ProviderHookStatus(
            provider: .codex,
            expectedEvents: ["Stop", "PermissionRequest", "PreToolUse"],
            installedEvents: [],
            helperExecutable: false
        ),
        managedHelperPath: ""
    )

    public func provider(_ source: ItemSource) -> ProviderHookStatus? {
        switch source {
        case .claude: claude
        case .codex: codex
        case .clipboard: nil
        }
    }
}

public final class HookInstaller: @unchecked Sendable {
    public enum InstallerError: LocalizedError {
        case helperNotFound(URL)
        case invalidConfiguration(URL)
        case unsupportedProvider
        case smokeTestFailed(Int32)

        public var errorDescription: String? {
            switch self {
            case .helperNotFound(let url):
                String(
                    format: String(localized: "hook.error.helper_missing", defaultValue: "duckclip-hook is not executable at %@. Build or install the app bundle first."),
                    url.path
                )
            case .invalidConfiguration(let url):
                String(
                    format: String(localized: "hook.error.invalid_configuration", defaultValue: "The hook configuration at %@ is not a JSON object."),
                    url.path
                )
            case .unsupportedProvider:
                String(localized: "hook.error.unsupported_provider", defaultValue: "Hook tests are supported only for Claude and Codex.")
            case .smokeTestFailed(let status):
                String(
                    format: String(localized: "hook.error.test_failed", defaultValue: "The DuckClip hook test exited with status %d."),
                    status
                )
            }
        }
    }

    private let home: URL
    private let sourceHelperURL: URL
    public let installedHelperURL: URL
    private let fileManager: FileManager

    private static let claudeSpecs = [
        HookSpec(eventName: "Stop", argument: "stop"),
        HookSpec(eventName: "PermissionRequest", argument: "permission-request"),
        HookSpec(
            eventName: "Notification",
            argument: "notification",
            matcher: "idle_prompt|agent_needs_input|agent_completed"
        ),
        HookSpec(eventName: "StopFailure", argument: "stop-failure")
    ]
    private static let codexSpecs = [
        HookSpec(eventName: "Stop", argument: "stop"),
        HookSpec(eventName: "PermissionRequest", argument: "permission-request"),
        HookSpec(
            eventName: "PreToolUse",
            argument: "input-request",
            matcher: "request_user_input|functions.request_user_input"
        )
    ]

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        helperURL: URL? = nil,
        managedHelperURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.home = home
        self.fileManager = fileManager
        sourceHelperURL = helperURL ?? Self.defaultHelperURL()
        installedHelperURL = managedHelperURL
            ?? home.appendingPathComponent("Library/Application Support/DuckClip/bin/duckclip-hook")
    }

    public func status() -> HookInstallationStatus {
        let executable = fileManager.isExecutableFile(atPath: installedHelperURL.path)
        return HookInstallationStatus(
            claude: providerStatus(
                .claude,
                specs: Self.claudeSpecs,
                at: claudeConfigURL,
                helperExecutable: executable
            ),
            codex: providerStatus(
                .codex,
                specs: Self.codexSpecs,
                at: codexConfigURL,
                helperExecutable: executable
            ),
            managedHelperPath: installedHelperURL.path
        )
    }

    public func install() throws {
        try installManagedHelper()
        try mergeHooks(Self.claudeSpecs, provider: "claude", at: claudeConfigURL)
        try mergeHooks(Self.codexSpecs, provider: "codex", at: codexConfigURL)
    }

    public func uninstall() throws {
        try removeDuckClipHooks(at: claudeConfigURL)
        try removeDuckClipHooks(at: codexConfigURL)
        if fileManager.fileExists(atPath: installedHelperURL.path) {
            try fileManager.removeItem(at: installedHelperURL)
        }
    }

    public func runSmokeTest(provider: ItemSource) throws {
        guard provider == .claude || provider == .codex else {
            throw InstallerError.unsupportedProvider
        }
        guard fileManager.isExecutableFile(atPath: installedHelperURL.path) else {
            throw InstallerError.helperNotFound(installedHelperURL)
        }

        let process = Process()
        let input = Pipe()
        process.executableURL = installedHelperURL
        process.arguments = [
            "capture", "--managed-by", "duckclip", "--schema", "1",
            "--provider", provider.rawValue, "--event", "session-start"
        ]
        process.standardInput = input
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        let payload: [String: Any] = [
            "hook_event_name": "SessionStart",
            "session_id": "duckclip-hook-test-\(UUID().uuidString)",
            "cwd": FileManager.default.currentDirectoryPath
        ]
        input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: payload))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw InstallerError.smokeTestFailed(process.terminationStatus)
        }
    }

    private var claudeConfigURL: URL {
        home.appendingPathComponent(".claude/settings.json")
    }

    private var codexConfigURL: URL {
        home.appendingPathComponent(".codex/hooks.json")
    }

    private struct HookSpec {
        let eventName: String
        let argument: String
        var matcher = ""
    }

    private func installManagedHelper() throws {
        guard fileManager.isExecutableFile(atPath: sourceHelperURL.path) else {
            throw InstallerError.helperNotFound(sourceHelperURL)
        }
        guard sourceHelperURL.standardizedFileURL != installedHelperURL.standardizedFileURL else { return }

        let directory = installedHelperURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let data = try Data(contentsOf: sourceHelperURL)
        try data.write(to: installedHelperURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedHelperURL.path)
    }

    private func mergeHooks(_ specs: [HookSpec], provider: String, at url: URL) throws {
        var root = try loadObject(at: url)
        var hooks = removingDuckClipHandlers(from: root["hooks"] as? [String: Any] ?? [:])
        for spec in specs {
            var groups = hooks[spec.eventName] as? [[String: Any]] ?? []
            groups.append([
                "matcher": spec.matcher,
                "hooks": [[
                    "type": "command",
                    "command": command(provider: provider, event: spec.argument),
                    "timeout": 5
                ]]
            ])
            hooks[spec.eventName] = groups
        }
        root["hooks"] = hooks
        try write(root, to: url)
    }

    private func removeDuckClipHooks(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        var root = try loadObject(at: url)
        guard let hooks = root["hooks"] as? [String: Any] else { return }
        root["hooks"] = removingDuckClipHandlers(from: hooks)
        try write(root, to: url)
    }

    private func removingDuckClipHandlers(from hooks: [String: Any]) -> [String: Any] {
        var hooks = hooks
        for key in Array(hooks.keys) {
            guard let groups = hooks[key] as? [[String: Any]] else { continue }
            let filteredGroups: [[String: Any]] = groups.compactMap { group in
                var mutable = group
                let handlers = group["hooks"] as? [[String: Any]] ?? []
                let filtered = handlers.filter {
                    guard let command = $0["command"] as? String else { return true }
                    return !isDuckClipCommand(command)
                }
                guard !filtered.isEmpty else { return nil }
                mutable["hooks"] = filtered
                return mutable
            }
            if filteredGroups.isEmpty {
                hooks.removeValue(forKey: key)
            } else {
                hooks[key] = filteredGroups
            }
        }
        return hooks
    }

    private func providerStatus(
        _ provider: ItemSource,
        specs: [HookSpec],
        at url: URL,
        helperExecutable: Bool
    ) -> ProviderHookStatus {
        let hooks = loadHooksIfPresent(at: url)
        let installedEvents = specs.compactMap { spec -> String? in
            let groups = hooks[spec.eventName] as? [[String: Any]] ?? []
            let expected = command(provider: provider.rawValue, event: spec.argument)
            let found = groups.contains { group in
                let handlers = group["hooks"] as? [[String: Any]] ?? []
                return handlers.contains { ($0["command"] as? String) == expected }
            }
            return found ? spec.eventName : nil
        }
        return ProviderHookStatus(
            provider: provider,
            expectedEvents: specs.map(\.eventName),
            installedEvents: installedEvents,
            helperExecutable: helperExecutable
        )
    }

    private func command(provider: String, event: String) -> String {
        "\(Self.shellQuote(installedHelperURL.path)) capture --managed-by duckclip --schema 1 --provider \(provider) --event \(event)"
    }

    private func isDuckClipCommand(_ command: String) -> Bool {
        if command.contains(" capture "), command.contains("--managed-by duckclip") {
            return command.contains("duckclip-hook")
        }
        let legacy = #"(^|[/\s'\"])duckclip-hook['\"]?\s+(claude|codex)\s+(stop|permission-request|notification|stop-failure)(\s|$)"#
        return command.range(of: legacy, options: .regularExpression) != nil
    }

    private func loadHooksIfPresent(at url: URL) -> [String: Any] {
        guard
            let data = try? Data(contentsOf: url),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return root["hooks"] as? [String: Any] ?? [:]
    }

    private func loadObject(at url: URL) throws -> [String: Any] {
        guard fileManager.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallerError.invalidConfiguration(url)
        }
        return object
    }

    private func write(_ object: [String: Any], to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: url, options: .atomic)
    }

    private static func defaultHelperURL() -> URL {
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return executable.deletingLastPathComponent().appendingPathComponent("duckclip-hook")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
