import Testing
@testable import DuckClipCore

@Suite struct AgentSessionReplyTests {
    @Test func validatesLiveSessionReply() throws {
        let request = try AgentSessionReply.request(
            provider: .codex,
            sessionID: " session-42 ",
            prompt: " Please run the focused tests. \n"
        )
        #expect(request.provider == .codex)
        #expect(request.sessionID == "session-42")
        #expect(request.prompt == "Please run the focused tests.")
    }

    @Test func findsTheProcessThatOwnsTheSessionFile() {
        let output = """
        p10760
        ccodex
        n/Users/example/.codex/sessions/rollout-session-42.jsonl
        n/Users/example/project/file.swift
        p22000
        cclaude
        n/Users/example/.claude/projects/other-session.jsonl
        p33000
        ccodex
        n/Users/example/.codex/sessions/rollout-session-42.jsonl
        """
        #expect(
            AgentSessionReply.processCandidates(fromOpenFileList: output, sessionID: "session-42") == [
                AgentSessionProcessCandidate(processID: 10760, command: "codex"),
                AgentSessionProcessCandidate(processID: 33000, command: "codex")
            ]
        )
    }

    @Test func recognizesProviderProcesses() {
        #expect(AgentSessionReply.processCommand("/opt/homebrew/bin/codex --search", matches: .codex))
        #expect(AgentSessionReply.processCommand("/Users/me/.bun/bin/claude", matches: .claude))
        #expect(AgentSessionReply.processCommand("cursor-agent --resume=123", matches: .cursor))
        #expect(!AgentSessionReply.processCommand("/bin/zsh", matches: .codex))
    }

    @Test func readsCmuxSurfaceFromProcessEnvironment() {
        let environment = "codex --search HOME=/Users/test CMUX_SURFACE_ID=9413C564-110A-4AB9-8B80-4792438B47CD PATH=/usr/bin"
        #expect(
            AgentSessionReply.cmuxSurfaceID(fromProcessEnvironment: environment)
                == "9413C564-110A-4AB9-8B80-4792438B47CD"
        )
        #expect(AgentSessionReply.cmuxSurfaceID(fromProcessEnvironment: "CMUX_SURFACE_ID=invalid") == nil)
        #expect(AgentSessionReply.cmuxSurfaceID(fromProcessEnvironment: "HOME=/Users/test") == nil)
    }

    @Test func readsExactTmuxPaneFromProcessEnvironment() {
        let environment = """
        codex --search HOME=/Users/test TMUX=/private/tmp/tmux-501/default,9182,0 TMUX_PANE=%12 PATH=/opt/homebrew/bin:/usr/bin
        """
        #expect(
            AgentSessionReply.tmuxTarget(fromProcessEnvironment: environment) == AgentSessionTmuxTarget(
                socketPath: "/private/tmp/tmux-501/default",
                paneID: "%12"
            )
        )

        let socketWithComma = "TMUX=/tmp/duckclip,local/default,42,1 TMUX_PANE=%3"
        #expect(
            AgentSessionReply.tmuxTarget(fromProcessEnvironment: socketWithComma) == AgentSessionTmuxTarget(
                socketPath: "/tmp/duckclip,local/default",
                paneID: "%3"
            )
        )
    }

    @Test func rejectsMalformedTmuxTargets() {
        #expect(AgentSessionReply.tmuxTarget(fromProcessEnvironment: "TMUX=/tmp/default,42,0") == nil)
        #expect(AgentSessionReply.tmuxTarget(fromProcessEnvironment: "TMUX=/tmp/default,42,0 TMUX_PANE=12") == nil)
        #expect(AgentSessionReply.tmuxTarget(fromProcessEnvironment: "TMUX=relative,42,0 TMUX_PANE=%1") == nil)
        #expect(AgentSessionReply.tmuxTarget(fromProcessEnvironment: "TMUX=/tmp/default,pid,0 TMUX_PANE=%1") == nil)
    }

    @Test func validatesTmuxPaneAgainstItsTTY() {
        let target = AgentSessionTmuxTarget(socketPath: "/tmp/tmux/default", paneID: "%12")
        let panes = """
        %3\t/dev/ttys003
        %12\t/dev/ttys020
        """
        #expect(AgentSessionReply.tmuxPaneIsLive(target, devicePath: "/dev/ttys020", inPaneList: panes))
        #expect(!AgentSessionReply.tmuxPaneIsLive(target, devicePath: "/dev/ttys003", inPaneList: panes))
        #expect(!AgentSessionReply.tmuxPaneIsLive(
            AgentSessionTmuxTarget(socketPath: target.socketPath, paneID: "%1"),
            devicePath: "/dev/ttys020",
            inPaneList: panes
        ))
    }

    @Test func findsTmuxPaneByExactTTYWhenEnvironmentIsUnavailable() {
        let panes = """
        /private/tmp/tmux-501/work\t%3\t/dev/ttys003
        /private/tmp/tmux-501/default\t%12\t/dev/ttys020
        """
        #expect(
            AgentSessionReply.tmuxTarget(
                matchingDevicePath: "/dev/ttys020",
                inPaneList: panes
            ) == AgentSessionTmuxTarget(
                socketPath: "/private/tmp/tmux-501/default",
                paneID: "%12"
            )
        )
        #expect(AgentSessionReply.tmuxTarget(matchingDevicePath: "/dev/ttys02", inPaneList: panes) == nil)
        #expect(AgentSessionReply.tmuxTarget(
            matchingDevicePath: "/dev/ttys020",
            inPaneList: "relative\t%12\t/dev/ttys020"
        ) == nil)
    }

    @Test func readsTmuxExecutableCandidatesFromSessionPath() {
        let environment = "codex PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin HOME=/Users/test"
        #expect(AgentSessionReply.executableSearchPaths(named: "tmux", fromProcessEnvironment: environment) == [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/usr/bin/tmux"
        ])
        #expect(AgentSessionReply.executableSearchPaths(named: "../tmux", fromProcessEnvironment: environment).isEmpty)
    }

    @Test func rejectsMissingSessionAndEmptyPrompt() {
        #expect(throws: AgentSessionReplyError.missingSessionID) {
            try AgentSessionReply.request(provider: .codex, sessionID: nil, prompt: "Continue")
        }
        #expect(throws: AgentSessionReplyError.emptyPrompt) {
            try AgentSessionReply.request(provider: .claude, sessionID: "session", prompt: "  \n ")
        }
        #expect(throws: AgentSessionReplyError.unsupportedProvider) {
            try AgentSessionReply.request(provider: .clipboard, sessionID: "session", prompt: "Continue")
        }
    }
}
