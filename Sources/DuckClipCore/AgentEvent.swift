import Foundation

public enum AgentEventKind: String, Sendable {
    case responseCompleted
    case approvalRequired
    case inputRequired
    case sessionStarted
    case failed
    case ignored
}

public struct AgentEvent: Sendable {
    public let provider: ItemSource
    public let kind: AgentEventKind
    public let sessionID: String?
    public let agentID: String?
    public let turnID: String?
    public let transcriptPath: String?
    public let eventID: String
    public let projectPath: String?
    public let response: String?
    public let title: String
    public let message: String
    public let receivedAt: Date

    public init(
        provider: ItemSource,
        kind: AgentEventKind,
        sessionID: String?,
        agentID: String?,
        turnID: String?,
        transcriptPath: String?,
        eventID: String,
        projectPath: String?,
        response: String?,
        title: String,
        message: String,
        receivedAt: Date
    ) {
        self.provider = provider
        self.kind = kind
        self.sessionID = sessionID
        self.agentID = agentID
        self.turnID = turnID
        self.transcriptPath = transcriptPath
        self.eventID = eventID
        self.projectPath = projectPath
        self.response = response
        self.title = title
        self.message = message
        self.receivedAt = receivedAt
    }

    public var clipItem: ClipItem? {
        guard kind == .responseCompleted, let response, !response.isEmpty else { return nil }
        return ClipItem(
            kind: .agentResponse,
            source: provider,
            text: response,
            contentHash: ContentHasher.sha256(response),
            sessionID: sessionID,
            agentID: agentID,
            agentTurnID: turnID,
            eventID: eventID,
            projectPath: projectPath,
            createdAt: receivedAt
        )
    }
}

public enum AgentEventParser {
    public static func parse(envelope data: Data) throws -> AgentEvent {
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let providerValue = root["provider"] as? String,
            let provider = ItemSource(rawValue: providerValue),
            let payload = root["payload"] as? [String: Any]
        else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let eventName = string(payload, "hook_event_name", "hookEventName")
            ?? (root["event"] as? String)
            ?? ""
        let sessionID = string(
            payload,
            "session_id", "sessionId", "thread_id", "threadId", "conversation_id", "conversationId"
        )
        let agentID = string(payload, "agent_id", "agentId")
        let turnID = string(payload, "turn_id", "turnId")
        let transcriptPath = string(payload, "transcript_path", "transcriptPath")
        let projectPath = string(payload, "cwd", "project_path", "projectPath")
        let receivedAt = ISO8601DateFormatter().date(from: root["received_at"] as? String ?? "") ?? Date()
        let response = string(payload, "last_assistant_message", "lastAssistantMessage")
        let notificationType = string(payload, "notification_type", "notificationType")

        let kind: AgentEventKind
        switch eventName.lowercased() {
        case "stop":
            kind = .responseCompleted
        case "permissionrequest", "permission_request":
            kind = .approvalRequired
        case "notification":
            if notificationType == "permission_prompt" {
                kind = .approvalRequired
            } else if ["idle_prompt", "agent_needs_input"].contains(notificationType) {
                kind = .inputRequired
            } else if notificationType == "agent_completed" {
                kind = .responseCompleted
            } else {
                kind = .ignored
            }
        case "sessionstart", "session_start":
            kind = .sessionStarted
        case "stopfailure", "stop_failure":
            kind = .failed
        default:
            kind = .ignored
        }

        let providerName = provider.displayName
        let projectName = projectPath.map { URL(fileURLWithPath: $0).lastPathComponent }
        let toolName = string(payload, "tool_name", "toolName")
        let toolInput = (payload["tool_input"] as? [String: Any])
            ?? (payload["toolInput"] as? [String: Any])
        let description = toolInput?["description"] as? String
            ?? toolInput?["command"] as? String
            ?? string(payload, "message")

        let title: String
        let message: String
        switch kind {
        case .responseCompleted:
            title = String(
                format: String(localized: "notification.response_ready", defaultValue: "%@ response ready"),
                providerName
            )
            message = response?.firstNonemptyLine
                ?? projectName
                ?? String(localized: "notification.open_for_details", defaultValue: "Open DuckClip to view it.")
        case .approvalRequired:
            title = String(
                format: String(localized: "notification.needs_approval", defaultValue: "%@ needs approval"),
                providerName
            )
            message = description
                ?? toolName
                ?? projectName
                ?? String(localized: "notification.return_to_agent", defaultValue: "Return to the agent to continue.")
        case .inputRequired:
            title = String(
                format: String(localized: "notification.waiting", defaultValue: "%@ is waiting"),
                providerName
            )
            message = string(payload, "message")
                ?? projectName
                ?? String(localized: "notification.waiting_for_input", defaultValue: "The agent is waiting for input.")
        case .failed:
            title = String(
                format: String(localized: "notification.failed", defaultValue: "%@ stopped with an error"),
                providerName
            )
            message = string(payload, "error_details", "errorDetails")
                ?? string(payload, "error")
                ?? projectName
                ?? String(localized: "notification.open_session", defaultValue: "Open the session for details.")
        case .sessionStarted, .ignored:
            title = providerName
            message = projectName ?? ""
        }

        let eventComponents: [String] = [
            provider.rawValue,
            eventName.lowercased(),
            sessionID ?? "",
            agentID ?? "",
            turnID ?? "",
            transcriptPath ?? "",
            response.map(ContentHasher.sha256) ?? "",
            notificationType ?? "",
            toolName ?? ""
        ]
        let eventID = ContentHasher.sha256(eventComponents.joined(separator: "\u{1F}"))

        return AgentEvent(
            provider: provider,
            kind: kind,
            sessionID: sessionID,
            agentID: agentID,
            turnID: turnID,
            transcriptPath: transcriptPath,
            eventID: eventID,
            projectPath: projectPath,
            response: response,
            title: title,
            message: String(message.prefix(220)),
            receivedAt: receivedAt
        )
    }

    private static func string(_ object: [String: Any], _ keys: String...) -> String? {
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }
}

private extension String {
    var firstNonemptyLine: String? {
        split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
            .map { String($0.prefix(180)) }
    }
}
