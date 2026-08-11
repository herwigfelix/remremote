import CoreGraphics

/// Injects key events received from a controlling machine into this Mac (the controlled
/// role). Windows virtual-key codes arrive over the control channel; this turns them back
/// into macOS key events with the right modifier flags.
///
/// macOS needs the aggregate modifier flags on every posted event for combinations to
/// register, so held modifiers are tracked as they arrive (VK_CONTROL, VK_MENU, …) and
/// applied to each keystroke. A Windows master controlling a Mac relays the NVDA key as
/// control+alt, which lands here as control+option — the VoiceOver keys.
final class KeyInjector {
    /// VK -> (macOS modifier key code, the flag it contributes).
    private static let modifiers: [Int: (Int64, CGEventFlags)] = [
        0x10: (56, .maskShift), 0xA0: (56, .maskShift), 0xA1: (60, .maskShift),
        0x11: (59, .maskControl), 0xA2: (59, .maskControl), 0xA3: (62, .maskControl),
        0x12: (58, .maskAlternate), 0xA4: (58, .maskAlternate), 0xA5: (61, .maskAlternate),
        0x5B: (55, .maskCommand), 0x5C: (54, .maskCommand),
    ]
    private static let capsLockVK = 0x14

    private var heldModifierFlags: CGEventFlags = []
    private let source = CGEventSource(stateID: .combinedSessionState)

    func handle(vkCode: Int, scanCode: Int, extended: Bool, pressed: Bool) {
        if vkCode == Self.capsLockVK {
            // Caps lock toggles; post it as its own key with the alpha-shift flag.
            post(keyCode: 57, down: pressed, flags: heldModifierFlags)
            return
        }
        if let (macCode, flag) = Self.modifiers[vkCode] {
            if pressed { heldModifierFlags.insert(flag) } else { heldModifierFlags.remove(flag) }
            post(keyCode: macCode, down: pressed, flags: heldModifierFlags)
            return
        }
        // Character keys (letters, number row, OEM punctuation) are injected by PHYSICAL
        // position via the hardware scan code, so a non-US keyboard on the controlling side
        // lands on the same physical key here and this Mac's layout produces the right
        // character. Non-extended only — extended/keypad keys share these scan codes and
        // must stay on the VK map.
        if !extended, let macCode = KeyMap.macCharKeyCode(forScan: scanCode) {
            post(keyCode: macCode, down: pressed, flags: heldModifierFlags)
            return
        }
        guard let macCode = KeyMap.macKeyCode(forVK: vkCode) else { return }
        post(keyCode: macCode, down: pressed, flags: heldModifierFlags)
    }

    /// Release any modifiers still held (when control ends or the session drops), so
    /// nothing stays stuck down on this Mac.
    func releaseAll() {
        heldModifierFlags = []
    }

    private func post(keyCode: Int64, down: Bool, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: down) else {
            return
        }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
}
