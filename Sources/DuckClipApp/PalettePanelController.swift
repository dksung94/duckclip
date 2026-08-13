import AppKit
import SwiftUI

@MainActor
final class PalettePanelController {
    private let model: AppModel
    private let panel: NSPanel
    private var targetApplication: NSRunningApplication?
    private var lastExternalApplication: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?
    private var needsInitialPosition = true

    init(model: AppModel) {
        self.model = model
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 650),
            styleMask: [.titled, .fullSizeContentView, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "DuckClip"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 900, height: 480)
        needsInitialPosition = !panel.setFrameUsingName("DuckClipPalette")
        panel.setFrameAutosaveName("DuckClipPalette")

        panel.contentView = NSHostingView(rootView: PaletteView(
            model: model,
            onActivate: { [weak self] item in
                guard let self else { return }
                if self.model.settings.autoPaste {
                    if self.model.paste(item, target: self.targetApplication) {
                        self.panel.orderOut(nil)
                    }
                } else if self.model.copy(item) {
                    self.panel.orderOut(nil)
                }
            },
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

    func toggle(selecting itemID: String? = nil) {
        if panel.isVisible && itemID == nil {
            hide()
            return
        }
        show(selecting: itemID)
    }

    func hide() {
        panel.orderOut(nil)
    }

    func show(selecting itemID: String? = nil) {
        let duckBundleID = Bundle.main.bundleIdentifier
        let frontmost = NSWorkspace.shared.frontmostApplication
        let currentExternal = frontmost.flatMap { app in
            app.bundleIdentifier != duckBundleID && !app.isTerminated ? app : nil
        }
        let fallback = lastExternalApplication.flatMap { !$0.isTerminated ? $0 : nil }
        targetApplication = currentExternal ?? fallback
        model.pasteTargetName = targetApplication?.localizedName
        model.refreshIntegrationStatus()
        model.refreshAccessibilityPermission()
        model.reload()
        if let itemID { model.selectedItemID = itemID }
        if needsInitialPosition {
            positionOnActiveScreen()
            needsInitialPosition = false
        }
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
            y: visibleFrame.midY - panel.frame.height / 2
        )
        panel.setFrameOrigin(origin)
    }
}
