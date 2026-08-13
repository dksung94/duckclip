import Carbon.HIToolbox
import DuckClipCore
import Foundation

@MainActor
final class HotKeyManager {
    var onInvoke: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    @discardableResult
    func register(_ shortcut: GlobalShortcut) -> Bool {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if handlerRef == nil {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: OSType(kEventHotKeyPressed)
            )
            let status = InstallEventHandler(
                GetApplicationEventTarget(),
                { _, _, userData in
                    guard let userData else { return noErr }
                    let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                    Task { @MainActor in manager.onInvoke?() }
                    return noErr
                },
                1,
                &eventType,
                Unmanaged.passUnretained(self).toOpaque(),
                &handlerRef
            )
            guard status == noErr else { return false }
        }

        let identifier = EventHotKeyID(signature: Self.signature("DUCK"), id: 1)
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_V),
            modifiers(for: shortcut),
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        return status == noErr && hotKeyRef != nil
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    private static func signature(_ value: String) -> OSType {
        value.utf8.reduce(0) { ($0 << 8) + OSType($1) }
    }

    private func modifiers(for shortcut: GlobalShortcut) -> UInt32 {
        switch shortcut {
        case .commandShiftV: UInt32(cmdKey | shiftKey)
        case .commandOptionV: UInt32(cmdKey | optionKey)
        case .controlOptionV: UInt32(controlKey | optionKey)
        }
    }
}
