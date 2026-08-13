import AppKit
import Foundation

@MainActor
public final class ClipboardMonitor {
    public var onCapture: ((ClipItem) -> Void)?

    private let pasteboard: NSPasteboard
    private let blobStore: BlobStore
    private let settings: DuckClipSettings
    private var timer: Timer?
    private var lastChangeCount: Int

    private let concealedTypes = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        NSPasteboard.PasteboardType("com.agilebits.onepassword")
    ]

    public init(
        pasteboard: NSPasteboard = .general,
        blobStore: BlobStore,
        settings: DuckClipSettings
    ) {
        self.pasteboard = pasteboard
        self.blobStore = blobStore
        self.settings = settings
        self.lastChangeCount = pasteboard.changeCount
    }

    public func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func acknowledgeCurrentContents() {
        lastChangeCount = pasteboard.changeCount
    }

    private func poll() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard settings.captureEnabled else { return }
        guard !concealedTypes.contains(where: { pasteboard.availableType(from: [$0]) != nil }) else { return }

        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard bundleID != Bundle.main.bundleIdentifier else { return }
        guard bundleID.map({ !settings.excludedAppBundleIDs.contains($0) }) ?? true else { return }

        if let item = captureFileURLs(bundleID: bundleID) ?? captureImage(bundleID: bundleID) ?? captureText(bundleID: bundleID) {
            onCapture?(item)
        }
    }

    private func captureFileURLs(bundleID: String?) -> ClipItem? {
        guard let values = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !values.isEmpty else { return nil }

        let paths = values.map(\.path)
        let text = paths.joined(separator: "\n")
        return ClipItem(
            kind: .file,
            source: .clipboard,
            text: text,
            contentHash: ContentHasher.sha256(text),
            sourceAppBundleID: bundleID,
            payloadPath: paths.first
        )
    }

    private func captureImage(bundleID: String?) -> ClipItem? {
        let data: Data?
        let fileExtension: String
        if let png = pasteboard.data(forType: .png) {
            data = png
            fileExtension = "png"
        } else if let tiff = pasteboard.data(forType: .tiff) {
            data = tiff
            fileExtension = "tiff"
        } else {
            return nil
        }
        guard let data, let url = try? blobStore.store(data, fileExtension: fileExtension) else { return nil }
        let description = "Image \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))"
        return ClipItem(
            kind: .image,
            source: .clipboard,
            text: description,
            contentHash: ContentHasher.sha256(data),
            sourceAppBundleID: bundleID,
            payloadPath: url.path
        )
    }

    private func captureText(bundleID: String?) -> ClipItem? {
        guard let value = pasteboard.string(forType: .string), !value.isEmpty else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind: ItemKind
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
            kind = .url
        } else {
            kind = .text
        }
        return ClipItem(
            kind: kind,
            source: .clipboard,
            text: value,
            contentHash: ContentHasher.sha256(value),
            sourceAppBundleID: bundleID
        )
    }
}
