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
        try require(try store.search(sources: [.claude, .codex]).map(\.id) == [agent.id], "Agent source filter failed")
        try require(try store.search(agentID: "agent-9").map(\.id) == [agent.id], "Agent ID filter failed")
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

        let installer = HookInstaller(home: root, helperURL: helper)
        try installer.install()
        try require(installer.status().claudeInstalled, "Claude hook installation failed")
        try require(installer.status().codexInstalled, "Codex hook installation failed")
        let installed = try String(contentsOf: claudeConfig, encoding: .utf8)
        try require(installed.contains("existing-hook"), "Existing hook was overwritten")
        try require(installed.contains("--managed-by duckclip"), "Managed hook marker is missing")
        try require(installed.contains("Library/Application Support/DuckClip/bin/duckclip-hook"), "Stable helper path was not installed")
        try installer.uninstall()
        let removed = try String(contentsOf: claudeConfig, encoding: .utf8)
        try require(removed.contains("existing-hook"), "Existing hook was removed")
        try require(removed.contains("duckclip-hook-backup"), "Unrelated hook with a similar name was removed")
        try require(!removed.contains("--managed-by duckclip"), "Managed DuckClip hook was not removed")
    }
}

do {
    try checkStore()
    try checkAgentEvents()
    try checkHistoryParsers()
    try checkHookInstaller()
    print("DuckClip checks passed: store, search, hooks, events, and history import")
} catch {
    FileHandle.standardError.write(Data("DuckClip check failed: \(error.localizedDescription)\n".utf8))
    exit(EXIT_FAILURE)
}
