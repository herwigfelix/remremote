import XCTest
@testable import remremote

/// Interoperability tests pinning the wire contracts against the Windows implementations.
/// If one of these fails, the app can no longer talk to the add-on — do not "fix" the
/// expectations without checking the other side.
final class InteropTests: XCTestCase {

    // MARK: - Control channel message layer (PyCryptodome AES-256-GCM, 16-byte nonce)

    /// Fixture generated with PyCryptodome exactly as transport.py does it:
    /// key = SHA256("geheim123"), AES.new(key, MODE_GCM) with its default 16-byte nonce.
    func testDecryptsPyCryptodomeMessage() throws {
        let key = MessageCrypto.key(fromPassword: "geheim123")
        let plaintext = MessageCrypto.decrypt(
            nonce: "zzHGCoi+9zkQalk8MC0JVQ==",
            data: "3JyMrzvBwhUxJM62nzBDT+0hjS1mu5gIA3YBA1zhDyDX0I5cUVMoHo/bB7TXxRPN8iwJHdjMh0CBEUbMOLjkfjGVZGVLT2AVKdTMJ3Zps5nC0Q==",
            tag: "ygE4K83YJkVJn7EEVrtA+w==",
            key: key
        )
        let decoded = try XCTUnwrap(plaintext)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: decoded) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "key")
        XCTAssertEqual(object["vk_code"] as? Int, 65)
        XCTAssertEqual(object["pressed"] as? Bool, true)
    }

    func testMessageCryptoRoundTrip() throws {
        let key = MessageCrypto.key(fromPassword: "another password")
        let plaintext = Data(#"{"type":"speak","sequence":["hello"]}"#.utf8)
        let wrapped = try MessageCrypto.encrypt(plaintext, key: key)
        XCTAssertEqual(wrapped["type"] as? String, "encrypted")
        let decrypted = MessageCrypto.decrypt(
            nonce: try XCTUnwrap(wrapped["nonce"] as? String),
            data: try XCTUnwrap(wrapped["data"] as? String),
            tag: try XCTUnwrap(wrapped["tag"] as? String),
            key: key
        )
        XCTAssertEqual(decrypted, plaintext)
        // Wrong key must fail, not produce garbage.
        XCTAssertNil(MessageCrypto.decrypt(
            nonce: try XCTUnwrap(wrapped["nonce"] as? String),
            data: try XCTUnwrap(wrapped["data"] as? String),
            tag: try XCTUnwrap(wrapped["tag"] as? String),
            key: MessageCrypto.key(fromPassword: "wrong")
        ))
    }

    // MARK: - RemSound key derivation (cross-implementation vectors)

    func testRemSoundKeyDerivationVectors() {
        func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
        XCTAssertEqual(
            hex(RemSoundCrypto.deriveKey(password: "test123").withUnsafeBytes { Data($0) }),
            "b419d5d5ab025172af8ea4f8923ef9176bf2c0e720e40873d82aa4350f0e87d3"
        )
        XCTAssertEqual(hex(RemSoundCrypto.fingerprint(password: "test123")), "fb6a9f52926ac190")
        XCTAssertEqual(hex(RemSoundCrypto.fingerprint(password: "")), "7a78e2d810154bf7")
    }

    func testRemSoundSealOpenRoundTrip() {
        let key = RemSoundCrypto.deriveKey(password: "test123")
        let plaintext = Data("TNVH1 payload".utf8)
        let sealed = RemSoundCrypto.seal(plaintext, key: key)!
        XCTAssertEqual(sealed.count, plaintext.count + RemSoundCrypto.overheadBytes)
        XCTAssertEqual(RemSoundCrypto.open(sealed, key: key), plaintext)
        XCTAssertNil(RemSoundCrypto.open(sealed, key: RemSoundCrypto.deriveKey(password: "other")))
    }

    // MARK: - RemSound packet header

    func testRemPacketHeaderRoundTrip() {
        let header = RemPacket.writeHeader(type: .heartbeat, streamId: 65534, sequence: 42)
        XCTAssertEqual(header.count, RemPacket.headerSize)
        XCTAssertEqual([UInt8](header.prefix(4)), [0x52, 0x4D, 0x4E, 0x44]) // "RMND"
        let parsed = RemPacket.readHeader(header + Data([1, 2, 3]))!
        XCTAssertEqual(parsed.type, .heartbeat)
        XCTAssertEqual(parsed.streamId, 65534)
        XCTAssertEqual(parsed.sequence, 42)
        XCTAssertNil(RemPacket.readHeader(Data([0, 1, 2])))
    }

    func testRemAudioFormatParsing() {
        // 44-byte payload: 48000 Hz, 2 ch, 16 bit, encoding 1, align 4, 384000 B/s,
        // codec 2 (Opus), 480 samples/frame, lane 0, fingerprint 8 bytes.
        var payload = Data()
        for value: Int32 in [48000, 2, 16, 1, 4, 384_000, 2, 480] {
            withUnsafeBytes(of: value.littleEndian) { payload.append(contentsOf: $0) }
        }
        payload.append(contentsOf: [0, 0, 0, 0])
        let fingerprint = Data([1, 2, 3, 4, 5, 6, 7, 8])
        payload.append(fingerprint)
        let format = RemAudioFormat.parse(payload)!
        XCTAssertEqual(format.sampleRate, 48000)
        XCTAssertEqual(format.channels, 2)
        XCTAssertEqual(format.codec, 2)
        XCTAssertEqual(format.frameSamplesPerChannel, 480)
        XCTAssertEqual(format.passwordFingerprint, fingerprint)
        // 32-byte payload (no lane, no fingerprint) must parse too.
        XCTAssertNotNil(RemAudioFormat.parse(payload.prefix(32)))
        XCTAssertNil(RemAudioFormat.parse(payload.prefix(31)))
    }

    // MARK: - Speech sequences

    func testSpeechSequenceParsing() {
        let raw: [Any] = [
            "Hello",
            ["PitchCommand", ["offset": 30]],
            "WORLD",
            ["PitchCommand", ["offset": 0]],
            ["LangChangeCommand", ["lang": "de_DE"]],
            "Hallo",
            ["EndUtteranceCommand", [:]],
        ]
        let items = SpeechSequenceItem.parse(raw)
        XCTAssertEqual(items.count, 7)
        XCTAssertEqual(SpeechSequenceItem.plainText(of: items), "Hello WORLD Hallo")
        if case .pitchOffset(let offset) = items[1] {
            XCTAssertEqual(offset, 30)
        } else {
            XCTFail("expected a pitch offset")
        }
        if case .languageChange(let lang) = items[4] {
            XCTAssertEqual(lang, "de_DE")
        } else {
            XCTFail("expected a language change")
        }
    }

    // MARK: - Address parsing

    func testAddressParsing() {
        XCTAssertEqual(ConnectView.parse(address: "example.com").host, "example.com")
        XCTAssertEqual(ConnectView.parse(address: "example.com").port, 6837)
        XCTAssertEqual(ConnectView.parse(address: "example.com:1234").port, 1234)
        XCTAssertEqual(ConnectView.parse(address: "[2001:db8::1]:9000").host, "2001:db8::1")
        XCTAssertEqual(ConnectView.parse(address: "[2001:db8::1]:9000").port, 9000)
        XCTAssertEqual(ConnectView.parse(address: "[2001:db8::1]").host, "2001:db8::1")
        XCTAssertEqual(ConnectView.parse(address: "[2001:db8::1]").port, 6837)
    }

    // MARK: - Key map sanity

    func testKeyMapEssentials() {
        XCTAssertEqual(KeyMap.windowsKey(for: 0), WindowsKey(vk: 0x41, extended: false)) // A
        XCTAssertEqual(KeyMap.windowsKey(for: 109), WindowsKey(vk: 0x79, extended: false)) // F10
        XCTAssertEqual(KeyMap.windowsKey(for: 114), WindowsKey(vk: 0x2D, extended: true)) // Insert
        XCTAssertEqual(KeyMap.windowsKey(for: 123), WindowsKey(vk: 0x25, extended: true)) // Left
        XCTAssertEqual(KeyMap.windowsKey(for: 55), WindowsKey(vk: 0x5B, extended: true)) // Cmd -> LWin
        XCTAssertEqual(KeyMap.windowsKey(for: 58), WindowsKey(vk: 0xA4, extended: false)) // Option -> LAlt
    }

    func testReverseKeyMapForInjection() {
        // Windows VK -> macOS key code, for injecting keys when this Mac is controlled.
        XCTAssertEqual(KeyMap.macKeyCode(forVK: 0x41), 0)   // A
        XCTAssertEqual(KeyMap.macKeyCode(forVK: 0x59), 16)  // Y
        XCTAssertEqual(KeyMap.macKeyCode(forVK: 0x5A), 6)   // Z
        XCTAssertEqual(KeyMap.macKeyCode(forVK: 0x0D), 36)  // Return (prefers main-block over keypad)
        XCTAssertEqual(KeyMap.macKeyCode(forVK: 0x25), 123) // Left arrow
        XCTAssertNil(KeyMap.macKeyCode(forVK: 0xFFFF))
    }

    func testModifierFlagDetection() {
        // Left command down: its device bit (0x08) is set.
        XCTAssertTrue(KeyMap.isModifierPressed(keyCode: 55, flags: CGEventFlags(rawValue: 0x0000_0008 | 0x0010_0000)))
        // Command family flag but the *right* command bit → left command reads as up.
        XCTAssertFalse(KeyMap.isModifierPressed(keyCode: 55, flags: CGEventFlags(rawValue: 0x0000_0010)))
        XCTAssertTrue(KeyMap.isModifierPressed(keyCode: 54, flags: CGEventFlags(rawValue: 0x0000_0010)))
        XCTAssertEqual(KeyMap.heldChordKeyCode(family: .command, flags: CGEventFlags(rawValue: 0x0000_0008)), 55)
        XCTAssertEqual(KeyMap.heldChordKeyCode(family: .option, flags: CGEventFlags(rawValue: 0x0000_0040)), 61)
        XCTAssertNil(KeyMap.heldChordKeyCode(family: .option, flags: CGEventFlags(rawValue: 0x0000_0008)))
    }

    // MARK: - NVDA chord (Command+Option → Insert) — the three reported bugs

    private let lCmd: Int64 = 55, lOpt: Int64 = 58
    private let cmdBit: UInt64 = 0x0000_0008, optBit: UInt64 = 0x0000_0020
    private func ins(_ pressed: Bool) -> ChordProcessor.Action {
        ChordProcessor.Action(vk: 0x2D, extended: true, pressed: pressed)
    }
    private func lwin(_ pressed: Bool) -> ChordProcessor.Action {
        ChordProcessor.Action(vk: 0x5B, extended: true, pressed: pressed)
    }
    private func lalt(_ pressed: Bool) -> ChordProcessor.Action {
        ChordProcessor.Action(vk: 0xA4, extended: false, pressed: pressed)
    }

    /// Pressing Option then Command sends Insert exactly once (down), with no phantom
    /// Alt/Windows tap. Releasing both sends Insert up exactly once. Reported bug: NVDA
    /// never arrived / Alt+NVDA leaked afterwards.
    func testChordOptionThenCommandProducesCleanInsert() {
        var chord = ChordProcessor()
        // Option down (only Option held): deferred, nothing sent.
        XCTAssertEqual(chord.modifierChanged(keyCode: lOpt, pressed: true, flags: optBit, chordEnabled: true), [])
        // Command down (now both held): NVDA key, Insert down, no Alt/Win tap.
        XCTAssertEqual(chord.modifierChanged(keyCode: lCmd, pressed: true, flags: cmdBit | optBit, chordEnabled: true), [ins(true)])
        // Release Command (Option still down): chord ends, Insert up.
        XCTAssertEqual(chord.modifierChanged(keyCode: lCmd, pressed: false, flags: optBit, chordEnabled: true), [ins(false)])
        // Release Option: it was only re-deferred, so nothing is sent.
        XCTAssertEqual(chord.modifierChanged(keyCode: lOpt, pressed: false, flags: 0, chordEnabled: true), [])
        XCTAssertFalse(chord.nvdaActive)
        XCTAssertTrue(chord.forwarded.isEmpty)
        XCTAssertTrue(chord.deferred.isEmpty)
    }

    /// Command then Option: identical clean result. And critically, pressing Option ALONE
    /// afterwards yields plain Alt — never the "Alt+NVDA" the stale-state bug produced.
    func testLoneOptionAfterChordIsPlainAlt() {
        var chord = ChordProcessor()
        _ = chord.modifierChanged(keyCode: lCmd, pressed: true, flags: cmdBit, chordEnabled: true)
        _ = chord.modifierChanged(keyCode: lOpt, pressed: true, flags: cmdBit | optBit, chordEnabled: true)
        _ = chord.modifierChanged(keyCode: lOpt, pressed: false, flags: cmdBit, chordEnabled: true)
        _ = chord.modifierChanged(keyCode: lCmd, pressed: false, flags: 0, chordEnabled: true)
        XCTAssertFalse(chord.nvdaActive)

        // Now Option alone, then a letter, then release: Alt down, key, Alt up. No Insert.
        XCTAssertEqual(chord.modifierChanged(keyCode: lOpt, pressed: true, flags: optBit, chordEnabled: true), [])
        XCTAssertEqual(chord.normalKeyDown(), [lalt(true)]) // flushed when a real key is pressed
        XCTAssertEqual(chord.modifierChanged(keyCode: lOpt, pressed: false, flags: 0, chordEnabled: true), [lalt(false)])
        XCTAssertFalse(chord.nvdaActive)
    }

    /// NVDA+letter: hold the chord, press N, N goes through while Insert stays down.
    func testChordPlusLetter() {
        var chord = ChordProcessor()
        _ = chord.modifierChanged(keyCode: lCmd, pressed: true, flags: cmdBit, chordEnabled: true)
        XCTAssertEqual(chord.modifierChanged(keyCode: lOpt, pressed: true, flags: cmdBit | optBit, chordEnabled: true), [ins(true)])
        // A letter while the chord is held: nothing extra is flushed (Insert already down).
        XCTAssertEqual(chord.normalKeyDown(), [])
        XCTAssertTrue(chord.nvdaActive)
        // Release both → Insert up once.
        XCTAssertEqual(chord.modifierChanged(keyCode: lOpt, pressed: false, flags: cmdBit, chordEnabled: true), [ins(false)])
        _ = chord.modifierChanged(keyCode: lCmd, pressed: false, flags: 0, chordEnabled: true)
        XCTAssertTrue(chord.forwarded.isEmpty)
    }

    /// The Command (Windows) key on its own must actually be sent — reported bug: it was
    /// "barely sent at all".
    func testLoneCommandIsSentAsWindowsKey() {
        var chord = ChordProcessor()
        // Command down alone: deferred until a key confirms intent.
        XCTAssertEqual(chord.modifierChanged(keyCode: lCmd, pressed: true, flags: cmdBit, chordEnabled: true), [])
        // Press a letter → LWin down is flushed first.
        XCTAssertEqual(chord.normalKeyDown(), [lwin(true)])
        // Release Command → LWin up.
        XCTAssertEqual(chord.modifierChanged(keyCode: lCmd, pressed: false, flags: 0, chordEnabled: true), [lwin(false)])
    }

    /// With the chord setting off, Command is the Windows key immediately (no deferral),
    /// and Command+Option is just Win+Alt — never Insert.
    func testChordDisabledForwardsImmediately() {
        var chord = ChordProcessor()
        XCTAssertEqual(chord.modifierChanged(keyCode: lCmd, pressed: true, flags: cmdBit, chordEnabled: false), [lwin(true)])
        XCTAssertEqual(chord.modifierChanged(keyCode: lOpt, pressed: true, flags: cmdBit | optBit, chordEnabled: false), [lalt(true)])
        XCTAssertFalse(chord.nvdaActive)
        _ = chord.modifierChanged(keyCode: lOpt, pressed: false, flags: cmdBit, chordEnabled: false)
        _ = chord.modifierChanged(keyCode: lCmd, pressed: false, flags: 0, chordEnabled: false)
        XCTAssertTrue(chord.forwarded.isEmpty)
    }

    /// Handing control back releases everything still down (no stuck keys on the remote).
    func testReleaseAllClearsHeldKeys() {
        var chord = ChordProcessor()
        _ = chord.modifierChanged(keyCode: lCmd, pressed: true, flags: cmdBit, chordEnabled: true)
        _ = chord.modifierChanged(keyCode: lOpt, pressed: true, flags: cmdBit | optBit, chordEnabled: true)
        let released = chord.releaseAll()
        XCTAssertEqual(released, [ins(false)])
        XCTAssertFalse(chord.nvdaActive)
        XCTAssertTrue(chord.forwarded.isEmpty)
        XCTAssertTrue(chord.deferred.isEmpty)
    }

    /// A lone Command tapped and released within the grace window is sent as a full tap,
    /// so pressing just Command opens the Start menu. Reported bug: nothing happened.
    func testLoneCommandTapSendsFullTap() {
        var chord = ChordProcessor()
        XCTAssertEqual(chord.modifierChanged(keyCode: lCmd, pressed: true, flags: cmdBit, chordEnabled: true), [])
        XCTAssertEqual(chord.modifierChanged(keyCode: lCmd, pressed: false, flags: 0, chordEnabled: true),
                       [lwin(true), lwin(false)])
        XCTAssertTrue(chord.forwarded.isEmpty)
        XCTAssertTrue(chord.deferred.isEmpty)
    }

    /// A lone Option held past the grace window commits (via the timer's commitDeferred)
    /// to Alt-down; releasing it then sends Alt-up.
    func testLoneOptionHeldCommitsToAlt() {
        var chord = ChordProcessor()
        XCTAssertEqual(chord.modifierChanged(keyCode: lOpt, pressed: true, flags: optBit, chordEnabled: true), [])
        XCTAssertEqual(chord.commitDeferred(), [lalt(true)]) // grace window elapsed
        XCTAssertEqual(chord.modifierChanged(keyCode: lOpt, pressed: false, flags: 0, chordEnabled: true), [lalt(false)])
    }

    /// After the grace window commits Command to Windows, a later Option is NOT folded
    /// into an NVDA chord — the two were not pressed together.
    func testSecondHalfAfterCommitIsPlainModifier() {
        var chord = ChordProcessor()
        _ = chord.modifierChanged(keyCode: lCmd, pressed: true, flags: cmdBit, chordEnabled: true)
        XCTAssertEqual(chord.commitDeferred(), [lwin(true)]) // Command committed to Windows
        // Now Option: Command is already committed, so no chord — Option just defers.
        XCTAssertEqual(chord.modifierChanged(keyCode: lOpt, pressed: true, flags: cmdBit | optBit, chordEnabled: true), [])
        XCTAssertFalse(chord.nvdaActive)
        XCTAssertEqual(chord.commitDeferred(), [lalt(true)])
    }

    // MARK: - Keyboard layout: map by produced character, not US physical position

    func testCharacterToWindowsVK() {
        func vk(_ c: Character) -> Int? { LayoutMapper.characterToVK[c]?.vk }
        // Letters map by letter (the y/z swap bug: 'z' must be VK_Z, not VK_Y).
        XCTAssertEqual(vk("z"), 0x5A)
        XCTAssertEqual(vk("y"), 0x59)
        XCTAssertEqual(vk("a"), 0x41)
        // Digits.
        XCTAssertEqual(vk("1"), 0x31)
        // German umlauts and ß map to the German OEM virtual keys.
        XCTAssertEqual(vk("ö"), 0xC0)
        XCTAssertEqual(vk("ä"), 0xDE)
        XCTAssertEqual(vk("ü"), 0xBA)
        XCTAssertEqual(vk("ß"), 0xDB)
        // US punctuation still resolves for US-layout users.
        XCTAssertEqual(vk(";"), 0xBA)
        XCTAssertEqual(vk("["), 0xDB)
        // Shared punctuation.
        XCTAssertEqual(vk(","), 0xBC)
        XCTAssertEqual(vk("-"), 0xBD)
    }

    func testCharacterKeyCodesCoverLettersNotNavigation() {
        XCTAssertTrue(KeyMap.characterKeyCodes.contains(6))  // Z key
        XCTAssertTrue(KeyMap.characterKeyCodes.contains(16)) // Y-position key
        XCTAssertTrue(KeyMap.characterKeyCodes.contains(41)) // ; / ö key
        XCTAssertFalse(KeyMap.characterKeyCodes.contains(123)) // left arrow — stays positional
        XCTAssertFalse(KeyMap.characterKeyCodes.contains(36))  // return — stays positional
        XCTAssertFalse(KeyMap.characterKeyCodes.contains(49))  // space — stays positional
    }
}
