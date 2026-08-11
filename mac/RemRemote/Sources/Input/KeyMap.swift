import Foundation
import CoreGraphics

/// A Windows virtual-key code plus its "extended" flag, as the NVDA Remote protocol
/// expects in "key" messages.
struct WindowsKey: Equatable, Hashable {
    let vk: Int
    let extended: Bool
}

/// Maps macOS virtual key codes (kVK_*, layout independent — physical positions) to
/// Windows virtual-key codes. Position-based mapping: the manual's advice "keep both
/// keyboard layouts the same" applies exactly as it does between two Windows machines.
enum KeyMap {
    static let f10KeyCode: Int64 = 109
    static let insertKeyCode: Int64 = 114 // "Help" on old Apple keyboards, Insert on PC boards

    static let leftCommand: Int64 = 55
    static let rightCommand: Int64 = 54
    static let leftOption: Int64 = 58
    static let rightOption: Int64 = 61
    static let leftShift: Int64 = 56
    static let rightShift: Int64 = 60
    static let leftControl: Int64 = 59
    static let rightControl: Int64 = 62
    static let capsLock: Int64 = 57
    static let function: Int64 = 63

    static let commandKeyCodes: Set<Int64> = [leftCommand, rightCommand]
    static let optionKeyCodes: Set<Int64> = [leftOption, rightOption]
    static let modifierKeyCodes: Set<Int64> = [
        leftCommand, rightCommand, leftOption, rightOption,
        leftShift, rightShift, leftControl, rightControl, capsLock, function,
    ]

    static let insert = WindowsKey(vk: 0x2D, extended: true)

    // MARK: - Modifier state from event flags

    /// Device-dependent left/right modifier bits carried in CGEventFlags
    /// (IOKit's NX_DEVICE*KEYMASK). Reading these off each event is the only reliable
    /// way to know a modifier's up/down state — CGEvents deliver no press flag for
    /// modifiers, and a self-maintained toggle desyncs on any missed event.
    static let deviceFlagMasks: [Int64: UInt64] = [
        leftControl: 0x0000_0001,
        rightControl: 0x0000_2000,
        leftShift: 0x0000_0002,
        rightShift: 0x0000_0004,
        leftCommand: 0x0000_0008,
        rightCommand: 0x0000_0010,
        leftOption: 0x0000_0020,
        rightOption: 0x0000_0040,
    ]

    static let commandFlagMask: UInt64 = 0x0000_0008 | 0x0000_0010
    static let optionFlagMask: UInt64 = 0x0000_0020 | 0x0000_0040

    enum ModifierFamily { case command, option }

    /// True if the given modifier key is down according to the event's own flags.
    static func isModifierPressed(keyCode: Int64, flags: CGEventFlags) -> Bool {
        if let mask = deviceFlagMasks[keyCode] {
            return (flags.rawValue & mask) != 0
        }
        if keyCode == capsLock { return flags.contains(.maskAlphaShift) }
        if keyCode == function { return flags.contains(.maskSecondaryFn) }
        return false
    }

    /// The key code of the currently-held Command or Option key (left preferred), or nil
    /// if that family is not down in the given flags.
    static func heldChordKeyCode(family: ModifierFamily, flags: CGEventFlags) -> Int64? {
        let raw = flags.rawValue
        switch family {
        case .command:
            if raw & 0x0000_0008 != 0 { return leftCommand }
            if raw & 0x0000_0010 != 0 { return rightCommand }
        case .option:
            if raw & 0x0000_0020 != 0 { return leftOption }
            if raw & 0x0000_0040 != 0 { return rightOption }
        }
        return nil
    }

    /// kVK code -> Windows key.
    static let table: [Int64: WindowsKey] = {
        var map: [Int64: WindowsKey] = [:]
        func put(_ code: Int64, _ vk: Int, extended: Bool = false) {
            map[code] = WindowsKey(vk: vk, extended: extended)
        }
        // Letters (ANSI positions)
        put(0, 0x41)  // A
        put(11, 0x42) // B
        put(8, 0x43)  // C
        put(2, 0x44)  // D
        put(14, 0x45) // E
        put(3, 0x46)  // F
        put(5, 0x47)  // G
        put(4, 0x48)  // H
        put(34, 0x49) // I
        put(38, 0x4A) // J
        put(40, 0x4B) // K
        put(37, 0x4C) // L
        put(46, 0x4D) // M
        put(45, 0x4E) // N
        put(31, 0x4F) // O
        put(35, 0x50) // P
        put(12, 0x51) // Q
        put(15, 0x52) // R
        put(1, 0x53)  // S
        put(17, 0x54) // T
        put(32, 0x55) // U
        put(9, 0x56)  // V
        put(13, 0x57) // W
        put(7, 0x58)  // X
        put(16, 0x59) // Y
        put(6, 0x5A)  // Z
        // Number row
        put(29, 0x30) // 0
        put(18, 0x31) // 1
        put(19, 0x32) // 2
        put(20, 0x33) // 3
        put(21, 0x34) // 4
        put(23, 0x35) // 5
        put(22, 0x36) // 6
        put(26, 0x37) // 7
        put(28, 0x38) // 8
        put(25, 0x39) // 9
        // Punctuation (OEM keys, US layout positions)
        put(24, 0xBB) // =
        put(27, 0xBD) // -
        put(33, 0xDB) // [
        put(30, 0xDD) // ]
        put(42, 0xDC) // backslash
        put(41, 0xBA) // ;
        put(39, 0xDE) // '
        put(43, 0xBC) // ,
        put(47, 0xBE) // .
        put(44, 0xBF) // /
        put(50, 0xC0) // `
        put(10, 0xE2) // ISO section key -> OEM_102
        // Whitespace and controls
        put(36, 0x0D) // Return
        put(48, 0x09) // Tab
        put(49, 0x20) // Space
        put(51, 0x08) // Delete (backspace)
        put(53, 0x1B) // Escape
        // Navigation block (extended keys on Windows)
        put(114, 0x2D, extended: true) // Help/Insert
        put(117, 0x2E, extended: true) // Forward delete
        put(115, 0x24, extended: true) // Home
        put(119, 0x23, extended: true) // End
        put(116, 0x21, extended: true) // Page up
        put(121, 0x22, extended: true) // Page down
        put(123, 0x25, extended: true) // Left arrow
        put(124, 0x27, extended: true) // Right arrow
        put(125, 0x28, extended: true) // Down arrow
        put(126, 0x26, extended: true) // Up arrow
        // Function keys
        put(122, 0x70) // F1
        put(120, 0x71) // F2
        put(99, 0x72)  // F3
        put(118, 0x73) // F4
        put(96, 0x74)  // F5
        put(97, 0x75)  // F6
        put(98, 0x76)  // F7
        put(100, 0x77) // F8
        put(101, 0x78) // F9
        put(109, 0x79) // F10
        put(103, 0x7A) // F11
        put(111, 0x7B) // F12
        put(105, 0x7C) // F13
        put(107, 0x7D) // F14
        put(113, 0x7E) // F15
        put(106, 0x7F) // F16
        put(64, 0x80)  // F17
        put(79, 0x81)  // F18
        put(80, 0x82)  // F19
        put(90, 0x83)  // F20
        // Keypad
        put(82, 0x60) // 0
        put(83, 0x61) // 1
        put(84, 0x62) // 2
        put(85, 0x63) // 3
        put(86, 0x64) // 4
        put(87, 0x65) // 5
        put(88, 0x66) // 6
        put(89, 0x67) // 7
        put(91, 0x68) // 8
        put(92, 0x69) // 9
        put(65, 0x6E) // decimal
        put(67, 0x6A) // multiply
        put(69, 0x6B) // plus
        put(78, 0x6D) // minus
        put(75, 0x6F, extended: true) // divide
        put(76, 0x0D, extended: true) // keypad enter
        put(71, 0x90) // clear -> num lock
        put(81, 0xBB) // keypad equals -> =
        // Modifiers
        put(56, 0xA0) // left shift
        put(60, 0xA1) // right shift
        put(59, 0xA2) // left control
        put(62, 0xA3, extended: true) // right control
        put(58, 0xA4) // left option -> left alt
        put(61, 0xA5, extended: true) // right option -> right alt (AltGr)
        put(55, 0x5B, extended: true) // left command -> left Windows
        put(54, 0x5C, extended: true) // right command -> right Windows
        put(110, 0x5D, extended: true) // PC menu key -> Applications
        return map
    }()

    static func windowsKey(for keyCode: Int64) -> WindowsKey? {
        table[keyCode]
    }

    /// Reverse lookup for the controlled (slave) role: a Windows virtual-key code back to a
    /// macOS key code, so incoming key messages can be injected. Positional (the inverse of
    /// `table`); the extended flag disambiguates the few keys that share a VK.
    static let reverseTable: [Int: Int64] = {
        var map: [Int: Int64] = [:]
        // Build from `table`; when several mac keys map to one VK, prefer the non-extended,
        // lower keycode (the main-block key rather than the keypad twin).
        for (macCode, key) in table.sorted(by: { $0.key < $1.key }) {
            if map[key.vk] == nil { map[key.vk] = macCode }
        }
        return map
    }()

    static func macKeyCode(forVK vk: Int) -> Int64? {
        reverseTable[vk]
    }

    /// PC set-1 make scan code -> macOS ANSI virtual key code (physical position), for the
    /// printable character block only: letters, the number row and the OEM punctuation
    /// around them, plus the ISO `<>` key. The controlled role injects these by physical
    /// position so a non-US keyboard on the controlling side (e.g. a German QWERTZ) lands
    /// on the same physical key here and this Mac's own layout produces the right character
    /// — the VK map alone would inject the US character at that VK and mis-map z/y, ö, ü, ß…
    /// Non-character keys (whitespace, navigation, keypad, function, modifiers) carry no
    /// layout-dependent character and stay on the positional VK map.
    static let scanToMacCharKey: [Int: Int64] = [
        // number row: 1 2 3 4 5 6 7 8 9 0 - =
        0x02: 18, 0x03: 19, 0x04: 20, 0x05: 21, 0x06: 23, 0x07: 22,
        0x08: 26, 0x09: 28, 0x0A: 25, 0x0B: 29, 0x0C: 27, 0x0D: 24,
        // top letter row: Q W E R T Y U I O P [ ]
        0x10: 12, 0x11: 13, 0x12: 14, 0x13: 15, 0x14: 17, 0x15: 16,
        0x16: 32, 0x17: 34, 0x18: 31, 0x19: 35, 0x1A: 33, 0x1B: 30,
        // home row: A S D F G H J K L ; ' `
        0x1E: 0, 0x1F: 1, 0x20: 2, 0x21: 3, 0x22: 5, 0x23: 4,
        0x24: 38, 0x25: 40, 0x26: 37, 0x27: 41, 0x28: 39, 0x29: 50,
        // bottom row: \ Z X C V B N M , . /
        0x2B: 42, 0x2C: 6, 0x2D: 7, 0x2E: 8, 0x2F: 9, 0x30: 11,
        0x31: 45, 0x32: 46, 0x33: 43, 0x34: 47, 0x35: 44,
        // ISO `<>` key between left shift and Z
        0x56: 10,
    ]

    /// Physical-position key code for a character-block scan code, or nil for keys that
    /// should stay on the VK map.
    static func macCharKeyCode(forScan scan: Int) -> Int64? {
        scanToMacCharKey[scan]
    }

    /// Physical keys in the printable "character" block — letters, the number row and the
    /// OEM punctuation around it. These are mapped by the character the active layout
    /// produces (see LayoutMapper), not by US physical position. Whitespace, navigation,
    /// function keys, the keypad and modifiers are deliberately excluded: they carry no
    /// layout-dependent character and stay positional.
    static let characterKeyCodes: Set<Int64> = [
        // number row: 1 2 3 4 5 6 7 8 9 0 - =
        18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24,
        // top letter row: Q W E R T Y U I O P [ ]
        12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30,
        // home row: A S D F G H J K L ; '
        0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39,
        // bottom row: Z X C V B N M , . /
        6, 7, 8, 9, 11, 45, 46, 43, 47, 44,
        // backslash, backtick, and the ISO key next to left shift
        42, 50, 10,
    ]
}
