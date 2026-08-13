import Foundation
import XCTest
@testable import DuckClipCore

final class HistoryImporterTests: XCTestCase {
    func testCodexHistoryParserImportsFinalAnswersOnly() throws {
        let lines = [
            #"{"timestamp":"2026-08-13T05:00:00.000Z","type":"session_meta","payload":{"id":"s1","cwd":"/tmp/repo"}}"#,
            #"{"timestamp":"2026-08-13T05:00:01.000Z","type":"response_item","payload":{"type":"message","id":"m1","role":"assistant","phase":"commentary","content":[{"type":"output_text","text":"working"}]}}"#,
            #"{"timestamp":"2026-08-13T05:00:02.000Z","type":"response_item","payload":{"type":"message","id":"m2","role":"assistant","phase":"final_answer","content":[{"type":"output_text","text":"finished"}]}}"#
        ].joined(separator: "\n")
        let items = HistoryImporter.parseCodex(data: Data(lines.utf8))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.text, "finished")
        XCTAssertEqual(items.first?.sessionID, "s1")
    }

    func testClaudeHistoryParserDeduplicatesMessageUpdates() throws {
        let lines = [
            #"{"type":"assistant","sessionId":"s2","cwd":"/tmp/repo","timestamp":"2026-08-13T05:00:00.000Z","message":{"id":"m1","role":"assistant","content":[{"type":"text","text":"partial"}]}}"#,
            #"{"type":"assistant","sessionId":"s2","cwd":"/tmp/repo","timestamp":"2026-08-13T05:00:01.000Z","message":{"id":"m1","role":"assistant","content":[{"type":"text","text":"complete"}]}}"#
        ].joined(separator: "\n")
        let items = HistoryImporter.parseClaude(data: Data(lines.utf8))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.text, "complete")
    }
}
