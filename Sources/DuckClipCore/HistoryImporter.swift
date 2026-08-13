import Foundation

public final class HistoryImporter: @unchecked Sendable {
    private let store: SQLiteStore
    private let home: URL
    private let fileManager: FileManager

    public init(
        store: SQLiteStore,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        self.store = store
        self.home = home
        self.fileManager = fileManager
    }

    public func importAll(provider: ItemSource? = nil) throws -> ImportSummary {
        var summary = ImportSummary()
        if provider == nil || provider == .codex {
            let root = home.appendingPathComponent(".codex/sessions", isDirectory: true)
            try importFiles(at: root, provider: .codex, summary: &summary)
        }
        if provider == nil || provider == .claude {
            let root = home.appendingPathComponent(".claude/projects", isDirectory: true)
            try importFiles(at: root, provider: .claude, summary: &summary)
        }
        return summary
    }

    private func importFiles(at root: URL, provider: ItemSource, summary: inout ImportSummary) throws {
        guard fileManager.fileExists(atPath: root.path), let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let file as URL in enumerator where file.pathExtension == "jsonl" {
            summary.filesScanned += 1
            let items: [ClipItem]
            do {
                let data = try Data(contentsOf: file, options: .mappedIfSafe)
                items = provider == .codex
                    ? Self.parseCodex(data: data)
                    : Self.parseClaude(data: data)
            } catch {
                continue
            }
            summary.itemsFound += items.count
            for item in items {
                if try store.insert(item) { summary.itemsImported += 1 }
            }
        }
    }

    public static func parseCodex(data: Data) -> [ClipItem] {
        var sessionID: String?
        var cwd: String?
        var activeTurnID: String?
        var results: [ClipItem] = []

        for object in jsonLines(data) {
            let type = object["type"] as? String
            let payload = object["payload"] as? [String: Any] ?? [:]
            if type == "session_meta" {
                sessionID = payload["id"] as? String ?? payload["session_id"] as? String
                cwd = payload["cwd"] as? String
                continue
            }
            if type == "turn_context" {
                activeTurnID = payload["turn_id"] as? String ?? activeTurnID
                cwd = payload["cwd"] as? String ?? cwd
                continue
            }
            if type == "event_msg", payload["type"] as? String == "task_started" {
                activeTurnID = payload["turn_id"] as? String ?? activeTurnID
                continue
            }
            guard
                type == "response_item",
                payload["type"] as? String == "message",
                payload["role"] as? String == "assistant"
            else { continue }

            let phase = payload["phase"] as? String
            if let phase, phase != "final_answer" { continue }
            let content = payload["content"] as? [[String: Any]] ?? []
            let text = content.compactMap { block -> String? in
                guard ["output_text", "text"].contains(block["type"] as? String ?? "") else { return nil }
                return block["text"] as? String
            }.joined(separator: "\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let messageID = payload["id"] as? String
            let timestamp = parseDate(object["timestamp"] as? String) ?? Date()
            results.append(ClipItem(
                kind: .agentResponse,
                source: .codex,
                text: text,
                contentHash: ContentHasher.sha256(text),
                sessionID: sessionID,
                agentTurnID: messageID ?? activeTurnID,
                projectPath: cwd,
                createdAt: timestamp
            ))
        }
        return deduplicated(results)
    }

    public static func parseClaude(data: Data) -> [ClipItem] {
        var byMessageID: [String: ClipItem] = [:]
        var anonymous: [ClipItem] = []

        for object in jsonLines(data) {
            guard object["type"] as? String == "assistant" else { continue }
            if object["isSidechain"] as? Bool == true { continue }
            let message = object["message"] as? [String: Any] ?? [:]
            guard message["role"] as? String == "assistant" else { continue }
            let content = message["content"] as? [[String: Any]] ?? []
            let text = content.compactMap { block -> String? in
                guard block["type"] as? String == "text" else { return nil }
                return block["text"] as? String
            }.joined(separator: "\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            let messageID = message["id"] as? String ?? object["uuid"] as? String
            let sessionID = object["sessionId"] as? String
            let cwd = object["cwd"] as? String
            let timestamp = parseDate(object["timestamp"] as? String) ?? Date()
            let item = ClipItem(
                kind: .agentResponse,
                source: .claude,
                text: text,
                contentHash: ContentHasher.sha256(text),
                sessionID: sessionID,
                agentTurnID: messageID,
                projectPath: cwd,
                createdAt: timestamp
            )
            if let messageID {
                byMessageID[messageID] = item
            } else {
                anonymous.append(item)
            }
        }
        return deduplicated(Array(byMessageID.values) + anonymous)
    }

    private static func jsonLines(_ data: Data) -> [[String: Any]] {
        data.split(separator: 0x0A).compactMap { line in
            try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
        }
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func deduplicated(_ items: [ClipItem]) -> [ClipItem] {
        var seen = Set<String>()
        return items
            .sorted { $0.createdAt < $1.createdAt }
            .filter { item in
                let key = "\(item.sessionID ?? ""):\(item.agentTurnID ?? item.contentHash)"
                return seen.insert(key).inserted
            }
    }
}
