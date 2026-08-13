import Carbon.HIToolbox
import DuckClipCore
import Foundation

@MainActor
final class HotKeyManager {
    var onInvoke: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var nextIdentifier: UInt32 = 1

    @discardableResult
    func register(_ shortcut: GlobalShortcut) -> Bool {
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

        nextIdentifier &+= 1
        let identifier = EventHotKeyID(signature: Self.signature("DUCK"), id: nextIdentifier)
        var candidate: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_V),
            modifiers(for: shortcut),
            identifier,
            GetApplicationEventTarget(),
            0,
            &candidate
        )
        guard status == noErr, let candidate else { return false }
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = candidate
        return true
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
