import Foundation

public struct AppPaths: Sendable {
    public let root: URL
    public let database: URL
    public let inbox: URL
    public let blobs: URL

    public init(root: URL? = nil) throws {
        let resolvedRoot: URL
        if let root {
            resolvedRoot = root
        } else {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            resolvedRoot = support.appendingPathComponent("DuckClip", isDirectory: true)
        }

        self.root = resolvedRoot
        self.database = resolvedRoot.appendingPathComponent("duckclip.sqlite3")
        self.inbox = resolvedRoot.appendingPathComponent("Inbox", isDirectory: true)
        self.blobs = resolvedRoot.appendingPathComponent("Blobs", isDirectory: true)

        try FileManager.default.createDirectory(at: resolvedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: resolvedRoot.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: inbox.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blobs.path)
    }
}
