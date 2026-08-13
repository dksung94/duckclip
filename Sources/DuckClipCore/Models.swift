import Foundation

public enum ItemSource: String, Codable, CaseIterable, Sendable {
    case clipboard
    case claude
    case codex
    case gajae
    case gemini
    case copilot
    case cursor
    case opencode

    public static let agentSources: [ItemSource] = [
        .claude, .codex, .gajae, .gemini, .copilot, .cursor, .opencode
    ]

    public var isAgent: Bool { self != .clipboard }

    public var displayName: String {
        switch self {
        case .clipboard: String(localized: "Clipboard")
        case .claude: "Claude"
        case .codex: "Codex"
        case .gajae: "Gajae Code"
        case .gemini: "Gemini CLI"
        case .copilot: "GitHub Copilot CLI"
        case .cursor: "Cursor"
        case .opencode: "OpenCode"
        }
    }
}

public enum ItemKind: String, Codable, CaseIterable, Sendable {
    case text
    case url
    case image
    case file
    case agentResponse = "agent_response"
}

public struct ClipItem: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public var kind: ItemKind
    public var source: ItemSource
    public var text: String
    public var contentHash: String
    public var sessionID: String?
    public var agentID: String?
    public var agentTurnID: String?
    public var eventID: String?
    public var projectPath: String?
    public var sourceAppBundleID: String?
    public var payloadPath: String?
    public var createdAt: Date
    public var lastUsedAt: Date?
    public var isPinned: Bool

    public init(
        id: String = UUID().uuidString,
        kind: ItemKind,
        source: ItemSource,
        text: String,
        contentHash: String,
        sessionID: String? = nil,
        agentID: String? = nil,
        agentTurnID: String? = nil,
        eventID: String? = nil,
        projectPath: String? = nil,
        sourceAppBundleID: String? = nil,
        payloadPath: String? = nil,
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil,
        isPinned: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.source = source
        self.text = text
        self.contentHash = contentHash
        self.sessionID = sessionID
        self.agentID = agentID
        self.agentTurnID = agentTurnID
        self.eventID = eventID
        self.projectPath = projectPath
        self.sourceAppBundleID = sourceAppBundleID
        self.payloadPath = payloadPath
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.isPinned = isPinned
    }

    public var title: String {
        let first = text
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !first.isEmpty {
            let displayTitle: String
            if kind == .agentResponse {
                displayTitle = first.drop(while: { $0 == "#" || $0.isWhitespace }).description
            } else {
                displayTitle = first
            }
            return String(displayTitle.prefix(120))
        }
        if let payloadPath { return URL(fileURLWithPath: payloadPath).lastPathComponent }
        return kind.rawValue.capitalized
    }

    public var projectName: String? {
        projectPath.map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    public var agentIdentityID: String? {
        agentID ?? sessionID
    }
}

public enum SourceFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case clipboard
    case agents

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all: String(localized: "All")
        case .clipboard: String(localized: "Clipboard")
        case .agents: String(localized: "Agents")
        }
    }

    public var itemSources: [ItemSource]? {
        switch self {
        case .all: nil
        case .clipboard: [.clipboard]
        case .agents: ItemSource.agentSources
        }
    }
}

public struct AgentSessionSummary: Identifiable, Hashable, Sendable {
    public var id: String {
        "\(provider.rawValue):\(agentID ?? ""):\(sessionID ?? ""):\(projectPath ?? "")"
    }
    public let provider: ItemSource
    public let agentID: String?
    public let sessionID: String?
    public let projectPath: String?
    public let itemCount: Int
    public let lastSeenAt: Date

    public init(
        provider: ItemSource,
        agentID: String?,
        sessionID: String?,
        projectPath: String?,
        itemCount: Int,
        lastSeenAt: Date
    ) {
        self.provider = provider
        self.agentID = agentID
        self.sessionID = sessionID
        self.projectPath = projectPath
        self.itemCount = itemCount
        self.lastSeenAt = lastSeenAt
    }

    public var identityID: String { agentID ?? sessionID ?? "unknown" }
    public var identityKind: String {
        agentID == nil ? String(localized: "Session") : String(localized: "Agent")
    }
}

public struct ProviderHealth: Identifiable, Hashable, Sendable {
    public var id: String { provider.rawValue }
    public let provider: ItemSource
    public let lastEventAt: Date?
    public let lastEventKind: AgentEventKind?
    public let lastError: String?

    public init(
        provider: ItemSource,
        lastEventAt: Date? = nil,
        lastEventKind: AgentEventKind? = nil,
        lastError: String? = nil
    ) {
        self.provider = provider
        self.lastEventAt = lastEventAt
        self.lastEventKind = lastEventKind
        self.lastError = lastError
    }
}

public struct ImportSummary: Sendable {
    public var filesScanned: Int = 0
    public var itemsFound: Int = 0
    public var itemsImported: Int = 0

    public init(filesScanned: Int = 0, itemsFound: Int = 0, itemsImported: Int = 0) {
        self.filesScanned = filesScanned
        self.itemsFound = itemsFound
        self.itemsImported = itemsImported
    }
}
