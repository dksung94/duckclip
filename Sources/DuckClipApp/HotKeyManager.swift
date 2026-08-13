import Carbon.HIToolbox
import DuckClipCore
import Foundation

@MainActor
final class HotKeyManager {
    var onInvoke: (() -> Void)?

    private let signature: OSType
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var activeIdentifier: EventHotKeyID?
    private var registeredKeyCode: UInt32?
    private var registeredModifiers: UInt32?
    private var nextIdentifier: UInt32 = 1

    init(signature: String = "DUCK") {
        self.signature = Self.makeSignature(signature)
    }

    @discardableResult
    func register(_ shortcut: GlobalShortcut) -> Bool {
        register(keyCode: UInt32(kVK_ANSI_V), carbonModifiers: modifiers(for: shortcut))
    }

    @discardableResult
    func registerQuickPaste() -> Bool {
        register(keyCode: UInt32(kVK_ANSI_V), carbonModifiers: UInt32(cmdKey | controlKey))
    }

    private func register(keyCode: UInt32, carbonModifiers: UInt32) -> Bool {
        if hotKeyRef != nil, registeredKeyCode == keyCode, registeredModifiers == carbonModifiers {
            return true
        }
        if handlerRef == nil {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: OSType(kEventHotKeyPressed)
            )
            let status = InstallEventHandler(
                GetApplicationEventTarget(),
                { _, event, userData in
                    guard let userData else { return noErr }
                    let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                    guard let event else { return OSStatus(eventNotHandledErr) }
                    var received = EventHotKeyID()
                    let status = GetEventParameter(
                        event,
                        EventParamName(kEventParamDirectObject),
                        EventParamType(typeEventHotKeyID),
                        nil,
                        MemoryLayout<EventHotKeyID>.size,
                        nil,
                        &received
                    )
                    guard
                        status == noErr,
                        let active = manager.activeIdentifier,
                        received.signature == active.signature,
                        received.id == active.id
                    else { return OSStatus(eventNotHandledErr) }
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
        let identifier = EventHotKeyID(signature: signature, id: nextIdentifier)
        var candidate: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            carbonModifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &candidate
        )
        guard status == noErr, let candidate else { return false }
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = candidate
        activeIdentifier = identifier
        registeredKeyCode = keyCode
        registeredModifiers = carbonModifiers
        return true
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    private static func makeSignature(_ value: String) -> OSType {
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
