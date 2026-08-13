import Foundation
import Testing
@testable import DuckClipCore

@Suite struct AgentEventTests {
    @Test func parsesCodexStopEnvelope() throws {
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
        #expect(event.provider == .codex)
        #expect(event.kind == .responseCompleted)
        #expect(event.clipItem?.text == "Implemented and tested.")
        #expect(event.clipItem?.agentTurnID == "turn-7")
        #expect(event.clipItem?.agentID == "agent-codex")
        #expect(event.clipItem?.eventID == event.eventID)

        let sameEvent = try AgentEventParser.parse(envelope: data)
        #expect(sameEvent.eventID == event.eventID)
    }

    @Test func parsesClaudePermissionRequest() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "provider": "claude",
            "event": "permission-request",
            "received_at": "2026-08-13T05:00:00Z",
            "payload": [
                "hook_event_name": "PermissionRequest",
                "session_id": "session-claude",
                "tool_name": "Bash",
                "tool_input": ["command": "swift test"]
            ]
        ])
        let event = try AgentEventParser.parse(envelope: data)
        #expect(event.kind == .approvalRequired)
        #expect(event.message.contains("swift test"))
    }

    @Test func parsesCodexInputRequest() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "provider": "codex",
            "event": "input-request",
            "payload": [
                "hook_event_name": "PreToolUse",
                "tool_name": "functions.request_user_input",
                "session_id": "session-codex"
            ]
        ])
        #expect(try AgentEventParser.parse(envelope: data).kind == .inputRequired)
    }

    @Test func parsesGeminiAndCursorResponses() throws {
        let gemini = try JSONSerialization.data(withJSONObject: [
            "provider": "gemini",
            "event": "after-agent",
            "payload": [
                "hook_event_name": "AfterAgent",
                "session_id": "gemini-session",
                "prompt_response": "Gemini completed."
            ]
        ])
        #expect(try AgentEventParser.parse(envelope: gemini).clipItem?.text == "Gemini completed.")

        let cursor = try JSONSerialization.data(withJSONObject: [
            "provider": "cursor",
            "event": "after-agent-response",
            "payload": [
                "hook_event_name": "afterAgentResponse",
                "conversation_id": "cursor-conversation",
                "generation_id": "cursor-generation",
                "workspace_roots": ["/tmp/cursor"],
                "text": "Cursor completed."
            ]
        ])
        let event = try AgentEventParser.parse(envelope: cursor)
        #expect(event.clipItem?.text == "Cursor completed.")
        #expect(event.clipItem?.agentTurnID == "cursor-generation")
        #expect(event.projectPath == "/tmp/cursor")
    }

    @Test func parsesCopilotResponseFromTranscript() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DuckClipAgentEventTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("copilot.jsonl")
        let lines = [
            #"{"role":"user","content":"fix it"}"#,
            #"{"role":"assistant","content":[{"type":"text","text":"Copilot completed."}]}"#
        ].joined(separator: "\n")
        try Data(lines.utf8).write(to: transcript)

        let data = try JSONSerialization.data(withJSONObject: [
            "provider": "copilot",
            "event": "agent-stop",
            "payload": [
                "hook_event_name": "agentStop",
                "sessionId": "copilot-session",
                "transcriptPath": transcript.path
            ]
        ])
        let event = try AgentEventParser.parse(envelope: data)
        #expect(event.clipItem?.text == "Copilot completed.")
        #expect(event.clipItem?.userPrompt == "fix it")
    }
}
