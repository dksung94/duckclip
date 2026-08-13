import AppKit
import ApplicationServices
import Foundation

@MainActor
public final class PasteCoordinator {
    public enum PasteError: LocalizedError {
        case missingPayload
        case unsupportedImage
        case accessibilityPermissionRequired
        case targetUnavailable

        public var errorDescription: String? {
            switch self {
            case .missingPayload:
                String(localized: "paste.error.missing_payload", defaultValue: "The original clipboard payload is no longer available.")
            case .unsupportedImage:
                String(localized: "paste.error.unsupported_image", defaultValue: "The stored image could not be decoded.")
            case .accessibilityPermissionRequired:
                String(localized: "paste.error.accessibility", defaultValue: "Enable DuckClip in System Settings → Privacy & Security → Accessibility to paste automatically.")
            case .targetUnavailable:
                String(localized: "paste.error.target_unavailable", defaultValue: "The destination app is no longer available. The item was copied instead.")
            }
        }
    }

    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public func copy(_ item: ClipItem) throws {
        pasteboard.clearContents()
        switch item.kind {
        case .text, .url, .agentResponse:
            pasteboard.setString(item.text, forType: .string)
        case .file:
            let urls = item.text
                .components(separatedBy: .newlines)
                .filter { !$0.isEmpty }
                .map { URL(fileURLWithPath: $0) }
            guard !urls.isEmpty else { throw PasteError.missingPayload }
            pasteboard.writeObjects(urls as [NSURL])
        case .image:
            guard let path = item.payloadPath, let image = NSImage(contentsOfFile: path) else {
                throw PasteError.missingPayload
            }
            pasteboard.writeObjects([image])
        }
    }

    public func paste(_ item: ClipItem, targetApplication: NSRunningApplication?) throws {
        guard AXIsProcessTrusted() else {
            requestAccessibilityPermission()
            throw PasteError.accessibilityPermissionRequired
        }
        try copy(item)
        guard let targetApplication, !targetApplication.isTerminated, targetApplication.activate() else {
            throw PasteError.targetUnavailable
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            let source = CGEventSource(stateID: .hidSystemState)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }

    @discardableResult
    public func requestAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }
}
