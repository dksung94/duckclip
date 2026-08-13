import DuckClipCore
import Foundation

enum ControlError: LocalizedError {
    case usage
    case missingHelper(URL)

    var errorDescription: String? {
        switch self {
        case .usage:
            "Usage: duckclipctl <install|uninstall|status|test claude|test codex> [--helper /path/to/duckclip-hook]"
        case .missingHelper(let url):
            "duckclip-hook is not executable at \(url.path)"
        }
    }
}

func printStatus(_ status: HookInstallationStatus) {
    for provider in [status.claude, status.codex] {
        let state = provider.installed ? "ready" : "needs setup"
        print("\(provider.provider.displayName): \(state)")
        if !provider.helperExecutable { print("  helper: missing or not executable") }
        if !provider.missingEvents.isEmpty { print("  missing events: \(provider.missingEvents.joined(separator: ", "))") }
    }
    print("Helper: \(status.managedHelperPath)")
}

func helperURL(arguments: [String]) throws -> URL {
    if let flagIndex = arguments.firstIndex(of: "--helper"), arguments.indices.contains(flagIndex + 1) {
        return URL(fileURLWithPath: NSString(string: arguments[flagIndex + 1]).expandingTildeInPath)
    }
    let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    return executable.deletingLastPathComponent().appendingPathComponent("duckclip-hook")
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else { throw ControlError.usage }
    let helper = try helperURL(arguments: arguments)
    let installer = HookInstaller(helperURL: helper)

    switch command {
    case "install":
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw ControlError.missingHelper(helper)
        }
        try installer.install()
        printStatus(installer.status())
    case "uninstall":
        try installer.uninstall()
        print("DuckClip integrations removed")
    case "status":
        printStatus(installer.status())
    case "test":
        guard arguments.count >= 2, let provider = ItemSource(rawValue: arguments[1]) else {
            throw ControlError.usage
        }
        try installer.runSmokeTest(provider: provider)
        print("\(provider.displayName) test event sent")
    default:
        throw ControlError.usage
    }
} catch {
    FileHandle.standardError.write(Data("duckclipctl: \(error.localizedDescription)\n".utf8))
    exit(EXIT_FAILURE)
}
