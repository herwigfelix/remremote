import Foundation
import CoreGraphics

/// The pure decision logic behind key forwarding: given modifier changes and normal key
/// presses, it produces the sequence of Windows key actions to send. Kept free of
/// CGEvent/AppKit timing so it can be unit-tested exhaustively (KeyCapture is the thin
/// CGEvent adapter around it, and owns the commit timer).
///
/// The hard part is the NVDA key. Most Mac keyboards have no Insert, so holding Command
/// and Option together stands in for it — but only when they are pressed *together*.
/// A lone Command or Option is held back briefly; the caller commits it (via
/// `commitDeferred`, driven by a timer) into its ordinary Windows/Alt key once the grace
/// window elapses, or `normalKeyDown` flushes it the instant another key is pressed. If
/// the lone key is instead released within the window, it is sent as a clean tap so a
/// single Windows-key or Alt press still works (e.g. opening the Start menu). Pressed
/// together within the window, the two become Insert and nothing else.
struct ChordProcessor {
    struct Action: Equatable {
        let vk: Int
        let extended: Bool
        let pressed: Bool
    }

    /// Modifiers currently sent "down" to the remote machine.
    private(set) var forwarded: [Int64: WindowsKey] = [:]
    /// Command/Option physically down but not yet forwarded (purpose still unknown).
    private(set) var deferred: Set<Int64> = []
    /// Subset of `deferred` that, if released before committing, should be sent as a tap
    /// (a genuine lone press). A half left over from a broken chord is not tap-eligible —
    /// releasing it must stay silent.
    private var tapEligible: Set<Int64> = []
    /// True while the Command+Option → Insert chord is held.
    private(set) var nvdaActive = false

    // MARK: - Events

    /// A modifier key changed state. `flags` is the event's raw CGEventFlags value, used
    /// as the sole source of truth for what is currently down.
    mutating func modifierChanged(keyCode: Int64, pressed: Bool, flags: UInt64, chordEnabled: Bool) -> [Action] {
        if keyCode == KeyMap.function {
            return []
        }
        if keyCode == KeyMap.capsLock {
            // Windows toggles caps lock on key-down; each macOS state change is one tap.
            return [Action(vk: 0x14, extended: false, pressed: true),
                    Action(vk: 0x14, extended: false, pressed: false)]
        }

        let isChordKey = KeyMap.commandKeyCodes.contains(keyCode) || KeyMap.optionKeyCodes.contains(keyCode)
        if chordEnabled && isChordKey {
            return chordModifierChanged(keyCode: keyCode, pressed: pressed, flags: flags)
        }

        // Shift/Control (or Command/Option with the chord setting off): forward verbatim.
        if pressed {
            guard let key = KeyMap.windowsKey(for: keyCode) else { return [] }
            forwarded[keyCode] = key
            return [Action(vk: key.vk, extended: key.extended, pressed: true)]
        } else if let key = forwarded.removeValue(forKey: keyCode) {
            return [Action(vk: key.vk, extended: key.extended, pressed: false)]
        }
        return []
    }

    private mutating func chordModifierChanged(keyCode: Int64, pressed: Bool, flags: UInt64) -> [Action] {
        if pressed {
            if nvdaActive { return [] }
            if otherHalfDeferred(keyCode) {
                // Both halves are down within the grace window: the NVDA key.
                return enterChord()
            }
            deferred.insert(keyCode)
            tapEligible.insert(keyCode)
            return []
        }

        // Released.
        if nvdaActive {
            // The NVDA key is the chord itself; releasing either half ends it.
            nvdaActive = false
            deferred.remove(keyCode)
            tapEligible.remove(keyCode)
            // A half still physically down reverts to a deferred ordinary modifier (not
            // tap-eligible: the user was doing NVDA, not tapping a lone key).
            if let held = KeyMap.heldChordKeyCode(family: .command, flags: CGEventFlags(rawValue: flags)), held != keyCode {
                deferred.insert(held)
            }
            if let held = KeyMap.heldChordKeyCode(family: .option, flags: CGEventFlags(rawValue: flags)), held != keyCode {
                deferred.insert(held)
            }
            return [Action(vk: KeyMap.insert.vk, extended: KeyMap.insert.extended, pressed: false)]
        }
        if let key = forwarded.removeValue(forKey: keyCode) {
            return [Action(vk: key.vk, extended: key.extended, pressed: false)]
        }
        if deferred.remove(keyCode) != nil {
            let wasTap = tapEligible.remove(keyCode) != nil
            if wasTap, let key = KeyMap.windowsKey(for: keyCode) {
                // A genuine lone Command/Option tap → send a full tap so single Windows /
                // Alt presses behave.
                return [Action(vk: key.vk, extended: key.extended, pressed: true),
                        Action(vk: key.vk, extended: key.extended, pressed: false)]
            }
        }
        return []
    }

    /// A normal (non-modifier) key is about to be pressed: flush any deferred
    /// Command/Option as their ordinary modifiers first.
    mutating func normalKeyDown() -> [Action] {
        flushDeferred()
    }

    /// The grace window elapsed with a lone Command/Option still held: commit it to its
    /// ordinary Windows/Alt key. Called by KeyCapture's timer.
    mutating func commitDeferred() -> [Action] {
        flushDeferred()
    }

    /// Release everything still held (used when control is handed back).
    mutating func releaseAll() -> [Action] {
        var actions: [Action] = []
        if nvdaActive {
            actions.append(Action(vk: KeyMap.insert.vk, extended: KeyMap.insert.extended, pressed: false))
            nvdaActive = false
        }
        for key in forwarded.values {
            actions.append(Action(vk: key.vk, extended: key.extended, pressed: false))
        }
        forwarded.removeAll()
        deferred.removeAll()
        tapEligible.removeAll()
        return actions
    }

    // MARK: - Helpers

    private mutating func flushDeferred() -> [Action] {
        guard !deferred.isEmpty else { return [] }
        var actions: [Action] = []
        for keyCode in deferred.sorted() {
            if let key = KeyMap.windowsKey(for: keyCode) {
                forwarded[keyCode] = key
                actions.append(Action(vk: key.vk, extended: key.extended, pressed: true))
            }
        }
        deferred.removeAll()
        tapEligible.removeAll()
        return actions
    }

    private func otherHalfDeferred(_ keyCode: Int64) -> Bool {
        if KeyMap.commandKeyCodes.contains(keyCode) {
            return deferred.contains { KeyMap.optionKeyCodes.contains($0) }
        }
        return deferred.contains { KeyMap.commandKeyCodes.contains($0) }
    }

    private mutating func enterChord() -> [Action] {
        var actions = [Action(vk: KeyMap.insert.vk, extended: KeyMap.insert.extended, pressed: true)]
        // Defensive: retract any Command/Option somehow already flushed.
        for keyCode in forwarded.keys.sorted()
        where KeyMap.commandKeyCodes.contains(keyCode) || KeyMap.optionKeyCodes.contains(keyCode) {
            if let key = forwarded.removeValue(forKey: keyCode) {
                actions.append(Action(vk: key.vk, extended: key.extended, pressed: false))
            }
        }
        deferred.removeAll()
        tapEligible.removeAll()
        nvdaActive = true
        return actions
    }
}
