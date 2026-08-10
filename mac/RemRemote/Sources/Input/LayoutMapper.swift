import AppKit
import CoreGraphics

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
    static func baseCharacter(for event: CGEvent) -> Character? {
        guard let nsEvent = NSEvent(cgEvent: event),
              let chars = nsEvent.charactersIgnoringModifiers,
              let scalar = chars.unicodeScalars.first,
              scalar.value >= 0x20 else { // reject control characters
            return nil
        }
        let lowered = Character(scalar).lowercased()
        return lowered.first
    }
}
