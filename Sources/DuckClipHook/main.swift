import Foundation

enum HookError: LocalizedError {
    case invalidArguments
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            "Usage: duckclip-hook capture --managed-by duckclip --schema 1 --provider <claude|codex> --event <event>"
        case .invalidJSON: "Hook input was not valid JSON."
        }
    }
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let provider: String
    let event: String
    if arguments.first == "capture" {
        guard
            value(after: "--managed-by", in: arguments) == "duckclip",
            value(after: "--schema", in: arguments) == "1",
            let parsedProvider = value(after: "--provider", in: arguments),
            let parsedEvent = value(after: "--event", in: arguments)
        else { throw HookError.invalidArguments }
        provider = parsedProvider
        event = parsedEvent
    } else {
        // Backward compatible with configurations created before the managed marker.
        guard arguments.count >= 2 else { throw HookError.invalidArguments }
        provider = arguments[0]
        event = arguments[1]
    }
    guard ["claude", "codex"].contains(provider) else { throw HookError.invalidArguments }

    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard let payload = try JSONSerialization.jsonObject(with: input) as? [String: Any] else {
        throw HookError.invalidJSON
    }

    let support = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
    )
    let root = support.appendingPathComponent("DuckClip", isDirectory: true)
    let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: inbox.path)

    let envelope: [String: Any] = [
        "provider": provider,
        "event": event,
        "received_at": ISO8601DateFormatter().string(from: Date()),
        "payload": payload
    ]
    let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys, .withoutEscapingSlashes])
    let target = inbox.appendingPathComponent("\(Date().timeIntervalSince1970)-\(UUID().uuidString).json")
    try data.write(to: target, options: .atomic)

    if provider == "codex" {
        FileHandle.standardOutput.write(Data("{}\n".utf8))
    }
    exit(EXIT_SUCCESS)
} catch {
    FileHandle.standardError.write(Data("duckclip-hook: \(error.localizedDescription)\n".utf8))
    // A capture failure must never block or change the agent's lifecycle.
    FileHandle.standardOutput.write(Data("{}\n".utf8))
    exit(EXIT_SUCCESS)
}

func value(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}
