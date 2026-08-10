import AppKit
import CoreGraphics
import Carbon.HIToolbox

/// Translates the *character* a key produces under the Mac's active keyboard layout into
/// the Windows virtual-key code that reproduces it on the controlled machine.
///
/// The controlled machine injects by VK code and derives the scan code from its own
/// layout (see the add-on's `input.send_key`), so — with matching layouts, as the manual
/// advises — the VK for a character always yields that character there. Mapping by
/// physical position instead assumes a US layout: on a German keyboard it swaps Y/Z and
/// turns ö/ä/ü/ß into US punctuation. Only the printable "character" keys are remapped;
/// everything else (arrows, function keys, whitespace, the keypad) stays positional.
enum LayoutMapper {
    /// Windows VK for a base (unshifted) character. Letters and digits are layout-neutral
    /// on Windows; the OEM punctuation entries cover the base characters of both the
    /// German and US layouts (each character is unique to one physical key per layout, so
    /// the combined table never has to choose between them for a given user).
    static let characterToVK: [Character: WindowsKey] = {
        var map: [Character: WindowsKey] = [:]
        for scalar in UnicodeScalar("a").value...UnicodeScalar("z").value {
            let c = Character(UnicodeScalar(scalar)!)
            map[c] = WindowsKey(vk: 0x41 + Int(scalar - UnicodeScalar("a").value), extended: false)
        }
        for scalar in UnicodeScalar("0").value...UnicodeScalar("9").value {
            let c = Character(UnicodeScalar(scalar)!)
            map[c] = WindowsKey(vk: 0x30 + Int(scalar - UnicodeScalar("0").value), extended: false)
        }
        func put(_ c: Character, _ vk: Int) { map[c] = WindowsKey(vk: vk, extended: false) }
        // German base characters.
        put("ü", 0xBA) // OEM_1
        put("ö", 0xC0) // OEM_3
        put("ä", 0xDE) // OEM_7
        put("ß", 0xDB) // OEM_4
        put("+", 0xBB) // OEM_PLUS (German)
        put("#", 0xBF) // OEM_2 (German)
        put("<", 0xE2) // OEM_102 (German, the extra key next to left shift)
        put("´", 0xDD) // OEM_6 (German acute accent, dead key)
        put("^", 0xDC) // OEM_5 (German circumflex, dead key)
        // US base characters (distinct from the German ones above).
        put(";", 0xBA) // OEM_1
        put("=", 0xBB) // OEM_PLUS
        put("/", 0xBF) // OEM_2
        put("`", 0xC0) // OEM_3
        put("[", 0xDB) // OEM_4
        put("]", 0xDD) // OEM_6
        put("\\", 0xDC) // OEM_5
        put("'", 0xDE) // OEM_7
        // Shared punctuation (same VK on both layouts).
        put(",", 0xBC) // OEM_COMMA
        put(".", 0xBE) // OEM_PERIOD
        put("-", 0xBD) // OEM_MINUS
        return map
    }()

    /// The Windows key for a printable character-block key, using the layout-produced
    /// character; nil if the character does not map (falls back to positional mapping).
    static func windowsKey(for event: CGEvent, keyCode: Int64) -> WindowsKey? {
        guard KeyMap.characterKeyCodes.contains(keyCode) else { return nil }
        guard let base = baseCharacter(for: event) else { return nil }
        return characterToVK[base]
    }

    /// The unshifted character the key produces under the current layout (lowercased),
    /// e.g. the "Z" key on a German keyboard yields "z", the "1" key yields "1".
    ///
    /// Uses UCKeyTranslate with NO modifiers, deliberately: NSEvent.charactersIgnoringModifiers
    /// still reflects Shift (and Caps Lock), so with Shift held it returns the *shifted*
    /// character — which, mapped to a VK and then combined with the separately-sent Shift on
    /// the far side, produces the wrong glyph (e.g. "_" -> "'", "'" -> "Ä"). The base
    /// character is layout-correct and Shift-independent, and dead keys (´, ^) resolve to
    /// their own character instead of falling through to a US position.
    static func baseCharacter(for event: CGEvent) -> Character? {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        return unshiftedCharacter(forKeyCode: keyCode)
    }

    static func unshiftedCharacter(forKeyCode keyCode: CGKeyCode) -> Character? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPtr).takeUnretainedValue() as Data
        let kbType = UInt32(LMGetKbdType())

        func translate(_ kc: CGKeyCode, state: inout UInt32, options: OptionBits) -> String {
            var chars = [UniChar](repeating: 0, count: 8)
            var length = 0
            let status = layoutData.withUnsafeBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return OSStatus(-1) }
                let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
                return UCKeyTranslate(layout, kc, UInt16(kUCKeyActionDown), 0, kbType,
                                      options, &state, chars.count, &length, &chars)
            }
            guard status == noErr else { return "" }
            return String(utf16CodeUnits: chars, count: length)
        }

        var state: UInt32 = 0
        var result = translate(keyCode, state: &state, options: OptionBits(kUCKeyTranslateNoDeadKeysBit))
        if result.isEmpty {
            // A dead key (´, ^, `): resolve it by pressing it, then flushing with a space,
            // which yields the spacing form of the accent (e.g. "´"). Without this it would
            // fall through to the US positional map and send the wrong key.
            state = 0
            _ = translate(keyCode, state: &state, options: 0)
            if state != 0 {
                result = translate(49 /* space */, state: &state, options: 0)
            }
        }
        // First printable, non-space scalar.
        for scalar in result.unicodeScalars where scalar.value > 0x20 {
            return Character(scalar).lowercased().first
        }
        return nil
    }
}
