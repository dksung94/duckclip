import AppKit
import DuckClipCore
import Foundation

enum AgentReplyLaunchError: LocalizedError {
    case sessionNotRunning(ItemSource)
    case terminalNotSupported(String)
    case deliveryFailed(String)

    var errorDescription: String? {
        switch self {
        case .sessionNotRunning(let provider):
            String(
                format: String(
                    localized: "reply.error.not_running",
                    defaultValue: "The %@ session is no longer running in a terminal."
                ),
                provider.displayName
            )
        case .terminalNotSupported(let tty):
            String(
                format: String(
                    localized: "reply.error.terminal_unsupported",
                    defaultValue: "The live session was found on %@, but DuckClip could not find its tmux pane, cmux, Terminal, or iTerm surface."
                ),
                tty
            )
        case .deliveryFailed(let message):
            String(
                format: String(
                    localized: "reply.error.delivery",
                    defaultValue: "The reply could not be sent to the live terminal session: %@"
                ),
                message
            )
        }
    }
}

@MainActor
struct AgentReplyLauncher {
    func unavailableReason(for item: ClipItem) -> String? {
        do {
            _ = try AgentSessionReply.request(
                provider: item.source,
                sessionID: item.sessionID,
                prompt: "reply"
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func send(item: ClipItem, prompt: String) async throws {
        let request = try AgentSessionReply.request(
            provider: item.source,
            sessionID: item.sessionID,
            prompt: prompt
        )
        let iTermRunning = !NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.googlecode.iterm2"
        ).isEmpty
        let terminalRunning = !NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.Terminal"
        ).isEmpty
        try await Task.detached(priority: .userInitiated) {
            let session = try Self.locateLiveSession(for: request)
            try Self.deliver(
                request.prompt,
                to: session,
                provider: request.provider,
                iTermRunning: iTermRunning,
                terminalRunning: terminalRunning
            )
        }.value
    }

    private struct LiveSession: Sendable {
        let processID: Int32
        let processGroupID: Int32
        let foregroundProcessGroupID: Int32
        let tty: String
        let command: String

        var devicePath: String {
            tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
        }
    }

    private struct ProcessResult {
        let status: Int32
        let output: String
    }

    nonisolated private static func locateLiveSession(for request: AgentSessionReplyRequest) throws -> LiveSession {
        let openFiles = try run("/usr/sbin/lsof", arguments: ["-n", "-Fpcn"])
        let candidates = AgentSessionReply.processCandidates(
            fromOpenFileList: openFiles.output,
            sessionID: request.sessionID
        )
        for candidate in candidates {
            if let session = processDetails(processID: candidate.processID),
               session.processGroupID == session.foregroundProcessGroupID,
               AgentSessionReply.processCommand(session.command, matches: request.provider) {
                return session
            }
        }

        let processes = try run(
            "/bin/ps",
            arguments: ["-axo", "pid=,pgid=,tpgid=,tty=,command="]
        )
        for line in processes.output.split(whereSeparator: \.isNewline) {
            guard line.localizedCaseInsensitiveContains(request.sessionID),
                  let session = parseProcessLine(String(line)),
                  session.processGroupID == session.foregroundProcessGroupID,
                  AgentSessionReply.processCommand(session.command, matches: request.provider)
            else { continue }
            return session
        }

        throw AgentReplyLaunchError.sessionNotRunning(request.provider)
    }

    nonisolated private static func processDetails(processID: Int32) -> LiveSession? {
        guard let result = try? run(
            "/bin/ps",
            arguments: ["-p", String(processID), "-o", "pid=,pgid=,tpgid=,tty=,command="]
        ), result.status == 0 else { return nil }
        return result.output
            .split(whereSeparator: \.isNewline)
            .first
            .flatMap { parseProcessLine(String($0)) }
    }

    nonisolated private static func parseProcessLine(_ line: String) -> LiveSession? {
        let fields = line.split(
            maxSplits: 4,
            omittingEmptySubsequences: true,
            whereSeparator: \.isWhitespace
        )
        guard fields.count == 5,
              let processID = Int32(fields[0]),
              let processGroupID = Int32(fields[1]),
              let foregroundProcessGroupID = Int32(fields[2]),
              fields[3] != "??"
        else { return nil }
        return LiveSession(
            processID: processID,
            processGroupID: processGroupID,
            foregroundProcessGroupID: foregroundProcessGroupID,
            tty: String(fields[3]),
            command: String(fields[4])
        )
    }

    nonisolated private static func deliver(
        _ prompt: String,
        to session: LiveSession,
        provider: ItemSource,
        iTermRunning: Bool,
        terminalRunning: Bool
    ) throws {
        guard let current = processDetails(processID: session.processID),
              current.processGroupID == session.processGroupID,
              current.tty == session.tty,
              current.processGroupID == current.foregroundProcessGroupID,
              current.command == session.command
        else {
            throw AgentReplyLaunchError.sessionNotRunning(provider)
        }

        let environment = processEnvironment(for: session)
        let tmuxExecutable = tmuxExecutable(fromProcessEnvironment: environment ?? "")
        let environmentTarget = environment.flatMap(AgentSessionReply.tmuxTarget(fromProcessEnvironment:))
        if let tmuxTarget = environmentTarget ?? tmuxTarget(
            matching: session,
            executable: tmuxExecutable
        ) {
            guard let tmuxExecutable else {
                throw AgentReplyLaunchError.deliveryFailed(
                    "tmux is running, but the tmux executable could not be found."
                )
            }
            try deliverToTmux(
                prompt,
                target: tmuxTarget,
                session: session,
                executable: tmuxExecutable
            )
            return
        }

        var errors: [String] = []
        if let environment,
           let surfaceID = AgentSessionReply.cmuxSurfaceID(fromProcessEnvironment: environment) {
            do {
                try deliverToCmux(prompt, surfaceID: surfaceID)
                return
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        if iTermRunning {
            let result = try runAppleScript(iTermScript, arguments: [session.devicePath, prompt])
            if result.status == 0, result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "sent" {
                return
            }
            if result.status != 0 { errors.append(result.output) }
        }
        if terminalRunning {
            let result = try runAppleScript(terminalScript, arguments: [session.devicePath, prompt])
            if result.status == 0, result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "sent" {
                return
            }
            if result.status != 0 { errors.append(result.output) }
        }
        if let message = errors.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            throw AgentReplyLaunchError.deliveryFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        throw AgentReplyLaunchError.terminalNotSupported(session.devicePath)
    }

    nonisolated private static func processEnvironment(for session: LiveSession) -> String? {
        guard let environment = try? run(
            "/bin/ps",
            arguments: ["-Eww", "-p", String(session.processID), "-o", "command="]
        ), environment.status == 0
        else { return nil }
        return environment.output
    }

    nonisolated private static func deliverToTmux(
        _ prompt: String,
        target: AgentSessionTmuxTarget,
        session: LiveSession,
        executable: String
    ) throws {
        let paneList = try run(
            executable,
            arguments: [
                "-S", target.socketPath,
                "list-panes", "-a",
                "-F", "#{pane_id}\t#{pane_tty}"
            ]
        )
        guard paneList.status == 0 else {
            throw AgentReplyLaunchError.deliveryFailed(
                paneList.output.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        guard AgentSessionReply.tmuxPaneIsLive(
            target,
            devicePath: session.devicePath,
            inPaneList: paneList.output
        ) else {
            throw AgentReplyLaunchError.deliveryFailed(
                "The original tmux pane is no longer available."
            )
        }

        let textResult = try run(
            executable,
            arguments: [
                "-S", target.socketPath,
                "send-keys", "-t", target.paneID,
                "-l", "--", prompt
            ]
        )
        guard textResult.status == 0 else {
            throw AgentReplyLaunchError.deliveryFailed(
                textResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let enterResult = try run(
            executable,
            arguments: [
                "-S", target.socketPath,
                "send-keys", "-t", target.paneID,
                "Enter"
            ]
        )
        guard enterResult.status == 0 else {
            throw AgentReplyLaunchError.deliveryFailed(
                enterResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    nonisolated private static func tmuxTarget(
        matching session: LiveSession,
        executable: String?
    ) -> AgentSessionTmuxTarget? {
        guard let executable else { return nil }
        let socketDirectory = "/private/tmp/tmux-\(getuid())"
        guard let socketNames = try? FileManager.default.contentsOfDirectory(atPath: socketDirectory) else {
            return nil
        }

        for socketName in socketNames.sorted() {
            let socketPath = URL(fileURLWithPath: socketDirectory)
                .appendingPathComponent(socketName)
                .path
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: socketPath),
                  attributes[.type] as? FileAttributeType == .typeSocket,
                  let panes = try? run(
                    executable,
                    arguments: [
                        "-S", socketPath,
                        "list-panes", "-a",
                        "-F", "#{socket_path}\t#{pane_id}\t#{pane_tty}"
                    ]
                  ),
                  panes.status == 0,
                  let target = AgentSessionReply.tmuxTarget(
                    matchingDevicePath: session.devicePath,
                    inPaneList: panes.output
                  )
            else { continue }
            return target
        }
        return nil
    }

    nonisolated private static func tmuxExecutable(fromProcessEnvironment environment: String) -> String? {
        let knownPaths = [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/opt/local/bin/tmux",
            "/usr/bin/tmux"
        ]
        var visited = Set<String>()
        let candidates = AgentSessionReply.executableSearchPaths(
            named: "tmux",
            fromProcessEnvironment: environment
        ) + knownPaths
        return candidates.first { path in
            visited.insert(path).inserted && FileManager.default.isExecutableFile(atPath: path)
        }
    }

    nonisolated private static func deliverToCmux(
        _ prompt: String,
        surfaceID: String
    ) throws {
        let result = try runAppleScript(cmuxInputScript, arguments: [surfaceID, prompt])
        guard result.status == 0,
              result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "sent"
        else {
            throw AgentReplyLaunchError.deliveryFailed(result.output)
        }
    }

    nonisolated private static func runAppleScript(_ source: String, arguments: [String]) throws -> ProcessResult {
        try run("/usr/bin/osascript", arguments: ["-e", source] + arguments)
    }

    nonisolated private static func run(_ executable: String, arguments: [String]) throws -> ProcessResult {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            throw AgentReplyLaunchError.deliveryFailed(error.localizedDescription)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessResult(
            status: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self)
        )
    }

    nonisolated private static let iTermScript = """
    on run argv
        set targetTTY to item 1 of argv
        set replyText to item 2 of argv
        tell application id "com.googlecode.iterm2"
            repeat with targetWindow in windows
                repeat with targetTab in tabs of targetWindow
                    repeat with targetSession in sessions of targetTab
                        if (tty of targetSession as text) is targetTTY then
                            select targetSession
                            activate
                            tell targetSession to write text replyText newline yes
                            return "sent"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "not-found"
    end run
    """

    nonisolated private static let terminalScript = """
    on run argv
        set targetTTY to item 1 of argv
        set replyText to item 2 of argv
        tell application id "com.apple.Terminal"
            repeat with targetWindow in windows
                repeat with targetTab in tabs of targetWindow
                    if (tty of targetTab as text) is targetTTY then
                        set selected of targetTab to true
                        set index of targetWindow to 1
                        activate
                        do script replyText in targetTab
                        return "sent"
                    end if
                end repeat
            end repeat
        end tell
        return "not-found"
    end run
    """

    nonisolated private static let cmuxInputScript = """
    on run argv
        set surfaceID to item 1 of argv
        set replyText to item 2 of argv
        tell application id "com.cmuxterm.app"
            repeat with targetTerminal in terminals
                if (id of targetTerminal as text) is surfaceID then
                    input text replyText to targetTerminal
                    perform action "text:\\\\x0d" on targetTerminal
                    return "sent"
                end if
            end repeat
        end tell
        return "not-found"
    end run
    """

}
