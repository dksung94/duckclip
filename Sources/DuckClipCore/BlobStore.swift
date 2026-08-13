import Foundation

public final class BlobStore: @unchecked Sendable {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    @discardableResult
    public func store(_ data: Data, fileExtension: String) throws -> URL {
        let hash = ContentHasher.sha256(data)
        let url = directory.appendingPathComponent(hash).appendingPathExtension(fileExtension)
        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
        }
        return url
    }

    public func deleteIfPresent(path: String?) {
        guard let path, path.hasPrefix(directory.path) else { return }
        try? FileManager.default.removeItem(atPath: path)
    }
}
