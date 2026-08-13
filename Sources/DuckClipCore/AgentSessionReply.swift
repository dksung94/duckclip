import Foundation

public struct AgentSessionReplyRequest: Equatable, Sendable {
    public let provider: ItemSource
    public let sessionID: String
    public let prompt: String

    public init(provider: ItemSource, sessionID: String, prompt: String) {
        self.provider = provider
        self.sessionID = sessionID
        self.prompt = prompt
    }
}

public struct AgentSessionProcessCandidate: Equatable, Sendable {
    public let processID: Int32
    public let command: String

    public init(processID: Int32, command: String) {
        self.processID = processID
        self.command = command
    }
}

public struct AgentSessionTmuxTarget: Equatable, Sendable {
    public let socketPath: String
    public let paneID: String

    public init(socketPath: String, paneID: String) {
        self.socketPath = socketPath
        self.paneID = paneID
    }
}

public enum AgentSessionReplyError: LocalizedError, Equatable, Sendable {
    case missingSessionID
    case emptyPrompt
    case unsupportedProvider

    public var errorDescription: String? {
        switch self {
        case .missingSessionID:
            String(localized: "This response does not include a live session ID.")
        case .emptyPrompt:
            String(localized: "Enter a reply first.")
        case .unsupportedProvider:
            String(localized: "This source does not support session replies.")
        }
    }
}

public enum AgentSessionReply {
    public static func request(
        provider: ItemSource,
        sessionID: String?,
        prompt: String
    ) throws -> AgentSessionReplyRequest {
        guard provider.isAgent else { throw AgentSessionReplyError.unsupportedProvider }
        guard let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty
        else {
            throw AgentSessionReplyError.missingSessionID
        }
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw AgentSessionReplyError.emptyPrompt }
        return AgentSessionReplyRequest(provider: provider, sessionID: sessionID, prompt: prompt)
    }

    public static func processCandidates(
        fromOpenFileList output: String,
        sessionID: String
    ) -> [AgentSessionProcessCandidate] {
        var processID: Int32?
        var command = ""
        var matches: [AgentSessionProcessCandidate] = []
        var matchedProcessIDs = Set<Int32>()

        for line in output.split(whereSeparator: \.isNewline) {
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            switch field {
            case "p":
                processID = Int32(value)
                command = ""
            case "c":
                command = value
            case "n":
                guard value.localizedCaseInsensitiveContains(sessionID),
                      let processID,
                      matchedProcessIDs.insert(processID).inserted
                else { continue }
                matches.append(AgentSessionProcessCandidate(processID: processID, command: command))
            default:
                continue
            }
        }
        return matches
    }

    public static func processCommand(_ command: String, matches provider: ItemSource) -> Bool {
        let command = command.lowercased()
        return switch provider {
        case .claude: command.contains("claude")
        case .codex: command.contains("codex")
        case .gajae: command.contains("gjc") || command.contains("gajae")
        case .gemini: command.contains("gemini")
        case .copilot: command.contains("copilot")
        case .cursor: command.contains("cursor-agent")
        case .opencode: command.contains("opencode")
        case .clipboard: false
        }
    }

    public static func cmuxSurfaceID(fromProcessEnvironment output: String) -> String? {
        guard let value = environmentValue(named: "CMUX_SURFACE_ID", in: output) else { return nil }
        return UUID(uuidString: value) == nil ? nil : value
    }

    public static func tmuxTarget(fromProcessEnvironment output: String) -> AgentSessionTmuxTarget? {
        guard let rawTarget = environmentValue(named: "TMUX", in: output),
              let paneID = environmentValue(named: "TMUX_PANE", in: output),
              paneID.first == "%",
              !paneID.dropFirst().isEmpty,
              paneID.dropFirst().allSatisfy(\.isNumber)
        else { return nil }

        let components = rawTarget.split(separator: ",", omittingEmptySubsequences: false)
        guard components.count >= 3,
              Int32(components[components.count - 2]) != nil,
              Int(components[components.count - 1]) != nil
        else { return nil }

        let socketPath = components.dropLast(2).joined(separator: ",")
        guard socketPath.hasPrefix("/"), !socketPath.contains("\0") else { return nil }
        return AgentSessionTmuxTarget(socketPath: socketPath, paneID: paneID)
    }

    public static func tmuxPaneIsLive(
        _ target: AgentSessionTmuxTarget,
        devicePath: String,
        inPaneList output: String
    ) -> Bool {
        output.split(whereSeparator: \.isNewline).contains { line in
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            return fields.count == 2
                && fields[0] == target.paneID
                && fields[1] == devicePath
        }
    }

    public static func tmuxTarget(
        matchingDevicePath devicePath: String,
        inPaneList output: String
    ) -> AgentSessionTmuxTarget? {
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3,
                  fields[2] == devicePath,
                  fields[0].hasPrefix("/"),
                  fields[1].first == "%",
                  !fields[1].dropFirst().isEmpty,
                  fields[1].dropFirst().allSatisfy(\.isNumber)
            else { continue }
            return AgentSessionTmuxTarget(socketPath: String(fields[0]), paneID: String(fields[1]))
        }
        return nil
    }

    public static func executableSearchPaths(
        named executable: String,
        fromProcessEnvironment output: String
    ) -> [String] {
        guard !executable.isEmpty,
              !executable.contains("/"),
              let path = environmentValue(named: "PATH", in: output)
        else { return [] }
        return path
            .split(separator: ":", omittingEmptySubsequences: true)
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent(executable).path }
    }

    private static func environmentValue(named name: String, in output: String) -> String? {
        let prefix = "\(name)="
        return output
            .split(whereSeparator: \.isWhitespace)
            .first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
    }
}
