import AppKit
import Combine
import DuckClipCore
import SwiftUI

@main
struct DuckClipApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarRoot(delegate: delegate)
        } label: {
            MenuBarLabel(delegate: delegate)
        }

        Settings {
            SettingsRoot(delegate: delegate)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published private(set) var model: AppModel?
    @Published private(set) var startupError: String?

    private var panelController: PalettePanelController?
    private var quickPastePanelController: QuickPastePanelController?
    private let hotKey = HotKeyManager()
    private let quickPasteHotKey = HotKeyManager(signature: "QDUK")
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        startModel()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model?.refreshNotificationAuthorization()
        model?.refreshAccessibilityPermission()
    }

    func applicationDidResignActive(_ notification: Notification) {
        // Quick Paste is transient. Keep its presentation state in sync with
        // AppKit when hidesOnDeactivate orders the panel out automatically.
        quickPastePanelController?.hide()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPalette()
        return true
    }

    func showPalette() {
        quickPastePanelController?.hide()
        panelController?.show()
    }

    func retryStartup() {
        startModel()
    }

    func openApplicationSupport() {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return }
        NSWorkspace.shared.open(support)
    }

    private func startModel() {
        do {
            let model = try AppModel()
            startupError = nil
            self.model = model
            let panelController = PalettePanelController(model: model)
            let quickPastePanelController = QuickPastePanelController(model: model)
            self.panelController = panelController
            self.quickPastePanelController = quickPastePanelController
            model.openPalette = { [weak panelController, weak quickPastePanelController] itemID in
                quickPastePanelController?.hide()
                panelController?.show(selecting: itemID)
            }
            hotKey.onInvoke = { [weak panelController, weak quickPastePanelController] in
                quickPastePanelController?.hide()
                panelController?.toggle()
            }
            quickPasteHotKey.onInvoke = { [weak panelController, weak quickPastePanelController] in
                panelController?.hide()
                quickPastePanelController?.toggle()
            }
            registerHotKey(model.settings.globalShortcut)
            model.quickPasteShortcutRegistrationSucceeded = quickPasteHotKey.registerQuickPaste()
            cancellables.removeAll()
            model.settings.$globalShortcut
                .dropFirst()
                .removeDuplicates()
                .sink { [weak self] shortcut in self?.registerHotKey(shortcut) }
                .store(in: &cancellables)
            model.start()
            if !model.settings.hasCompletedOnboarding || CommandLine.arguments.contains("--show-palette") {
                Task { @MainActor [weak panelController] in
                    try? await Task.sleep(for: .milliseconds(250))
                    panelController?.show()
                }
            }
        } catch {
            model = nil
            panelController = nil
            quickPastePanelController = nil
            startupError = error.localizedDescription
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    private func registerHotKey(_ shortcut: GlobalShortcut) {
        model?.shortcutRegistrationSucceeded = hotKey.register(shortcut)
    }
}

private struct MenuBarRoot: View {
    @ObservedObject var delegate: AppDelegate

    var body: some View {
        if let model = delegate.model {
            MenuBarContent(
                model: model,
                showPalette: delegate.showPalette
            )
        } else if let error = delegate.startupError {
            Text("DuckClip could not start")
            Text(error).font(.caption)
            Divider()
            Button("Retry") { delegate.retryStartup() }
            Button("Open Application Support") { delegate.openApplicationSupport() }
            Divider()
            Button("Quit DuckClip") { NSApplication.shared.terminate(nil) }
        } else {
            Text("Starting DuckClip…")
        }
    }
}

private struct SettingsRoot: View {
    @ObservedObject var delegate: AppDelegate

    var body: some View {
        if let model = delegate.model {
            SettingsView(model: model)
        } else {
            ContentUnavailableView {
                Label("DuckClip could not start", systemImage: "exclamationmark.triangle")
            } description: {
                Text(delegate.startupError ?? String(localized: "Unknown startup error"))
            } actions: {
                Button("Retry") { delegate.retryStartup() }
                Button("Open Application Support") { delegate.openApplicationSupport() }
            }
            .frame(width: 520, height: 320)
        }
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var delegate: AppDelegate

    var body: some View {
        if let model = delegate.model {
            CaptureStatusIcon(model: model)
        } else {
            Image(systemName: "exclamationmark.triangle.fill")
        }
    }
}

private struct CaptureStatusIcon: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: DuckClipSettings

    init(model: AppModel) {
        self.model = model
        _settings = ObservedObject(wrappedValue: model.settings)
    }

    var body: some View {
        Group {
            if !model.shortcutRegistrationSucceeded || !model.quickPasteShortcutRegistrationSucceeded {
                Image(systemName: "exclamationmark.triangle.fill")
            } else if !settings.captureEnabled {
                Image(systemName: "pause.circle.fill")
            } else if let image = MenuBarDuck.image {
                Image(nsImage: image)
            } else {
                Image(systemName: "bird.fill")
            }
        }
            .accessibilityLabel(settings.captureEnabled ? "DuckClip recording" : "DuckClip paused")
    }
}

private enum MenuBarDuck {
    static let image: NSImage? = {
        guard
            let url = Bundle.main.url(forResource: "DuckClipMenuBar", withExtension: "png"),
            let image = NSImage(contentsOf: url)
        else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()
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
        if !model.shortcutRegistrationSucceeded {
            Label("The selected shortcut is unavailable", systemImage: "exclamationmark.triangle.fill")
        }
        if !model.quickPasteShortcutRegistrationSucceeded {
            Label("The Quick Paste shortcut is unavailable", systemImage: "exclamationmark.triangle.fill")
        }
        Button(settings.captureEnabled
            ? String(localized: "Pause Clipboard Recording")
            : String(localized: "Resume Clipboard Recording")) {
            settings.captureEnabled.toggle()
        }
        if !settings.captureEnabled {
            Text("Clipboard recording is paused").foregroundStyle(.secondary)
        }
        Divider()
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit DuckClip") { NSApplication.shared.terminate(nil) }
    }
}
