import Foundation
import Testing
@testable import DuckClipCore

@Suite struct SQLiteStoreTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DuckClipTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func insertSearchPinAndDelete() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteStore(url: directory.appendingPathComponent("test.sqlite3"))
        let first = ClipItem(
            kind: .text,
            source: .clipboard,
            text: "A yellow duck remembers this clipboard",
            contentHash: ContentHasher.sha256("A yellow duck remembers this clipboard")
        )
        let second = ClipItem(
            kind: .agentResponse,
            source: .codex,
            text: "The race condition is inside BalanceLocker",
            contentHash: ContentHasher.sha256("The race condition is inside BalanceLocker"),
            sessionID: "session-1",
            agentID: "agent-1",
            agentTurnID: "turn-1",
            eventID: "event-1",
            projectPath: "/tmp/platform-api"
        )

        #expect(try store.insert(first))
        #expect(try store.insert(second))
        #expect(try store.search(query: "BalanceLocker").map(\.id) == [second.id])
        #expect(try store.search(source: .clipboard).map(\.id) == [first.id])
        #expect(try store.search(sources: ItemSource.agentSources).map(\.id) == [second.id])
        #expect(try store.search(agentID: "agent-1").map(\.id) == [second.id])
        #expect(try store.sessions().first?.agentID == "agent-1")

        try store.setPinned(id: first.id, pinned: true)
        #expect(try store.search().first?.id == first.id)
        try store.softDelete(id: first.id)
        #expect(try store.search().map(\.id) == [second.id])
        try store.restore(id: first.id)
        #expect(try store.search().first?.id == first.id)
        try store.softDelete(id: first.id)
        _ = try store.deleteSoftDeleted()
        #expect(try store.item(id: first.id) == nil)
    }

    @Test func agentTurnIsIdempotent() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteStore(url: directory.appendingPathComponent("test.sqlite3"))
        let item = ClipItem(
            kind: .agentResponse,
            source: .claude,
            text: "done",
            contentHash: ContentHasher.sha256("done"),
            sessionID: "s",
            agentTurnID: "t"
        )
        #expect(try store.insert(item))
        #expect(try !store.insert(item))
        #expect(try store.count() == 1)
    }

    @Test func backfillsQuestionOntoAnExistingAgentResponse() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteStore(url: directory.appendingPathComponent("test.sqlite3"))
        let original = ClipItem(
            kind: .agentResponse,
            source: .codex,
            text: "Fixed it.",
            contentHash: "answer-hash",
            sessionID: "session-1",
            agentTurnID: "turn-1"
        )
        #expect(try store.insert(original))

        let enriched = ClipItem(
            kind: .agentResponse,
            source: .codex,
            text: "Fixed it.",
            userPrompt: "Can you fix the layout?",
            contentHash: "answer-hash",
            sessionID: "session-1",
            agentTurnID: "turn-1"
        )
        #expect(try !store.insert(enriched))
        #expect(try store.item(id: original.id)?.userPrompt == "Can you fix the layout?")
    }
}
