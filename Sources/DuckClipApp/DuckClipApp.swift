import AppKit
import Combine
import DuckClipCore
import SwiftUI

@main
struct DuckClipApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("DuckClip", systemImage: "doc.on.clipboard.fill") {
            MenuBarContent(model: delegate.model, showPalette: delegate.showPalette)
        }

        Settings {
            SettingsView(model: delegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    private var panelController: PalettePanelController?
    private let hotKey = HotKeyManager()
    private var cancellables: Set<AnyCancellable> = []

    override init() {
        do {
            model = try AppModel()
        } catch {
            fatalError("DuckClip could not start: \(error.localizedDescription)")
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        let panelController = PalettePanelController(model: model)
        self.panelController = panelController
        model.openPalette = { [weak panelController] itemID in
            panelController?.show(selecting: itemID)
        }
        hotKey.onInvoke = { [weak panelController] in panelController?.toggle() }
        registerHotKey(model.settings.globalShortcut)
        model.settings.$globalShortcut
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] shortcut in self?.registerHotKey(shortcut) }
            .store(in: &cancellables)
        model.start()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.refreshNotificationAuthorization()
        model.refreshAccessibilityPermission()
    }

    func showPalette() {
        panelController?.show()
    }

    private func registerHotKey(_ shortcut: GlobalShortcut) {
        model.shortcutRegistrationSucceeded = hotKey.register(shortcut)
    }
}

private struct MenuBarContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: DuckClipSettings
    let showPalette: () -> Void

    init(model: AppModel, showPalette: @escaping () -> Void) {
        self.model = model
        _settings = ObservedObject(wrappedValue: model.settings)
        self.showPalette = showPalette
    }

    var body: some View {
        Button("Open DuckClip (\(settings.globalShortcut.displayName))") { showPalette() }
        Button(settings.captureEnabled
            ? String(localized: "Pause Clipboard Recording")
            : String(localized: "Resume Clipboard Recording")) {
            settings.captureEnabled.toggle()
        }
        Divider()
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit DuckClip") { NSApplication.shared.terminate(nil) }
    }
}
