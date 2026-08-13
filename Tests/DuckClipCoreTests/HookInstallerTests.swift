import Foundation
import Testing
@testable import DuckClipCore

@Suite struct HookInstallerTests {
    @Test func installerPreservesExistingHooksAndRemovesOnlyDuckClip() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DuckClipHookTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let helper = root.appendingPathComponent("duckclip-hook")
        try Data().write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        let claudeConfig = root.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: claudeConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing: [String: Any] = [
            "theme": "dark",
            "hooks": [
                "Stop": [["hooks": [
                    ["type": "command", "command": "/usr/bin/existing-hook"],
                    ["type": "command", "command": "/tmp/duckclip-hook-backup"]
                ]]]
            ]
        ]
        try JSONSerialization.data(withJSONObject: existing).write(to: claudeConfig)

        let installer = HookInstaller(home: root, helperURL: helper)
        try installer.install()
        #expect(installer.status().providers.count == ItemSource.agentSources.count)
        #expect(installer.status().providers.allSatisfy { $0.installed })

        let installedText = try String(contentsOf: claudeConfig, encoding: .utf8)
        #expect(installedText.contains("existing-hook"))
        #expect(installedText.contains("--managed-by duckclip"))
        #expect(installedText.contains("Library/Application Support/DuckClip/bin/duckclip-hook"))

        try installer.uninstall()
        let removedText = try String(contentsOf: claudeConfig, encoding: .utf8)
        #expect(removedText.contains("existing-hook"))
        #expect(removedText.contains("duckclip-hook-backup"))
        #expect(!removedText.contains("--managed-by duckclip"))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".copilot/hooks/duckclip.json").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".gjc/agent/extensions/duckclip/index.ts").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".config/opencode/plugins/duckclip.js").path))
    }
}
