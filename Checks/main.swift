import DuckClipCore
import Foundation

enum CheckFailure: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): message
        }
    }
}

@discardableResult
func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws -> Bool {
    guard try condition() else { throw CheckFailure.failed(message) }
    return true
}

func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DuckClipChecks-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try body(directory)
}

func validateBunModule(at url: URL, output: URL) throws {
    guard let bun = ProcessInfo.processInfo.environment["PATH"]?
        .split(separator: ":")
        .map({ URL(fileURLWithPath: String($0)).appendingPathComponent("bun") })
        .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
    else { return }
    let process = Process()
    process.executableURL = bun
    process.arguments = ["build", url.path, "--target=bun", "--outfile=\(output.path)"]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    try require(process.terminationStatus == 0, "Generated module is not valid: \(url.path)")
}

func checkStore() throws {
    try withTemporaryDirectory { directory in
        let store = try SQLiteStore(url: directory.appendingPathComponent("test.sqlite3"))
        let clipboard = ClipItem(
            kind: .text,
            source: .clipboard,
            text: "A yellow duck remembers this clipboard",
            contentHash: ContentHasher.sha256("A yellow duck remembers this clipboard")
        )
        let agent = ClipItem(
            kind: .agentResponse,
            source: .codex,
            text: "The race condition is inside BalanceLocker",
            contentHash: ContentHasher.sha256("The race condition is inside BalanceLocker"),
            sessionID: "session-1",
            agentID: "agent-9",
            agentTurnID: "turn-1",
            eventID: "event-1",
            projectPath: "/tmp/platform-api"
        )

        try require(store.insert(clipboard), "Clipboard insert failed")
        try require(store.insert(agent), "Agent insert failed")
        try require(try store.search(query: "BalanceLocker").map(\.id) == [agent.id], "FTS search failed")
        try require(try store.search(source: .clipboard).map(\.id) == [clipboard.id], "Source filter failed")
        try require(try store.search(sources: ItemSource.agentSources).map(\.id) == [agent.id], "Agent source filter failed")
        try require(try store.search(agentID: "agent-9").map(\.id) == [agent.id], "Agent ID filter failed")
        let markdownAgent = ClipItem(
            kind: .agentResponse,
            source: .codex,
            text: "### Finished\n\nDetails",
            contentHash: "markdown-title"
        )
        try require(markdownAgent.title == "Finished", "Markdown heading marker leaked into the item title")
        try require(try store.count() == 2, "All item count failed")
        try require(try store.count(sources: [.clipboard]) == 1, "Clipboard item count failed")
        try require(!store.insert(agent), "Agent turn insertion was not idempotent")
        try require(try store.sessions().first?.agentID == "agent-9", "Agent grouping failed")
        try store.setPinned(id: clipboard.id, pinned: true)
        try require(try store.search().first?.id == clipboard.id, "Pinned ordering failed")
        try store.softDelete(id: clipboard.id)
        try require(try store.search().map(\.id) == [agent.id], "Soft delete failed")
        try store.restore(id: clipboard.id)
        try require(try store.search().first?.id == clipboard.id, "Delete undo failed")
        try store.softDelete(id: clipboard.id)
        _ = try store.deleteSoftDeleted()
        try require(try store.item(id: clipboard.id) == nil, "Deleted item cleanup failed")
    }
}

func checkAgentEvents() throws {
    let data = try JSONSerialization.data(withJSONObject: [
        "provider": "codex",
        "event": "stop",
        "received_at": "2026-08-13T05:00:00Z",
        "payload": [
            "hook_event_name": "Stop",
            "session_id": "session-codex",
            "agent_id": "agent-codex",
            "turn_id": "turn-7",
            "transcript_path": "/tmp/transcript.jsonl",
            "cwd": "/tmp/repo",
            "last_assistant_message": "Implemented and tested."
        ]
    ])
    let event = try AgentEventParser.parse(envelope: data)
    try require(event.provider == .codex, "Codex provider parsing failed")
    try require(event.kind == .responseCompleted, "Stop event parsing failed")
    try require(event.clipItem?.agentTurnID == "turn-7", "Turn ID parsing failed")
    try require(event.clipItem?.agentID == "agent-codex", "Agent ID parsing failed")
    try require(event.clipItem?.eventID == event.eventID, "Stable event ID was not attached")

    let notification = try JSONSerialization.data(withJSONObject: [
        "provider": "claude",
        "event": "notification",
        "payload": [
            "hook_event_name": "Notification",
            "notification_type": "agent_needs_input",
            "message": "Choose an option"
        ]
    ])
    try require(try AgentEventParser.parse(envelope: notification).kind == .inputRequired, "Input notification parsing failed")

    let codexInput = try JSONSerialization.data(withJSONObject: [
        "provider": "codex",
        "event": "input-request",
        "payload": [
            "hook_event_name": "PreToolUse",
            "tool_name": "functions.request_user_input"
        ]
    ])
    try require(try AgentEventParser.parse(envelope: codexInput).kind == .inputRequired, "Codex input request parsing failed")

    let gemini = try JSONSerialization.data(withJSONObject: [
        "provider": "gemini",
        "event": "after-agent",
        "payload": [
            "hook_event_name": "AfterAgent",
            "session_id": "gemini-session",
            "prompt_response": "Gemini finished this response."
        ]
    ])
    try require(try AgentEventParser.parse(envelope: gemini).clipItem?.text == "Gemini finished this response.", "Gemini response parsing failed")

    let cursor = try JSONSerialization.data(withJSONObject: [
        "provider": "cursor",
        "event": "after-agent-response",
        "payload": [
            "hook_event_name": "afterAgentResponse",
            "conversation_id": "cursor-conversation",
            "generation_id": "cursor-generation",
            "workspace_roots": ["/tmp/cursor-project"],
            "text": "Cursor finished this response."
        ]
    ])
    let cursorEvent = try AgentEventParser.parse(envelope: cursor)
    try require(cursorEvent.clipItem?.text == "Cursor finished this response.", "Cursor response parsing failed")
    try require(cursorEvent.clipItem?.agentTurnID == "cursor-generation", "Cursor generation ID parsing failed")

    let openCodePermission = try JSONSerialization.data(withJSONObject: [
        "provider": "opencode",
        "event": "permission-request",
        "payload": ["hook_event_name": "permission-request", "session_id": "open-code-session"]
    ])
    try require(try AgentEventParser.parse(envelope: openCodePermission).kind == .approvalRequired, "OpenCode permission parsing failed")

    try withTemporaryDirectory { directory in
        let transcript = directory.appendingPathComponent("copilot.jsonl")
        let rows = [
            #"{"role":"user","content":"please fix it"}"#,
            #"{"role":"assistant","content":[{"type":"text","text":"Copilot finished from transcript."}]}"#
        ].joined(separator: "\n")
        try Data(rows.utf8).write(to: transcript)
        let copilot = try JSONSerialization.data(withJSONObject: [
            "provider": "copilot",
            "event": "agent-stop",
            "payload": [
                "hook_event_name": "agentStop",
                "sessionId": "copilot-session",
                "transcriptPath": transcript.path
            ]
        ])
        try require(
            try AgentEventParser.parse(envelope: copilot).clipItem?.text == "Copilot finished from transcript.",
            "Copilot transcript parsing failed"
        )
    }
}

func checkHistoryParsers() throws {
    let codex = [
        #"{"timestamp":"2026-08-13T05:00:00.000Z","type":"session_meta","payload":{"id":"s1","cwd":"/tmp/repo"}}"#,
        #"{"timestamp":"2026-08-13T05:00:01.000Z","type":"response_item","payload":{"type":"message","role":"assistant","phase":"commentary","content":[{"type":"output_text","text":"working"}]}}"#,
        #"{"timestamp":"2026-08-13T05:00:02.000Z","type":"response_item","payload":{"type":"message","role":"assistant","phase":"final_answer","content":[{"type":"output_text","text":"finished"}]}}"#
    ].joined(separator: "\n")
    let codexItems = HistoryImporter.parseCodex(data: Data(codex.utf8))
    try require(codexItems.count == 1 && codexItems.first?.text == "finished", "Codex history parsing failed")

    let claude = [
        #"{"type":"assistant","sessionId":"s2","cwd":"/tmp/repo","timestamp":"2026-08-13T05:00:00.000Z","message":{"id":"m1","role":"assistant","content":[{"type":"text","text":"partial"}]}}"#,
        #"{"type":"assistant","sessionId":"s2","cwd":"/tmp/repo","timestamp":"2026-08-13T05:00:01.000Z","message":{"id":"m1","role":"assistant","content":[{"type":"text","text":"complete"}]}}"#
    ].joined(separator: "\n")
    let claudeItems = HistoryImporter.parseClaude(data: Data(claude.utf8))
    try require(claudeItems.count == 1 && claudeItems.first?.text == "complete", "Claude history parsing failed")
}

func checkAgentReplies() throws {
    let prompt = "Continue from DuckClip"
    let codex = try AgentSessionReply.request(
        provider: .codex,
        sessionID: "session-codex",
        prompt: prompt
    )
    try require(codex.sessionID == "session-codex", "Codex live session ID is incorrect")
    let openFiles = """
    p10760
    ccodex
    n/Users/example/.codex/sessions/rollout-session-codex.jsonl
    """
    try require(
        AgentSessionReply.processCandidates(
            fromOpenFileList: openFiles,
            sessionID: codex.sessionID
        ).first?.processID == 10760,
        "The live Codex process was not found from its open session file"
    )
}

func checkHookInstaller() throws {
    try withTemporaryDirectory { root in
        let helper = root.appendingPathComponent("duckclip-hook")
        try Data().write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        let claudeConfig = root.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: claudeConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing: [String: Any] = [
            "theme": "dark",
            "hooks": [
                "Stop": [["hooks": [
                    ["type": "command", "command": "/usr/bin/existing-hook"],
                    ["type": "command", "command": "/tmp/duckclip-hook-backup"]
                ]]]
            ]
        ]
        try JSONSerialization.data(withJSONObject: existing).write(to: claudeConfig)

        let cursorConfig = root.appendingPathComponent(".cursor/hooks.json")
        try FileManager.default.createDirectory(at: cursorConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "hooks": ["afterFileEdit": [["command": "/usr/bin/existing-cursor-hook"]]]
        ]).write(to: cursorConfig)

        let installer = HookInstaller(home: root, helperURL: helper)
        try installer.install()
        let status = installer.status()
        try require(status.providers.count == ItemSource.agentSources.count, "Not all providers were reported")
        let incomplete = status.providers.filter { !$0.installed }.map {
            "\($0.provider.rawValue): \($0.missingEvents.joined(separator: ","))"
        }.joined(separator: "; ")
        try require(status.providers.allSatisfy(\.installed), "One or more agent integrations failed to install: \(incomplete)")
        let installed = try String(contentsOf: claudeConfig, encoding: .utf8)
        try require(installed.contains("existing-hook"), "Existing hook was overwritten")
        try require(installed.contains("--managed-by duckclip"), "Managed hook marker is missing")
        try require(installed.contains("Library/Application Support/DuckClip/bin/duckclip-hook"), "Stable helper path was not installed")
        let installedCursor = try String(contentsOf: cursorConfig, encoding: .utf8)
        try require(installedCursor.contains("existing-cursor-hook"), "Existing Cursor hook was overwritten")
        try require(FileManager.default.fileExists(atPath: root.appendingPathComponent(".copilot/hooks/duckclip.json").path), "Copilot hook file is missing")
        let gajaeExtension = root.appendingPathComponent(".gjc/agent/extensions/duckclip/index.ts")
        let openCodePlugin = root.appendingPathComponent(".config/opencode/plugins/duckclip.js")
        try require(FileManager.default.fileExists(atPath: gajaeExtension.path), "Gajae extension is missing")
        try require(FileManager.default.fileExists(atPath: openCodePlugin.path), "OpenCode plugin is missing")
        try validateBunModule(at: gajaeExtension, output: root.appendingPathComponent("gajae-extension.js"))
        try validateBunModule(at: openCodePlugin, output: root.appendingPathComponent("opencode-plugin.js"))
        try installer.uninstall()
        let removed = try String(contentsOf: claudeConfig, encoding: .utf8)
        try require(removed.contains("existing-hook"), "Existing hook was removed")
        try require(removed.contains("duckclip-hook-backup"), "Unrelated hook with a similar name was removed")
        try require(!removed.contains("--managed-by duckclip"), "Managed DuckClip hook was not removed")
        let removedCursor = try String(contentsOf: cursorConfig, encoding: .utf8)
        try require(removedCursor.contains("existing-cursor-hook"), "Existing Cursor hook was removed")
        try require(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".copilot/hooks/duckclip.json").path), "Copilot hook file was not removed")
    }
}

do {
    try checkStore()
    try checkAgentEvents()
    try checkHistoryParsers()
    try checkAgentReplies()
    try checkHookInstaller()
    print("DuckClip checks passed: store, search, seven agent integrations, replies, events, and history import")
} catch {
    FileHandle.standardError.write(Data("DuckClip check failed: \(error.localizedDescription)\n".utf8))
    exit(EXIT_FAILURE)
}
