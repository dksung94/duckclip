import CSQLite
import Foundation

public enum StoreError: LocalizedError {
    case open(String)
    case execute(String)
    case prepare(String)

    public var errorDescription: String? {
        switch self {
        case .open(let message):
            String(format: String(localized: "store.error.open", defaultValue: "Unable to open DuckClip database: %@"), message)
        case .execute(let message):
            String(format: String(localized: "store.error.execute", defaultValue: "DuckClip database operation failed: %@"), message)
        case .prepare(let message):
            String(format: String(localized: "store.error.prepare", defaultValue: "Unable to prepare DuckClip database query: %@"), message)
        }
    }
}

public final class SQLiteStore: @unchecked Sendable {
    private var database: OpaquePointer?
    private let lock = NSRecursiveLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(url: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            throw StoreError.open(message)
        }
        database = handle
        try migrate()
    }

    deinit {
        sqlite3_close(database)
    }

    private func migrate() throws {
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA synchronous=NORMAL;")
        try execute("PRAGMA foreign_keys=ON;")
        try execute("""
        CREATE TABLE IF NOT EXISTS items (
            id TEXT PRIMARY KEY NOT NULL,
            kind TEXT NOT NULL,
            source TEXT NOT NULL,
            text TEXT NOT NULL DEFAULT '',
            content_hash TEXT NOT NULL,
            session_id TEXT,
            agent_id TEXT,
            agent_turn_id TEXT,
            event_id TEXT,
            project_path TEXT,
            source_app_bundle_id TEXT,
            payload_path TEXT,
            created_at REAL NOT NULL,
            last_used_at REAL,
            pinned INTEGER NOT NULL DEFAULT 0,
            deleted_at REAL
        );
        """)
        try ensureColumn("agent_id", definition: "TEXT", in: "items")
        try ensureColumn("event_id", definition: "TEXT", in: "items")
        try execute("CREATE INDEX IF NOT EXISTS idx_items_recency ON items(pinned DESC, created_at DESC);")
        try execute("CREATE INDEX IF NOT EXISTS idx_items_source ON items(source, created_at DESC);")
        try execute("CREATE INDEX IF NOT EXISTS idx_items_session ON items(source, session_id, created_at DESC);")
        try execute("CREATE INDEX IF NOT EXISTS idx_items_agent ON items(source, agent_id, created_at DESC);")
        try execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_items_agent_turn ON items(source, session_id, agent_turn_id) WHERE agent_turn_id IS NOT NULL;")
        try execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_items_event ON items(source, event_id) WHERE event_id IS NOT NULL;")
        try execute("""
        CREATE TABLE IF NOT EXISTS provider_health (
            provider TEXT PRIMARY KEY NOT NULL,
            last_event_at REAL,
            last_event_kind TEXT,
            last_error TEXT
        );
        """)
        try execute("""
        CREATE VIRTUAL TABLE IF NOT EXISTS items_fts USING fts5(
            text,
            project_path,
            session_id,
            content='items',
            content_rowid='rowid',
            tokenize='unicode61 remove_diacritics 2'
        );
        """)
        try execute("""
        CREATE TRIGGER IF NOT EXISTS items_ai AFTER INSERT ON items BEGIN
            INSERT INTO items_fts(rowid, text, project_path, session_id)
            VALUES (new.rowid, new.text, new.project_path, new.session_id);
        END;
        """)
        try execute("""
        CREATE TRIGGER IF NOT EXISTS items_ad AFTER DELETE ON items BEGIN
            INSERT INTO items_fts(items_fts, rowid, text, project_path, session_id)
            VALUES ('delete', old.rowid, old.text, old.project_path, old.session_id);
        END;
        """)
        try execute("""
        CREATE TRIGGER IF NOT EXISTS items_au AFTER UPDATE ON items BEGIN
            INSERT INTO items_fts(items_fts, rowid, text, project_path, session_id)
            VALUES ('delete', old.rowid, old.text, old.project_path, old.session_id);
            INSERT INTO items_fts(rowid, text, project_path, session_id)
            VALUES (new.rowid, new.text, new.project_path, new.session_id);
        END;
        """)
    }

    @discardableResult
    public func insert(_ item: ClipItem) throws -> Bool {
        try withLock {
            if item.source == .clipboard, try refreshRecentDuplicate(item) {
                return false
            }

            let sql = """
            INSERT OR IGNORE INTO items (
                id, kind, source, text, content_hash, session_id, agent_id,
                agent_turn_id, event_id, project_path, source_app_bundle_id,
                payload_path, created_at, last_used_at, pinned, deleted_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL);
            """
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            bind(item.id, at: 1, in: statement)
            bind(item.kind.rawValue, at: 2, in: statement)
            bind(item.source.rawValue, at: 3, in: statement)
            bind(item.text, at: 4, in: statement)
            bind(item.contentHash, at: 5, in: statement)
            bind(item.sessionID, at: 6, in: statement)
            bind(item.agentID, at: 7, in: statement)
            bind(item.agentTurnID, at: 8, in: statement)
            bind(item.eventID, at: 9, in: statement)
            bind(item.projectPath, at: 10, in: statement)
            bind(item.sourceAppBundleID, at: 11, in: statement)
            bind(item.payloadPath, at: 12, in: statement)
            sqlite3_bind_double(statement, 13, item.createdAt.timeIntervalSince1970)
            bind(item.lastUsedAt?.timeIntervalSince1970, at: 14, in: statement)
            sqlite3_bind_int(statement, 15, item.isPinned ? 1 : 0)
            try stepDone(statement)
            return sqlite3_changes(database) > 0
        }
    }

    public func search(
        query: String = "",
        source: ItemSource? = nil,
        sources: [ItemSource]? = nil,
        projectPath: String? = nil,
        sessionID: String? = nil,
        agentID: String? = nil,
        limit: Int = 300
    ) throws -> [ClipItem] {
        try withLock {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            var clauses = ["i.deleted_at IS NULL"]
            var bindings: [Binding] = []
            var join = ""

            if !trimmed.isEmpty {
                join = "JOIN items_fts f ON f.rowid = i.rowid"
                clauses.append("items_fts MATCH ?")
                bindings.append(.text(Self.ftsQuery(trimmed)))
            }
            if let source {
                clauses.append("i.source = ?")
                bindings.append(.text(source.rawValue))
            } else if let sources {
                if sources.isEmpty {
                    clauses.append("1 = 0")
                } else {
                    clauses.append("i.source IN (\(Array(repeating: "?", count: sources.count).joined(separator: ", ")))")
                    bindings.append(contentsOf: sources.map { .text($0.rawValue) })
                }
            }
            if let projectPath {
                clauses.append("i.project_path = ?")
                bindings.append(.text(projectPath))
            }
            if let sessionID {
                clauses.append("i.session_id = ?")
                bindings.append(.text(sessionID))
            }
            if let agentID {
                clauses.append("i.agent_id = ?")
                bindings.append(.text(agentID))
            }

            let ordering = trimmed.isEmpty
                ? "i.pinned DESC, COALESCE(i.last_used_at, i.created_at) DESC"
                : "i.pinned DESC, bm25(items_fts) ASC, COALESCE(i.last_used_at, i.created_at) DESC"
            let sql = """
            SELECT i.id, i.kind, i.source, i.text, i.content_hash,
                   i.session_id, i.agent_id, i.agent_turn_id, i.event_id,
                   i.project_path, i.source_app_bundle_id, i.payload_path,
                   i.created_at, i.last_used_at, i.pinned
            FROM items i
            \(join)
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY \(ordering)
            LIMIT ?;
            """
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            for (offset, binding) in bindings.enumerated() {
                apply(binding, at: Int32(offset + 1), in: statement)
            }
            sqlite3_bind_int(statement, Int32(bindings.count + 1), Int32(limit))

            var result: [ClipItem] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                result.append(Self.item(from: statement))
            }
            return result
        }
    }

    public func sessions(source: ItemSource? = nil) throws -> [AgentSessionSummary] {
        try withLock {
            var whereClause = "deleted_at IS NULL AND source IN ('claude', 'codex') AND (session_id IS NOT NULL OR agent_id IS NOT NULL)"
            if source == .claude || source == .codex {
                whereClause += " AND source = ?"
            }
            let statement = try prepare("""
                SELECT source, agent_id,
                       CASE WHEN agent_id IS NULL THEN session_id ELSE NULL END AS fallback_session_id,
                       project_path, COUNT(*), MAX(created_at)
                FROM items
                WHERE \(whereClause)
                GROUP BY source, agent_id,
                         CASE WHEN agent_id IS NULL THEN session_id ELSE NULL END,
                         project_path
                ORDER BY MAX(created_at) DESC;
            """)
            defer { sqlite3_finalize(statement) }
            if source == .claude || source == .codex {
                bind(source?.rawValue, at: 1, in: statement)
            }
            var result: [AgentSessionSummary] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard
                    let sourceValue = Self.text(statement, 0),
                    let itemSource = ItemSource(rawValue: sourceValue)
                else { continue }
                result.append(AgentSessionSummary(
                    provider: itemSource,
                    agentID: Self.text(statement, 1),
                    sessionID: Self.text(statement, 2),
                    projectPath: Self.text(statement, 3),
                    itemCount: Int(sqlite3_column_int(statement, 4)),
                    lastSeenAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
                ))
            }
            return result
        }
    }

    public func setPinned(id: String, pinned: Bool) throws {
        try update("UPDATE items SET pinned = ? WHERE id = ?;", [.integer(pinned ? 1 : 0), .text(id)])
    }

    public func markUsed(id: String, at date: Date = Date()) throws {
        try update("UPDATE items SET last_used_at = ? WHERE id = ?;", [.double(date.timeIntervalSince1970), .text(id)])
    }

    public func softDelete(id: String) throws {
        try update("UPDATE items SET deleted_at = ? WHERE id = ?;", [.double(Date().timeIntervalSince1970), .text(id)])
    }

    public func restore(id: String) throws {
        try update("UPDATE items SET deleted_at = NULL WHERE id = ?;", [.text(id)])
    }

    public func deleteSoftDeleted() throws -> [String] {
        try withLock {
            let paths = try payloadPaths(
                sql: "SELECT DISTINCT payload_path FROM items WHERE deleted_at IS NOT NULL AND payload_path IS NOT NULL;"
            )
            try update("DELETE FROM items WHERE deleted_at IS NOT NULL;", [])
            return try unreferenced(paths: paths)
        }
    }

    public func delete(id: String) throws -> [String] {
        try withLock {
            let paths = try payloadPaths(sql: "SELECT payload_path FROM items WHERE id = ? AND payload_path IS NOT NULL;", bindings: [.text(id)])
            try update("DELETE FROM items WHERE id = ?;", [.text(id)])
            return try unreferenced(paths: paths)
        }
    }

    public func clearUnpinned() throws -> [String] {
        try withLock {
            let paths = try payloadPaths(sql: "SELECT DISTINCT payload_path FROM items WHERE pinned = 0 AND payload_path IS NOT NULL;")
            try update("DELETE FROM items WHERE pinned = 0;", [])
            return try unreferenced(paths: paths)
        }
    }

    public func purge(olderThan date: Date) throws -> [String] {
        try withLock {
            let paths = try payloadPaths(
                sql: "SELECT DISTINCT payload_path FROM items WHERE pinned = 0 AND created_at < ? AND payload_path IS NOT NULL;",
                bindings: [.double(date.timeIntervalSince1970)]
            )
            try update("DELETE FROM items WHERE pinned = 0 AND created_at < ?;", [.double(date.timeIntervalSince1970)])
            return try unreferenced(paths: paths)
        }
    }

    public func count() throws -> Int {
        try withLock {
            let statement = try prepare("SELECT COUNT(*) FROM items WHERE deleted_at IS NULL;")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    public func recordAgentEvent(_ event: AgentEvent, error: String? = nil) throws {
        try update("""
            INSERT INTO provider_health (provider, last_event_at, last_event_kind, last_error)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(provider) DO UPDATE SET
                last_event_at = excluded.last_event_at,
                last_event_kind = excluded.last_event_kind,
                last_error = excluded.last_error;
        """, [
            .text(event.provider.rawValue),
            .double(event.receivedAt.timeIntervalSince1970),
            .text(event.kind.rawValue),
            error.map(Binding.text) ?? .null
        ])
    }

    public func providerHealth() throws -> [ProviderHealth] {
        try withLock {
            let statement = try prepare("""
                SELECT provider, last_event_at, last_event_kind, last_error
                FROM provider_health ORDER BY provider;
            """)
            defer { sqlite3_finalize(statement) }
            var result: [ProviderHealth] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard
                    let rawProvider = Self.text(statement, 0),
                    let provider = ItemSource(rawValue: rawProvider)
                else { continue }
                let lastEventAt = sqlite3_column_type(statement, 1) == SQLITE_NULL
                    ? nil
                    : Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
                result.append(ProviderHealth(
                    provider: provider,
                    lastEventAt: lastEventAt,
                    lastEventKind: Self.text(statement, 2).flatMap(AgentEventKind.init(rawValue:)),
                    lastError: Self.text(statement, 3)
                ))
            }
            return result
        }
    }

    public func item(id: String) throws -> ClipItem? {
        try withLock {
            let statement = try prepare("""
                SELECT id, kind, source, text, content_hash,
                       session_id, agent_id, agent_turn_id, event_id,
                       project_path, source_app_bundle_id, payload_path,
                       created_at, last_used_at, pinned
                FROM items WHERE id = ? AND deleted_at IS NULL LIMIT 1;
            """)
            defer { sqlite3_finalize(statement) }
            bind(id, at: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return Self.item(from: statement)
        }
    }

    private func refreshRecentDuplicate(_ item: ClipItem) throws -> Bool {
        let threshold = item.createdAt.addingTimeInterval(-5).timeIntervalSince1970
        let statement = try prepare("""
            UPDATE items
            SET created_at = ?, source_app_bundle_id = ?, deleted_at = NULL
            WHERE id = (
                SELECT id FROM items
                WHERE source = 'clipboard' AND content_hash = ? AND created_at >= ?
                ORDER BY created_at DESC LIMIT 1
            );
        """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, item.createdAt.timeIntervalSince1970)
        bind(item.sourceAppBundleID, at: 2, in: statement)
        bind(item.contentHash, at: 3, in: statement)
        sqlite3_bind_double(statement, 4, threshold)
        try stepDone(statement)
        return sqlite3_changes(database) > 0
    }

    private func update(_ sql: String, _ bindings: [Binding]) throws {
        try withLock {
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            for (offset, binding) in bindings.enumerated() {
                apply(binding, at: Int32(offset + 1), in: statement)
            }
            try stepDone(statement)
        }
    }

    private func payloadPaths(sql: String, bindings: [Binding] = []) throws -> [String] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (offset, binding) in bindings.enumerated() {
            apply(binding, at: Int32(offset + 1), in: statement)
        }
        var paths: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let path = Self.text(statement, 0) { paths.append(path) }
        }
        return paths
    }

    private func unreferenced(paths: [String]) throws -> [String] {
        try paths.filter { path in
            let statement = try prepare("SELECT 1 FROM items WHERE payload_path = ? LIMIT 1;")
            defer { sqlite3_finalize(statement) }
            bind(path, at: 1, in: statement)
            return sqlite3_step(statement) != SQLITE_ROW
        }
    }

    private func execute(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? lastError
            sqlite3_free(errorPointer)
            throw StoreError.execute(message)
        }
    }

    private func ensureColumn(_ name: String, definition: String, in table: String) throws {
        let statement = try prepare("PRAGMA table_info(\(table));")
        var exists = false
        while sqlite3_step(statement) == SQLITE_ROW {
            if Self.text(statement, 1) == name {
                exists = true
                break
            }
        }
        sqlite3_finalize(statement)
        guard !exists else { return }
        try execute("ALTER TABLE \(table) ADD COLUMN \(name) \(definition);")
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.prepare(lastError)
        }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StoreError.execute(lastError)
        }
    }

    private var lastError: String {
        database.map { String(cString: sqlite3_errmsg($0)) } ?? "database unavailable"
    }

    private func bind(_ value: String?, at index: Int32, in statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, Self.transient)
    }

    private func bind(_ value: Double?, at index: Int32, in statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_double(statement, index, value)
    }

    private enum Binding {
        case text(String)
        case integer(Int)
        case double(Double)
        case null
    }

    private func apply(_ binding: Binding, at index: Int32, in statement: OpaquePointer) {
        switch binding {
        case .text(let value): bind(value, at: index, in: statement)
        case .integer(let value): sqlite3_bind_int64(statement, index, sqlite3_int64(value))
        case .double(let value): sqlite3_bind_double(statement, index, value)
        case .null: sqlite3_bind_null(statement, index)
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private static func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    private static func item(from statement: OpaquePointer) -> ClipItem {
        ClipItem(
            id: text(statement, 0) ?? UUID().uuidString,
            kind: ItemKind(rawValue: text(statement, 1) ?? "text") ?? .text,
            source: ItemSource(rawValue: text(statement, 2) ?? "clipboard") ?? .clipboard,
            text: text(statement, 3) ?? "",
            contentHash: text(statement, 4) ?? "",
            sessionID: text(statement, 5),
            agentID: text(statement, 6),
            agentTurnID: text(statement, 7),
            eventID: text(statement, 8),
            projectPath: text(statement, 9),
            sourceAppBundleID: text(statement, 10),
            payloadPath: text(statement, 11),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 12)),
            lastUsedAt: sqlite3_column_type(statement, 13) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 13)),
            isPinned: sqlite3_column_int(statement, 14) != 0
        )
    }

    private static func ftsQuery(_ query: String) -> String {
        let tokens = query
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.replacingOccurrences(of: "\"", with: "\"\"") }
            .filter { !$0.isEmpty }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " AND ")
    }
}
