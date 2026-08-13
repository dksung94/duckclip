import AppKit
import Foundation

public enum ClipboardCaptureStatus: Sendable, Equatable {
    case paused
    case protectedContent
    case excludedApplication(String?)
    case unsupportedContent
    case imageStorageFailed(String)
}

@MainActor
public final class ClipboardMonitor {
    public var onCapture: ((ClipItem) -> Void)?
    public var onStatus: ((ClipboardCaptureStatus) -> Void)?

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
        guard settings.captureEnabled else {
            onStatus?(.paused)
            return
        }
        guard !concealedTypes.contains(where: { pasteboard.availableType(from: [$0]) != nil }) else {
            onStatus?(.protectedContent)
            return
        }

        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard bundleID.map({ !settings.excludedAppBundleIDs.contains($0) }) ?? true else {
            onStatus?(.excludedApplication(bundleID))
            return
        }

        if let item = captureFileURLs(bundleID: bundleID) {
            onCapture?(item)
            return
        }
        if pasteboard.data(forType: .png) != nil || pasteboard.data(forType: .tiff) != nil {
            do {
                if let item = try captureImage(bundleID: bundleID) {
                    onCapture?(item)
                }
            } catch {
                onStatus?(.imageStorageFailed(error.localizedDescription))
            }
            return
        }
        if let item = captureText(bundleID: bundleID) {
            onCapture?(item)
        } else {
            onStatus?(.unsupportedContent)
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

    private func captureImage(bundleID: String?) throws -> ClipItem? {
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
        guard let data else { return nil }
        let url = try blobStore.store(data, fileExtension: fileExtension)
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
