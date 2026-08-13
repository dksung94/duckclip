import Foundation
import XCTest
@testable import DuckClipCore

final class AgentEventTests: XCTestCase {
    func testParsesCodexStopEnvelope() throws {
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
        XCTAssertEqual(event.provider, .codex)
        XCTAssertEqual(event.kind, .responseCompleted)
        XCTAssertEqual(event.clipItem?.text, "Implemented and tested.")
        XCTAssertEqual(event.clipItem?.agentTurnID, "turn-7")
        XCTAssertEqual(event.clipItem?.agentID, "agent-codex")
        XCTAssertEqual(event.clipItem?.eventID, event.eventID)

        let sameEvent = try AgentEventParser.parse(envelope: data)
        XCTAssertEqual(sameEvent.eventID, event.eventID)
    }

    func testParsesClaudePermissionRequest() throws {
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
        XCTAssertEqual(event.kind, .approvalRequired)
        XCTAssertTrue(event.message.contains("swift test"))
    }
}
