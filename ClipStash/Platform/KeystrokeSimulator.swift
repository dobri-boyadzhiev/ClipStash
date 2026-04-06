import AppKit
import os.log

private let logger = Logger(subsystem: "com.clipstash.app", category: "KeystrokeSimulator")

/// Simulates keyboard events via CGEvent for auto-paste and other system-level key actions.
enum KeystrokeSimulator {

    /// Returns `true` if the app has Accessibility permission, which is required for CGEvent posting.
    /// If `promptIfNeeded` is true, macOS will show the Accessibility permission dialog.
    @discardableResult
    static func checkAccessibility(promptIfNeeded: Bool = false) -> Bool {
        let trusted: Bool
        if promptIfNeeded {
            let options = [
                "AXTrustedCheckOptionPrompt" as CFString: true as CFBoolean
            ] as CFDictionary
            trusted = AXIsProcessTrustedWithOptions(options)
        } else {
            trusted = AXIsProcessTrustedWithOptions(nil)
        }
        if !trusted {
            logger.warning("⚠️ Accessibility permission NOT granted — CGEvent keystrokes will be silently dropped")
        }
        return trusted
    }

    /// Simulates a single keystroke with the given key code and modifier flags.
    static func simulateKeystroke(keyCode: CGKeyCode, modifiers: CGEventFlags) async {
        guard checkAccessibility() else {
            logger.error("❌ Cannot simulate keystroke — no Accessibility permission")
            return
        }

        let source = CGEventSource(stateID: .combinedSessionState)
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)

        guard keyDown != nil, keyUp != nil else {
            logger.error("❌ Failed to create CGEvent objects")
            return
        }

        keyDown?.flags = modifiers
        keyUp?.flags = modifiers

        keyDown?.post(tap: .cgSessionEventTap)
        try? await Task.sleep(nanoseconds: 20_000_000) // 20ms between key down and up
        keyUp?.post(tap: .cgSessionEventTap)
    }

    /// Simulates ⌘V (paste) keystroke.
    static func simulatePaste() async {
        await simulateKeystroke(keyCode: 9, modifiers: .maskCommand) // 9 = V
    }

    /// Simulates ⌘C (copy) keystroke.
    static func simulateCopy() async {
        await simulateKeystroke(keyCode: 8, modifiers: .maskCommand) // 8 = C
    }
}
