import Foundation
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
    /// VK -> (macOS modifier key code, the flags it contributes). Each flag carries BOTH the
    /// device-independent mask (.maskControl …) AND the device-dependent left/right bit
    /// (NX_DEVICE*KEYMASK). Real hardware modifier presses set both.
    private static func flags(_ raw: UInt64) -> CGEventFlags { CGEventFlags(rawValue: raw) }
    private static let modifiers: [Int: (Int64, CGEventFlags)] = [
        0x10: (56, flags(0x20000 | 0x2)),   0xA0: (56, flags(0x20000 | 0x2)),   0xA1: (60, flags(0x20000 | 0x4)),
        0x11: (59, flags(0x40000 | 0x1)),   0xA2: (59, flags(0x40000 | 0x1)),   0xA3: (62, flags(0x40000 | 0x2000)),
        0x12: (58, flags(0x80000 | 0x20)),  0xA4: (58, flags(0x80000 | 0x20)),  0xA5: (61, flags(0x80000 | 0x40)),
        0x5B: (55, flags(0x100000 | 0x8)),  0x5C: (54, flags(0x100000 | 0x10)),
    ]
    private static let capsLockVK = 0x14

    private var heldModifierFlags: CGEventFlags = []
    /// Hardware-state source: VoiceOver only recognises its VO keys (control+option) from
    /// events posted with .hidSystemState — .combinedSessionState events reach ordinary app
    /// shortcuts but never trigger VoiceOver commands.
    private let source = CGEventSource(stateID: .hidSystemState)

    func handle(vkCode: Int, scanCode: Int, extended: Bool, pressed: Bool) {
        if vkCode == Self.capsLockVK {
            // Caps lock toggles; post it as its own key with the alpha-shift flag.
            post(keyCode: 57, down: pressed, flags: heldModifierFlags)
            return
        }
        if let (macCode, flag) = Self.modifiers[vkCode] {
            if pressed { heldModifierFlags.insert(flag) } else { heldModifierFlags.remove(flag) }
            post(keyCode: macCode, down: pressed, flags: heldModifierFlags)
            // VoiceOver only fires a VO command if its VO keys (control+option) have registered
            // as held before the command key arrives. When a VO chord is building, give its state
            // machine a moment; ordinary typing (no control+option) is never delayed.
            if pressed, heldModifierFlags.contains(.maskControl), heldModifierFlags.contains(.maskAlternate) {
                usleep(20_000)
            }
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
