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
    public let userPrompt: String?
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
        userPrompt: String? = nil,
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
        self.userPrompt = userPrompt
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
            userPrompt: userPrompt,
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
            "session_id", "sessionId", "sessionID", "thread_id", "threadId", "conversation_id", "conversationId"
        )
        let agentID = string(payload, "agent_id", "agentId", "agent")
        let turnID = string(payload, "turn_id", "turnId", "generation_id", "generationId", "message_id", "messageId")
        let transcriptPath = string(payload, "transcript_path", "transcriptPath")
        let projectPath = string(payload, "cwd", "project_path", "projectPath")
            ?? (payload["workspace_roots"] as? [String])?.first
        let receivedAt = ISO8601DateFormatter().date(from: root["received_at"] as? String ?? "") ?? Date()
        let directResponse = string(
            payload,
            "last_assistant_message", "lastAssistantMessage", "prompt_response", "promptResponse", "response", "text"
        )
        let response = directResponse ?? transcriptPath.flatMap(lastAssistantResponse(at:))
        let directUserPrompt = string(
            payload,
            "user_prompt", "userPrompt", "prompt", "question", "request"
        )
        let userPrompt = sanitizedUserPrompt(directUserPrompt)
            ?? transcriptPath.flatMap { lastUserPrompt(at: $0, provider: provider) }
        let notificationType = string(payload, "notification_type", "notificationType")
        let toolName = string(payload, "tool_name", "toolName")
        let normalizedEvent = normalized(eventName)
        let normalizedNotification = normalized(notificationType ?? "")

        let kind: AgentEventKind
        switch normalizedEvent {
        case "afteragent", "afteragentresponse", "agentstop", "responsecompleted", "sessionidle":
            kind = .responseCompleted
        case "stop":
            if provider == .cursor, response == nil {
                let status = normalized(string(payload, "status") ?? "")
                kind = status == "error" ? .failed : .ignored
            } else {
                kind = .responseCompleted
            }
        case "permissionrequest", "permissionasked":
            kind = .approvalRequired
        case "inputrequired":
            kind = .inputRequired
        case "pretooluse":
            if toolName?.lowercased().contains("request_user_input") == true
                || (root["event"] as? String)?.lowercased() == "input-request" {
                kind = .inputRequired
            } else {
                kind = .ignored
            }
        case "notification":
            if ["permissionprompt", "toolpermission"].contains(normalizedNotification) {
                kind = .approvalRequired
            } else if ["idleprompt", "agentneedsinput", "elicitationdialog"].contains(normalizedNotification) {
                kind = .inputRequired
            } else if ["agentcompleted", "idle"].contains(normalizedNotification) {
                kind = .responseCompleted
            } else {
                kind = .ignored
            }
        case "sessionstart":
            kind = .sessionStarted
        case "stopfailure", "erroroccurred", "sessionerror", "agentfailed":
            kind = .failed
        default:
            kind = .ignored
        }

        let providerName = provider.displayName
        let projectName = projectPath.map { URL(fileURLWithPath: $0).lastPathComponent }
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
            message = string(payload, "error_details", "errorDetails", "error_message", "errorMessage")
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
            userPrompt: userPrompt,
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

    private static func normalized(_ value: String) -> String {
        String(value.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }

    private static func lastAssistantResponse(at path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? NSNumber,
            size.int64Value <= 50 * 1_024 * 1_024,
            let data = try? Data(contentsOf: url)
        else { return nil }

        if let object = try? JSONSerialization.jsonObject(with: data) {
            return assistantTexts(in: object).last?.trimmedNonempty
        }

        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard
                let lineData = String(line).data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: lineData),
                let response = assistantTexts(in: object).last?.trimmedNonempty
            else { continue }
            return response
        }
        return nil
    }

    private static func lastUserPrompt(at path: String, provider: ItemSource) -> String? {
        let url = URL(fileURLWithPath: path)
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? NSNumber,
            size.int64Value <= 50 * 1_024 * 1_024,
            let data = try? Data(contentsOf: url)
        else { return nil }

        if let object = try? JSONSerialization.jsonObject(with: data) {
            return userPrompts(in: object, provider: provider).last
        }

        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard
                let lineData = String(line).data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: lineData),
                let prompt = userPrompts(in: object, provider: provider).last
            else { continue }
            return prompt
        }
        return nil
    }

    private static func userPrompts(in value: Any, provider: ItemSource) -> [String] {
        if let array = value as? [Any] {
            return array.flatMap { userPrompts(in: $0, provider: provider) }
        }
        guard let object = value as? [String: Any] else { return [] }

        if provider == .codex,
           normalized(string(object, "type") ?? "") == "eventmsg",
           let payload = object["payload"] as? [String: Any],
           normalized(string(payload, "type") ?? "") == "usermessage",
           let prompt = sanitizedUserPrompt(string(payload, "message")) {
            return [prompt]
        }

        if provider == .claude,
           normalized(string(object, "type") ?? "") == "user",
           object["isMeta"] as? Bool != true,
           object["isSidechain"] as? Bool != true,
           let message = object["message"] as? [String: Any],
           normalized(string(message, "role") ?? "") == "user",
           let prompt = sanitizedUserPrompt(textContent(in: message)) {
            return [prompt]
        }

        guard provider != .codex, provider != .claude else { return [] }
        let role = normalized(string(object, "role", "author", "speaker") ?? "")
        if ["user", "human"].contains(role),
           let prompt = sanitizedUserPrompt(textContent(in: object)) {
            return [prompt]
        }
        return object.values.flatMap { userPrompts(in: $0, provider: provider) }
    }

    private static func assistantTexts(in value: Any) -> [String] {
        if let array = value as? [Any] {
            return array.flatMap(assistantTexts(in:))
        }
        guard let object = value as? [String: Any] else { return [] }

        let role = normalized(string(object, "role", "author", "speaker") ?? "")
        let type = normalized(string(object, "type", "kind") ?? "")
        let isAssistant = role == "assistant" || role == "model"
            || (role.isEmpty && type.contains("assistant") && !type.contains("tool"))
        if isAssistant, let text = textContent(in: object), !text.isEmpty {
            return [text]
        }
        return object.values.flatMap(assistantTexts(in:))
    }

    private static func textContent(in object: [String: Any]) -> String? {
        for key in ["content", "text", "message", "output", "response"] {
            if let value = object[key] as? String, !value.isEmpty { return value }
            if let parts = object[key] as? [Any] {
                let text = parts.compactMap { part -> String? in
                    if let value = part as? String { return value }
                    guard let block = part as? [String: Any] else { return nil }
                    let type = normalized(string(block, "type", "kind") ?? "text")
                    guard ["text", "outputtext", "markdown"].contains(type) else { return nil }
                    return string(block, "text", "content", "value")
                }.joined(separator: "\n\n")
                if !text.isEmpty { return text }
            }
        }
        return nil
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
}

private extension String {
    var trimmedNonempty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var firstNonemptyLine: String? {
        split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
            .map { String($0.prefix(180)) }
    }
}
