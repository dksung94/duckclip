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
    public let providers: [ProviderHookStatus]
    public let managedHelperPath: String

    public static var empty: HookInstallationStatus {
        HookInstallationStatus(
            providers: ItemSource.agentSources.map {
                ProviderHookStatus(
                    provider: $0,
                    expectedEvents: HookInstaller.expectedEvents(for: $0),
                    installedEvents: [],
                    helperExecutable: false
                )
            },
            managedHelperPath: ""
        )
    }

    public func provider(_ source: ItemSource) -> ProviderHookStatus? {
        providers.first { $0.provider == source }
    }

    // Kept as conveniences for callers compiled against the first two integrations.
    public var claude: ProviderHookStatus { provider(.claude)! }
    public var codex: ProviderHookStatus { provider(.codex)! }
    public var claudeInstalled: Bool { claude.installed }
    public var codexInstalled: Bool { codex.installed }
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
                    format: String(localized: "hook.error.invalid_configuration", defaultValue: "The integration configuration at %@ is not a JSON object."),
                    url.path
                )
            case .unsupportedProvider:
                String(localized: "hook.error.unsupported_provider", defaultValue: "This provider does not support DuckClip integration tests.")
            case .smokeTestFailed(let status):
                String(
                    format: String(localized: "hook.error.test_failed", defaultValue: "The DuckClip hook test exited with status %d."),
                    status
                )
            }
        }
    }

    private struct HookSpec {
        let eventName: String
        let argument: String
        var matcher = ""
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
    private static let geminiSpecs = [
        HookSpec(eventName: "AfterAgent", argument: "after-agent"),
        HookSpec(eventName: "Notification", argument: "notification")
    ]
    private static let cursorSpecs = [
        HookSpec(eventName: "afterAgentResponse", argument: "after-agent-response"),
        HookSpec(eventName: "stop", argument: "stop"),
        HookSpec(eventName: "sessionStart", argument: "session-start")
    ]
    private static let copilotSpecs = [
        HookSpec(eventName: "agentStop", argument: "agent-stop"),
        HookSpec(eventName: "permissionRequest", argument: "permission-request"),
        HookSpec(eventName: "notification", argument: "notification"),
        HookSpec(eventName: "errorOccurred", argument: "error-occurred"),
        HookSpec(eventName: "sessionStart", argument: "session-start")
    ]
    private static let gajaeEvents = ["agent_end", "tool_call", "session_start"]
    private static let openCodeEvents = ["session.idle", "permission.asked", "session.error"]

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

    public static func expectedEvents(for provider: ItemSource) -> [String] {
        switch provider {
        case .clipboard: []
        case .claude: claudeSpecs.map(\.eventName)
        case .codex: codexSpecs.map(\.eventName)
        case .gajae: gajaeEvents
        case .gemini: geminiSpecs.map(\.eventName)
        case .copilot: copilotSpecs.map(\.eventName)
        case .cursor: cursorSpecs.map(\.eventName)
        case .opencode: openCodeEvents
        }
    }

    public func status() -> HookInstallationStatus {
        let executable = fileManager.isExecutableFile(atPath: installedHelperURL.path)
        let providers = ItemSource.agentSources.map { provider -> ProviderHookStatus in
            switch provider {
            case .claude:
                groupedStatus(provider, specs: Self.claudeSpecs, at: claudeConfigURL, helperExecutable: executable)
            case .codex:
                groupedStatus(provider, specs: Self.codexSpecs, at: codexConfigURL, helperExecutable: executable)
            case .gemini:
                groupedStatus(provider, specs: Self.geminiSpecs, at: geminiConfigURL, helperExecutable: executable)
            case .cursor:
                simpleStatus(provider, specs: Self.cursorSpecs, at: cursorConfigURL, commandKey: "command", helperExecutable: executable)
            case .copilot:
                simpleStatus(provider, specs: Self.copilotSpecs, at: copilotConfigURL, commandKey: "bash", helperExecutable: executable)
            case .gajae:
                managedFileStatus(provider, events: Self.gajaeEvents, at: gajaeExtensionURL, helperExecutable: executable)
            case .opencode:
                managedFileStatus(provider, events: Self.openCodeEvents, at: openCodePluginURL, helperExecutable: executable)
            case .clipboard:
                ProviderHookStatus(provider: .clipboard, expectedEvents: [], installedEvents: [], helperExecutable: executable)
            }
        }
        return HookInstallationStatus(providers: providers, managedHelperPath: installedHelperURL.path)
    }

    public func install() throws {
        try installManagedHelper()
        try mergeGroupedHooks(Self.claudeSpecs, provider: .claude, at: claudeConfigURL, timeout: 5)
        try mergeGroupedHooks(Self.codexSpecs, provider: .codex, at: codexConfigURL, timeout: 5)
        try mergeGroupedHooks(Self.geminiSpecs, provider: .gemini, at: geminiConfigURL, timeout: 5_000)
        try mergeSimpleHooks(Self.cursorSpecs, provider: .cursor, at: cursorConfigURL, commandKey: "command", timeoutKey: "timeout")
        try writeCopilotHooks()
        try writeManagedText(gajaeExtension, to: gajaeExtensionURL)
        try writeManagedText(openCodePlugin, to: openCodePluginURL)
    }

    public func uninstall() throws {
        try removeGroupedHooks(at: claudeConfigURL)
        try removeGroupedHooks(at: codexConfigURL)
        try removeGroupedHooks(at: geminiConfigURL)
        try removeSimpleHooks(at: cursorConfigURL, commandKey: "command")
        try removeIfPresent(copilotConfigURL)
        try removeIfPresent(gajaeExtensionURL)
        try removeIfPresent(openCodePluginURL)
        if fileManager.fileExists(atPath: installedHelperURL.path) {
            try fileManager.removeItem(at: installedHelperURL)
        }
    }

    public func runSmokeTest(provider: ItemSource) throws {
        guard provider.isAgent else { throw InstallerError.unsupportedProvider }
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

    private var claudeConfigURL: URL { home.appendingPathComponent(".claude/settings.json") }
    private var codexConfigURL: URL { home.appendingPathComponent(".codex/hooks.json") }
    private var geminiConfigURL: URL { home.appendingPathComponent(".gemini/settings.json") }
    private var cursorConfigURL: URL { home.appendingPathComponent(".cursor/hooks.json") }
    private var copilotConfigURL: URL { home.appendingPathComponent(".copilot/hooks/duckclip.json") }
    private var gajaeExtensionURL: URL { home.appendingPathComponent(".gjc/agent/extensions/duckclip/index.ts") }
    private var openCodePluginURL: URL { home.appendingPathComponent(".config/opencode/plugins/duckclip.js") }

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

    private func mergeGroupedHooks(
        _ specs: [HookSpec],
        provider: ItemSource,
        at url: URL,
        timeout: Int
    ) throws {
        var root = try loadObject(at: url)
        var hooks = removingDuckClipGroupedHandlers(from: root["hooks"] as? [String: Any] ?? [:])
        for spec in specs {
            var groups = hooks[spec.eventName] as? [[String: Any]] ?? []
            groups.append([
                "matcher": spec.matcher,
                "hooks": [[
                    "type": "command",
                    "command": command(provider: provider, event: spec.argument),
                    "timeout": timeout
                ]]
            ])
            hooks[spec.eventName] = groups
        }
        root["hooks"] = hooks
        try write(root, to: url)
    }

    private func mergeSimpleHooks(
        _ specs: [HookSpec],
        provider: ItemSource,
        at url: URL,
        commandKey: String,
        timeoutKey: String
    ) throws {
        var root = try loadObject(at: url)
        root["version"] = root["version"] ?? 1
        var hooks = removingDuckClipSimpleHandlers(
            from: root["hooks"] as? [String: Any] ?? [:],
            commandKey: commandKey
        )
        for spec in specs {
            var handlers = hooks[spec.eventName] as? [[String: Any]] ?? []
            handlers.append([
                commandKey: command(provider: provider, event: spec.argument),
                timeoutKey: 5
            ])
            hooks[spec.eventName] = handlers
        }
        root["hooks"] = hooks
        try write(root, to: url)
    }

    private func writeCopilotHooks() throws {
        var hooks: [String: Any] = [:]
        for spec in Self.copilotSpecs {
            hooks[spec.eventName] = [[
                "type": "command",
                "bash": command(provider: .copilot, event: spec.argument),
                "timeoutSec": 5
            ]]
        }
        try write(["version": 1, "hooks": hooks], to: copilotConfigURL)
    }

    private func removeGroupedHooks(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        var root = try loadObject(at: url)
        guard let hooks = root["hooks"] as? [String: Any] else { return }
        root["hooks"] = removingDuckClipGroupedHandlers(from: hooks)
        try write(root, to: url)
    }

    private func removeSimpleHooks(at url: URL, commandKey: String) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        var root = try loadObject(at: url)
        guard let hooks = root["hooks"] as? [String: Any] else { return }
        root["hooks"] = removingDuckClipSimpleHandlers(from: hooks, commandKey: commandKey)
        try write(root, to: url)
    }

    private func removingDuckClipGroupedHandlers(from hooks: [String: Any]) -> [String: Any] {
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
            if filteredGroups.isEmpty { hooks.removeValue(forKey: key) }
            else { hooks[key] = filteredGroups }
        }
        return hooks
    }

    private func removingDuckClipSimpleHandlers(from hooks: [String: Any], commandKey: String) -> [String: Any] {
        var hooks = hooks
        for key in Array(hooks.keys) {
            guard let handlers = hooks[key] as? [[String: Any]] else { continue }
            let filtered = handlers.filter {
                guard let command = $0[commandKey] as? String else { return true }
                return !isDuckClipCommand(command)
            }
            if filtered.isEmpty { hooks.removeValue(forKey: key) }
            else { hooks[key] = filtered }
        }
        return hooks
    }

    private func groupedStatus(
        _ provider: ItemSource,
        specs: [HookSpec],
        at url: URL,
        helperExecutable: Bool
    ) -> ProviderHookStatus {
        let hooks = loadHooksIfPresent(at: url)
        let installedEvents = specs.compactMap { spec -> String? in
            let groups = hooks[spec.eventName] as? [[String: Any]] ?? []
            let expected = command(provider: provider, event: spec.argument)
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

    private func simpleStatus(
        _ provider: ItemSource,
        specs: [HookSpec],
        at url: URL,
        commandKey: String,
        helperExecutable: Bool
    ) -> ProviderHookStatus {
        let hooks = loadHooksIfPresent(at: url)
        let installedEvents = specs.compactMap { spec -> String? in
            let handlers = hooks[spec.eventName] as? [[String: Any]] ?? []
            let expected = command(provider: provider, event: spec.argument)
            return handlers.contains { ($0[commandKey] as? String) == expected } ? spec.eventName : nil
        }
        return ProviderHookStatus(
            provider: provider,
            expectedEvents: specs.map(\.eventName),
            installedEvents: installedEvents,
            helperExecutable: helperExecutable
        )
    }

    private func managedFileStatus(
        _ provider: ItemSource,
        events: [String],
        at url: URL,
        helperExecutable: Bool
    ) -> ProviderHookStatus {
        let text = try? String(contentsOf: url, encoding: .utf8)
        let installed = text?.contains("Managed by DuckClip") == true
            && text?.contains(installedHelperURL.path) == true
        return ProviderHookStatus(
            provider: provider,
            expectedEvents: events,
            installedEvents: installed ? events : [],
            helperExecutable: helperExecutable
        )
    }

    private func command(provider: ItemSource, event: String) -> String {
        "\(Self.shellQuote(installedHelperURL.path)) capture --managed-by duckclip --schema 1 --provider \(provider.rawValue) --event \(event)"
    }

    private func isDuckClipCommand(_ command: String) -> Bool {
        if command.contains(" capture "), command.contains("--managed-by duckclip") {
            return command.contains("duckclip-hook")
        }
        let providers = ItemSource.agentSources.map(\.rawValue).joined(separator: "|")
        let legacy = "(^|[/\\s'\\\"])duckclip-hook['\\\"]?\\s+(\(providers))\\s+[^\\s]+(\\s|$)"
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

    private func writeManagedText(_ text: String, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func removeIfPresent(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }

    private var gajaeExtension: String {
        let helper = Self.javaScriptString(installedHelperURL.path)
        return #"""
        // Managed by DuckClip. Reinstall from DuckClip Settings to update this file.
        const DUCKCLIP_HELPER = \#(helper);

        async function sendToDuckClip(event, payload) {
          try {
            const child = Bun.spawn([
              DUCKCLIP_HELPER, "capture", "--managed-by", "duckclip", "--schema", "1",
              "--provider", "gajae", "--event", event
            ], { stdin: "pipe", stdout: "ignore", stderr: "ignore" });
            child.stdin.write(JSON.stringify(payload));
            child.stdin.end();
            await child.exited;
          } catch (_) {}
        }

        function assistantText(messages) {
          const message = [...messages].reverse().find((item) => item && item.role === "assistant");
          if (!message) return "";
          if (typeof message.content === "string") return message.content;
          if (!Array.isArray(message.content)) return "";
          return message.content
            .filter((part) => part && part.type === "text" && typeof part.text === "string")
            .map((part) => part.text)
            .join("\n\n");
        }

        export default function duckClipExtension(pi) {
          pi.on("session_start", async (_event, ctx) => {
            await sendToDuckClip("session-start", {
              hook_event_name: "session-start",
              session_id: ctx.sessionManager.getSessionId(),
              transcript_path: ctx.sessionManager.getSessionFile(),
              cwd: ctx.cwd
            });
          });

          pi.on("agent_end", async (event, ctx) => {
            if (event.stopReason === "maintenance") return;
            await sendToDuckClip("response-completed", {
              hook_event_name: "response-completed",
              session_id: ctx.sessionManager.getSessionId(),
              turn_id: ctx.getActivePromptHandle?.(),
              transcript_path: ctx.sessionManager.getSessionFile(),
              cwd: ctx.cwd,
              response: assistantText(event.messages),
              model: ctx.model?.id,
              model_provider: ctx.model?.provider
            });
          });

          pi.on("tool_call", async (event, ctx) => {
            const name = String(event.toolName || "").toLowerCase();
            if (!name.includes("ask") && !name.includes("request_user_input")) return;
            await sendToDuckClip("input-required", {
              hook_event_name: "input-required",
              session_id: ctx.sessionManager.getSessionId(),
              cwd: ctx.cwd,
              tool_name: event.toolName,
              tool_input: event.input
            });
          });
        }
        """#
    }

    private var openCodePlugin: String {
        let helper = Self.javaScriptString(installedHelperURL.path)
        return #"""
        // Managed by DuckClip. Reinstall from DuckClip Settings to update this file.
        const DUCKCLIP_HELPER = \#(helper)

        async function sendToDuckClip(event, payload) {
          try {
            const child = Bun.spawn([
              DUCKCLIP_HELPER, "capture", "--managed-by", "duckclip", "--schema", "1",
              "--provider", "opencode", "--event", event
            ], { stdin: "pipe", stdout: "ignore", stderr: "ignore" })
            child.stdin.write(JSON.stringify(payload))
            child.stdin.end()
            await child.exited
          } catch (_) {}
        }

        function sessionID(event) {
          const value = event?.properties || {}
          return value.sessionID || value.sessionId || value.info?.sessionID || value.info?.sessionId || value.id
        }

        function lastAssistant(messages) {
          const list = Array.isArray(messages) ? messages : []
          const entry = [...list].reverse().find((item) => item?.info?.role === "assistant")
          if (!entry) return null
          const text = (entry.parts || [])
            .filter((part) => part?.type === "text" && typeof part.text === "string")
            .map((part) => part.text)
            .join("\n\n")
          return { text, id: entry.info?.id, agent: entry.info?.agent }
        }

        export const DuckClip = async ({ client, directory }) => ({
          event: async ({ event }) => {
            const id = sessionID(event)
            if (event.type === "session.idle" && id) {
              try {
                const result = await client.session.messages({ path: { id } })
                const response = lastAssistant(result?.data || result)
                await sendToDuckClip("response-completed", {
                  hook_event_name: "response-completed",
                  session_id: id,
                  turn_id: response?.id,
                  agent_id: response?.agent,
                  cwd: directory,
                  response: response?.text || ""
                })
              } catch (_) {
                await sendToDuckClip("response-completed", {
                  hook_event_name: "response-completed",
                  session_id: id,
                  cwd: directory
                })
              }
            } else if (event.type === "permission.asked") {
              await sendToDuckClip("permission-request", {
                hook_event_name: "permission-request",
                session_id: id,
                cwd: directory,
                message: event?.properties?.permission || event?.properties?.title
              })
            } else if (event.type === "session.error") {
              await sendToDuckClip("error-occurred", {
                hook_event_name: "error-occurred",
                session_id: id,
                cwd: directory,
                error: event?.properties?.error?.message || String(event?.properties?.error || "")
              })
            }
          }
        })
        """#
    }

    private static func defaultHelperURL() -> URL {
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return executable.deletingLastPathComponent().appendingPathComponent("duckclip-hook")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func javaScriptString(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes])
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }
}
