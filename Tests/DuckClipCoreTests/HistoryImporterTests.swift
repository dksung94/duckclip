import Foundation
import Testing
@testable import DuckClipCore

@Suite struct HistoryImporterTests {
    @Test func codexHistoryParserImportsFinalAnswersOnly() throws {
        let lines = [
            #"{"timestamp":"2026-08-13T05:00:00.000Z","type":"session_meta","payload":{"id":"s1","cwd":"/tmp/repo"}}"#,
            #"{"timestamp":"2026-08-13T05:00:00.500Z","type":"event_msg","payload":{"type":"user_message","message":"Why is the pane shrinking?"}}"#,
            #"{"timestamp":"2026-08-13T05:00:01.000Z","type":"response_item","payload":{"type":"message","id":"m1","role":"assistant","phase":"commentary","content":[{"type":"output_text","text":"working"}]}}"#,
            #"{"timestamp":"2026-08-13T05:00:02.000Z","type":"response_item","payload":{"type":"message","id":"m2","role":"assistant","phase":"final_answer","content":[{"type":"output_text","text":"finished"}]}}"#
        ].joined(separator: "\n")
        let items = HistoryImporter.parseCodex(data: Data(lines.utf8))
        #expect(items.count == 1)
        #expect(items.first?.text == "finished")
        #expect(items.first?.userPrompt == "Why is the pane shrinking?")
        #expect(items.first?.title == "Why is the pane shrinking?")
        #expect(items.first?.sessionID == "s1")
    }

    @Test func codexHistoryParserLinksCurrentUserMessageFormatByTurn() throws {
        let lines = [
            #"{"timestamp":"2026-08-13T05:00:00.000Z","type":"session_meta","payload":{"id":"s1","cwd":"/tmp/repo"}}"#,
            #"{"timestamp":"2026-08-13T05:00:00.500Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-7"}}"#,
            #"{"timestamp":"2026-08-13T05:00:00.600Z","type":"response_item","payload":{"type":"message","id":"user-message","role":"user","content":[{"type":"input_text","text":"Why is my question missing?"}],"internal_chat_message_metadata_passthrough":{"turn_id":"turn-7"}}}"#,
            #"{"timestamp":"2026-08-13T05:00:01.000Z","type":"response_item","payload":{"type":"message","id":"assistant-message","role":"assistant","phase":"final_answer","content":[{"type":"output_text","text":"It is fixed."}],"internal_chat_message_metadata_passthrough":{"turn_id":"turn-7"}}}"#
        ].joined(separator: "\n")

        let item = HistoryImporter.parseCodex(data: Data(lines.utf8)).first
        #expect(item?.userPrompt == "Why is my question missing?")
        #expect(item?.agentTurnID == "turn-7")
        #expect(item?.title == "Why is my question missing?")
    }

    @Test func claudeHistoryParserDeduplicatesMessageUpdates() throws {
        let lines = [
            #"{"type":"user","sessionId":"s2","cwd":"/tmp/repo","timestamp":"2026-08-13T04:59:59.000Z","message":{"role":"user","content":"Please keep the window full height."}}"#,
            #"{"type":"assistant","sessionId":"s2","cwd":"/tmp/repo","timestamp":"2026-08-13T05:00:00.000Z","message":{"id":"m1","role":"assistant","content":[{"type":"text","text":"partial"}]}}"#,
            #"{"type":"assistant","sessionId":"s2","cwd":"/tmp/repo","timestamp":"2026-08-13T05:00:01.000Z","message":{"id":"m1","role":"assistant","content":[{"type":"text","text":"complete"}]}}"#
        ].joined(separator: "\n")
        let items = HistoryImporter.parseClaude(data: Data(lines.utf8))
        #expect(items.count == 1)
        #expect(items.first?.text == "complete")
        #expect(items.first?.userPrompt == "Please keep the window full height.")
    }
}
