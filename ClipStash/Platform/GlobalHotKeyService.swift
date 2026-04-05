import Carbon
import AppKit

/// Lightweight global hotkey service using Carbon APIs.
/// Replaces the KeyboardShortcuts library to avoid #Preview macro build issues.
@MainActor
final class GlobalHotKeyService {
    static let shared = GlobalHotKeyService()
    
    private var hotKeys: [UInt32: HotKeyRegistration] = [:]
    private var nextId: UInt32 = 1
    
    struct HotKeyRegistration {
        let id: UInt32
        let ref: EventHotKeyRef
        let handler: () -> Void
    }
    
    private init() {
        // Install Carbon event handler for hot keys
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        
        let handler: EventHandlerUPP = { _, event, userData -> OSStatus in
            guard let event = event else { return OSStatus(eventNotHandledErr) }
            
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            
            guard status == noErr else { return status }
            
            DispatchQueue.main.async {
                GlobalHotKeyService.shared.hotKeys[hotKeyID.id]?.handler()
            }
            
            return noErr
        }
        
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventSpec, nil, nil)
    }
    
    /// Register a global hotkey
    /// - Parameters:
    ///   - keyCode: Carbon virtual key code
    ///   - modifiers: Carbon modifier flags (cmdKey, shiftKey, optionKey, controlKey)
    ///   - handler: Closure to call when hotkey is pressed
    /// - Returns: Registration ID for later unregistration
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> UInt32 {
        let id = nextId
        nextId += 1
        
        let signature = OSType(0x434C5053) // "CLPS"
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        
        guard status == noErr, let ref = hotKeyRef else {
            print("ClipStash: Failed to register hotkey, status: \(status)")
            return 0
        }
        
        hotKeys[id] = HotKeyRegistration(id: id, ref: ref, handler: handler)
        return id
    }
    
    /// Unregister a previously registered hotkey
    func unregister(id: UInt32) {
        guard let registration = hotKeys.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(registration.ref)
    }
    
    /// Unregister all hotkeys
    func unregisterAll() {
        for (_, registration) in hotKeys {
            UnregisterEventHotKey(registration.ref)
        }
        hotKeys.removeAll()
    }
    
    // MARK: - Common key codes (Carbon virtual key codes)
    enum KeyCode {
        static let i: UInt32 = 34
        static let v: UInt32 = 9
        static let p: UInt32 = 35
        static let c: UInt32 = 8
        static let x: UInt32 = 7
        static let left: UInt32 = 123
        static let right: UInt32 = 124
        static let delete: UInt32 = 51
    }
    
    // MARK: - Modifier masks (Carbon)
    enum Modifiers {
        static let cmd: UInt32 = UInt32(cmdKey)
        static let shift: UInt32 = UInt32(shiftKey)
        static let option: UInt32 = UInt32(optionKey)
        static let control: UInt32 = UInt32(controlKey)
        static let cmdShift: UInt32 = cmd | shift
        static let cmdControl: UInt32 = cmd | control
        static let cmdOption: UInt32 = cmd | option
    }
}


