import Foundation
import AppKit
import Carbon.HIToolbox

final class HotKeyManager {
    static let shared = HotKeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var handlerUPP: EventHandlerUPP?
    var onHotKey: (() -> Void)?

    private init() {}

    func register() {
        unregister()

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let handler: EventHandlerUPP = { (_, event, userData) -> OSStatus in
            guard let userData else { return noErr }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            if hotKeyID.id == 1 {
                DispatchQueue.main.async {
                    manager.onHotKey?()
                }
            }
            return noErr
        }
        handlerUPP = handler

        var handlerRefLocal: EventHandlerRef?
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            userData,
            &handlerRefLocal
        )
        handlerRef = handlerRefLocal

        // Shift + Command + V
        // cmdKey = 256, shiftKey = 512 in Carbon
        let hotKeyID = EventHotKeyID(signature: OSType(0x50535447), id: 1) // 'PSTG'
        var hotKeyRefLocal: EventHotKeyRef?
        let keyCode = UInt32(kVK_ANSI_V)
        let modifiers = UInt32(cmdKey | shiftKey)
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRefLocal
        )
        hotKeyRef = hotKeyRefLocal

        if installStatus == noErr && registerStatus == noErr {
            AppLog.info("Registered global hotkey ⇧⌘V (Carbon)")
        } else {
            AppLog.error("Hotkey registration failed: install=\(installStatus) register=\(registerStatus)")
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    deinit {
        unregister()
    }
}
