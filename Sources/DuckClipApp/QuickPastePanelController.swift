import AppKit
import SwiftUI

@MainActor
final class QuickPastePanelState: ObservableObject {
    @Published var targetName: String?
    @Published var refreshToken = UUID()
}

@MainActor
final class QuickPastePanelController {
    private let model: AppModel
    private let state = QuickPastePanelState()
    private let panel: NSPanel
    private var targetApplication: NSRunningApplication?
    private var lastExternalApplication: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?

    init(model: AppModel) {
        self.model = model
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 510),
            styleMask: [.titled, .fullSizeContentView, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = String(localized: "Quick Paste")
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true

        panel.contentView = NSHostingView(rootView: QuickPasteView(
            model: model,
            state: state,
            onPaste: { [weak self] item in
                guard let self else { return }
                if self.model.paste(item, target: self.targetApplication) {
                    self.panel.orderOut(nil)
                }
            },
            onCopy: { [weak self] item in
                guard let self else { return }
                if self.model.copy(item) {
                    self.panel.orderOut(nil)
                }
            },
            onDismiss: { [weak panel] in panel?.orderOut(nil) }
        ))

        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != Bundle.main.bundleIdentifier,
           !frontmost.isTerminated {
            lastExternalApplication = frontmost
        }

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in
                guard let self, app.bundleIdentifier != Bundle.main.bundleIdentifier, !app.isTerminated else { return }
                self.lastExternalApplication = app
            }
        }
    }

    deinit {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    func toggle() {
        if panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func show() {
        let bundleID = Bundle.main.bundleIdentifier
        let frontmost = NSWorkspace.shared.frontmostApplication
        let currentExternal = frontmost.flatMap { app in
            app.bundleIdentifier != bundleID && !app.isTerminated ? app : nil
        }
        let fallback = lastExternalApplication.flatMap { !$0.isTerminated ? $0 : nil }
        targetApplication = currentExternal ?? fallback
        state.targetName = targetApplication?.localizedName
        state.refreshToken = UUID()
        model.refreshAccessibilityPermission()
        positionOnActiveScreen()
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func positionOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else {
            panel.center()
            return
        }
        let origin = NSPoint(
            x: visibleFrame.midX - panel.frame.width / 2,
            y: visibleFrame.maxY - panel.frame.height - 72
        )
        panel.setFrameOrigin(origin)
    }
}
