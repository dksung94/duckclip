import Foundation
import XCTest
@testable import DuckClipCore

final class SQLiteStoreTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DuckClipTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testInsertSearchPinAndDelete() throws {
        let directory = try temporaryDirectory()
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

        XCTAssertTrue(try store.insert(first))
        XCTAssertTrue(try store.insert(second))
        XCTAssertEqual(try store.search(query: "BalanceLocker").map(\.id), [second.id])
        XCTAssertEqual(try store.search(source: .clipboard).map(\.id), [first.id])
        XCTAssertEqual(try store.search(sources: [.claude, .codex]).map(\.id), [second.id])
        XCTAssertEqual(try store.search(agentID: "agent-1").map(\.id), [second.id])
        XCTAssertEqual(try store.sessions().first?.agentID, "agent-1")

        try store.setPinned(id: first.id, pinned: true)
        XCTAssertEqual(try store.search().first?.id, first.id)
        try store.softDelete(id: first.id)
        XCTAssertEqual(try store.search().map(\.id), [second.id])
        try store.restore(id: first.id)
        XCTAssertEqual(try store.search().first?.id, first.id)
        try store.softDelete(id: first.id)
        _ = try store.deleteSoftDeleted()
        XCTAssertNil(try store.item(id: first.id))
    }

    func testAgentTurnIsIdempotent() throws {
        let directory = try temporaryDirectory()
        let store = try SQLiteStore(url: directory.appendingPathComponent("test.sqlite3"))
        let item = ClipItem(
            kind: .agentResponse,
            source: .claude,
            text: "done",
            contentHash: ContentHasher.sha256("done"),
            sessionID: "s",
            agentTurnID: "t"
        )
        XCTAssertTrue(try store.insert(item))
        XCTAssertFalse(try store.insert(item))
        XCTAssertEqual(try store.count(), 1)
    }
}
