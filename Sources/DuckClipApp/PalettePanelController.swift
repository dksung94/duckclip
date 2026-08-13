import AppKit
import SwiftUI

@MainActor
final class PalettePanelController {
    private let model: AppModel
    private let panel: NSPanel
    private var targetApplication: NSRunningApplication?

    init(model: AppModel) {
        self.model = model
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 590),
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
        panel.minSize = NSSize(width: 680, height: 420)

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
    }

    func toggle(selecting itemID: String? = nil) {
        if panel.isVisible && itemID == nil {
            panel.orderOut(nil)
            return
        }
        show(selecting: itemID)
    }

    func show(selecting itemID: String? = nil) {
        let duckBundleID = Bundle.main.bundleIdentifier
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.bundleIdentifier != duckBundleID {
            targetApplication = frontmost
        }
        model.refreshIntegrationStatus()
        model.refreshAccessibilityPermission()
        model.reload()
        if let itemID { model.selectedItemID = itemID }
        panel.center()
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
}
