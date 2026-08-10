import AppKit
import CoreGraphics

/// Captures the keyboard with a CGEvent tap while a session is connected.
///
/// F10 (or fn+F10, depending on the Mac's function-key setting — whatever produces a
/// real F10 key event) toggles control. While controlling, every key event is swallowed
/// locally and forwarded to the controlled computer as a Windows key message.
///
/// The NVDA key: most Mac keyboards have no Insert. When the corresponding setting is
/// on (default), holding Command and Option together sends Insert down until one of the
/// two is released — so Command+Option+N is NVDA+N on the remote machine. With the
/// setting off, Command stays the Windows key and Option the Alt key, and only a real
/// Insert/Help key (PC keyboards) produces Insert.
///
/// Modifier state is read from each event's own flags (the device-dependent left/right
/// bits), never from a self-maintained toggle set: a single missed event would otherwise
/// invert a modifier's sense for the rest of the session.
final class KeyCapture {
    /// Called on F10 key-down. Return true to swallow the event (i.e. the toggle was
    /// handled), false to let it through to macOS.
    var onToggleKey: (() -> Bool)?
    /// Forward a key to the remote machine.
    var sendKey: ((_ vk: Int, _ extended: Bool, _ pressed: Bool) -> Void)?

    private(set) var forwarding = false

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// The pure decision logic — see ChordProcessor.
    private var chord = ChordProcessor()
    /// Fires when a lone Command/Option has waited out the grace window and should commit
    /// to being its ordinary Windows/Alt key.
    private var commitTimer: DispatchSourceTimer?

    private func emit(_ actions: [ChordProcessor.Action]) {
        for action in actions {
            sendKey?(action.vk, action.extended, action.pressed)
        }
    }

    /// Keep the commit timer in step with whether a lone modifier is waiting. Runs on the
    /// main queue, the same thread the event tap is serviced on, so `chord` is never
    /// touched concurrently.
    private func updateCommitTimer() {
        if chord.deferred.isEmpty {
            commitTimer?.cancel()
            commitTimer = nil
            return
        }
        if commitTimer != nil { return } // a window is already counting down
        let latency = max(0, AppSettings.shared.nvdaChordLatencyMs)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(Int(latency)))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.commitTimer = nil
            self.emit(self.chord.commitDeferred())
        }
        timer.resume()
        commitTimer = timer
    }

    static func ensureAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Tap lifecycle

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let capture = Unmanaged<KeyCapture>.fromOpaque(userInfo).takeUnretainedValue()
            return capture.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        setForwarding(false)
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            self.tap = nil
        }
    }

    /// Start or stop forwarding keys. When stopping, every key we still hold on the
    /// remote machine is released, so nothing stays stuck down over there.
    func setForwarding(_ enabled: Bool) {
        guard enabled != forwarding else { return }
        if !enabled {
            commitTimer?.cancel()
            commitTimer = nil
            emit(chord.releaseAll())
        }
        forwarding = enabled
    }

    // MARK: - Event handling

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        case .flagsChanged:
            return handleFlagsChanged(event)
        case .keyDown, .keyUp:
            return handleKey(type: type, event: event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleKey(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let pressed = type == .keyDown
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        if keyCode == KeyMap.f10KeyCode {
            if pressed && !isRepeat {
                if onToggleKey?() == true {
                    return nil
                }
                return Unmanaged.passUnretained(event)
            }
            // Swallow F10 repeats/key-up while we are (or just were) in control, so a
            // toggle never leaks half an event to macOS.
            return forwarding ? nil : Unmanaged.passUnretained(event)
        }

        guard forwarding else { return Unmanaged.passUnretained(event) }

        // A real key is being pressed: any Command/Option we were holding back is meant
        // as its ordinary modifier after all, so send it down first.
        if pressed {
            emit(chord.normalKeyDown())
            updateCommitTimer()
        }

        // Character-block keys map by the character the Mac's layout produces (so a German
        // keyboard sends z/y and ö/ä/ü/ß correctly); everything else stays positional.
        if let key = LayoutMapper.windowsKey(for: event, keyCode: keyCode) ?? KeyMap.windowsKey(for: keyCode) {
            sendKey?(key.vk, key.extended, pressed)
        }
        return nil
    }

    private func handleFlagsChanged(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard forwarding else { return Unmanaged.passUnretained(event) }
        guard KeyMap.modifierKeyCodes.contains(keyCode) else { return nil }

        let pressed = KeyMap.isModifierPressed(keyCode: keyCode, flags: event.flags)
        emit(chord.modifierChanged(
            keyCode: keyCode,
            pressed: pressed,
            flags: event.flags.rawValue,
            chordEnabled: AppSettings.shared.nvdaKeyCommandOption
        ))
        updateCommitTimer()
        return nil
    }
}
