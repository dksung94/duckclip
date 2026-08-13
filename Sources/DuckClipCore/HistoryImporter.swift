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

    @discardableResult
    public func backfillExistingUserPrompts() throws -> Int {
        var updated = 0
        for (provider, relativePath) in [
            (ItemSource.codex, ".codex/sessions"),
            (ItemSource.claude, ".claude/projects")
        ] {
            let root = home.appendingPathComponent(relativePath, isDirectory: true)
            guard fileManager.fileExists(atPath: root.path), let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let file as URL in enumerator where file.pathExtension == "jsonl" {
                guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { continue }
                let items = provider == .codex ? Self.parseCodex(data: data) : Self.parseClaude(data: data)
                for item in items {
                    guard let prompt = item.userPrompt else { continue }
                    if try store.backfillUserPrompt(prompt, for: item) { updated += 1 }
                }
            }
        }
        return updated
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
        var activeUserPrompt: String?
        var results: [ClipItem] = []

        for line in data.split(separator: 0x0A) {
            autoreleasepool {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                    return
                }
                let type = object["type"] as? String
                let payload = object["payload"] as? [String: Any] ?? [:]
                if type == "session_meta" {
                    sessionID = payload["id"] as? String ?? payload["session_id"] as? String
                    cwd = payload["cwd"] as? String
                    return
                }
                if type == "turn_context" {
                    activeTurnID = payload["turn_id"] as? String ?? activeTurnID
                    cwd = payload["cwd"] as? String ?? cwd
                    return
                }
                if type == "event_msg", payload["type"] as? String == "task_started" {
                    activeTurnID = payload["turn_id"] as? String ?? activeTurnID
                    activeUserPrompt = nil
                    return
                }
                if type == "event_msg", payload["type"] as? String == "user_message" {
                    activeUserPrompt = sanitizedUserPrompt(payload["message"] as? String)
                    return
                }
                if type == "response_item",
                   payload["type"] as? String == "message",
                   payload["role"] as? String == "user" {
                    activeTurnID = codexTurnID(payload) ?? activeTurnID
                    activeUserPrompt = sanitizedUserPrompt(textContent(payload["content"]))
                    return
                }
                if type == "event_msg", payload["type"] as? String == "item_completed",
                   let item = payload["item"] as? [String: Any],
                   item["type"] as? String == "UserMessage" {
                    activeTurnID = payload["turn_id"] as? String ?? activeTurnID
                    activeUserPrompt = sanitizedUserPrompt(textContent(item["content"]))
                    return
                }
                guard
                    type == "response_item",
                    payload["type"] as? String == "message",
                    payload["role"] as? String == "assistant"
                else { return }

                let phase = payload["phase"] as? String
                if let phase, phase != "final_answer" { return }
                let content = payload["content"] as? [[String: Any]] ?? []
                let text = content.compactMap { block -> String? in
                    guard ["output_text", "text"].contains(block["type"] as? String ?? "") else { return nil }
                    return block["text"] as? String
                }.joined(separator: "\n")
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                let messageID = payload["id"] as? String
                let messageTurnID = codexTurnID(payload) ?? activeTurnID
                let timestamp = parseDate(object["timestamp"] as? String) ?? Date()
                results.append(ClipItem(
                    kind: .agentResponse,
                    source: .codex,
                    text: text,
                    userPrompt: activeUserPrompt,
                    contentHash: ContentHasher.sha256(text),
                    sessionID: sessionID,
                    agentTurnID: messageTurnID ?? messageID,
                    projectPath: cwd,
                    createdAt: timestamp
                ))
            }
        }
        return deduplicated(results)
    }

    public static func parseClaude(data: Data) -> [ClipItem] {
        var byMessageID: [String: ClipItem] = [:]
        var anonymous: [ClipItem] = []
        var activeUserPrompt: String?

        for line in data.split(separator: 0x0A) {
            autoreleasepool {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                    return
                }
                if object["type"] as? String == "user" {
                    guard object["isSidechain"] as? Bool != true,
                          object["isMeta"] as? Bool != true
                    else { return }
                    let message = object["message"] as? [String: Any] ?? [:]
                    guard message["role"] as? String == "user" else { return }
                    activeUserPrompt = sanitizedUserPrompt(textContent(message["content"]))
                    return
                }
                guard object["type"] as? String == "assistant" else { return }
                if object["isSidechain"] as? Bool == true { return }
                let message = object["message"] as? [String: Any] ?? [:]
                guard message["role"] as? String == "assistant" else { return }
                let content = message["content"] as? [[String: Any]] ?? []
                let text = content.compactMap { block -> String? in
                    guard block["type"] as? String == "text" else { return nil }
                    return block["text"] as? String
                }.joined(separator: "\n")
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

                let messageID = message["id"] as? String ?? object["uuid"] as? String
                let sessionID = object["sessionId"] as? String
                let cwd = object["cwd"] as? String
                let timestamp = parseDate(object["timestamp"] as? String) ?? Date()
                let item = ClipItem(
                    kind: .agentResponse,
                    source: .claude,
                    text: text,
                    userPrompt: activeUserPrompt,
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
        }
        return deduplicated(Array(byMessageID.values) + anonymous)
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func textContent(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        guard let blocks = value as? [[String: Any]] else { return nil }
        let text = blocks.compactMap { block -> String? in
            guard ["text", "input_text"].contains(block["type"] as? String ?? "") else { return nil }
            return block["text"] as? String
        }.joined(separator: "\n\n")
        return text.isEmpty ? nil : text
    }

    private static func codexTurnID(_ payload: [String: Any]) -> String? {
        if let turnID = payload["turn_id"] as? String { return turnID }
        let metadata = payload["internal_chat_message_metadata_passthrough"] as? [String: Any]
        return metadata?["turn_id"] as? String
    }

    private static func sanitizedUserPrompt(_ value: String?) -> String? {
        guard let value else { return nil }
        let prompt = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return nil }
        let normalized = prompt.lowercased()
        let metadataPrefixes = [
            "<local-command-", "<command-name>", "<system-reminder>",
            "<environment_context>", "<developer", "<instructions>"
        ]
        guard !metadataPrefixes.contains(where: normalized.hasPrefix) else { return nil }
        return String(prompt.prefix(50_000))
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
