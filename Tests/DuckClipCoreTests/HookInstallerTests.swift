import Foundation
import XCTest
@testable import DuckClipCore

final class HookInstallerTests: XCTestCase {
    func testInstallerPreservesExistingHooksAndRemovesOnlyDuckClip() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DuckClipHookTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

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
        XCTAssertTrue(installer.status().claudeInstalled)
        XCTAssertTrue(installer.status().codexInstalled)

        let installedText = try String(contentsOf: claudeConfig, encoding: .utf8)
        XCTAssertTrue(installedText.contains("existing-hook"))
        XCTAssertTrue(installedText.contains("--managed-by duckclip"))
        XCTAssertTrue(installedText.contains("Library/Application Support/DuckClip/bin/duckclip-hook"))

        try installer.uninstall()
        let removedText = try String(contentsOf: claudeConfig, encoding: .utf8)
        XCTAssertTrue(removedText.contains("existing-hook"))
        XCTAssertTrue(removedText.contains("duckclip-hook-backup"))
        XCTAssertFalse(removedText.contains("--managed-by duckclip"))
    }
}
