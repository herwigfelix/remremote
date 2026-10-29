import AppKit

/// Two-way clipboard synchronisation (remremote extension). While enabled, text copied
/// on either machine is pushed to the other. The toggle is shared state: either side
/// may flip it, the peer adopts it without echoing back. Text only, capped at 100 000
/// characters. macOS has no clipboard-change notification, so we poll the change count.
final class ClipboardSyncController {
    private(set) var enabled = false {
        didSet { onStateChanged?(enabled) }
    }

    var onStateChanged: ((Bool) -> Void)?
    var announce: ((String) -> Void)?
    var playReceivedCue: (() -> Void)?

    private weak var session: RemoteSession?
    private var pollTimer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var lastText: String?

    private static let maxSyncLength = 100_000
    private static let pollInterval: TimeInterval = 0.5

    func attach(to session: RemoteSession) {
        self.session = session
        session.register("clipboard_sync") { [weak self] message in
            guard let self, let state = message["state"] as? Bool, state != self.enabled else { return }
            self.apply(state, fromPeer: true)
        }
        session.register("clipboard_sync_text") { [weak self] message in
            guard let self, self.enabled,
                  let text = message["text"] as? String, !text.isEmpty,
                  text != self.lastText else { return }
            self.lastText = text
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            self.lastChangeCount = NSPasteboard.general.changeCount
            self.playReceivedCue?()
        }
        // The classic one-shot "push clipboard" of NVDA Remote.
        session.register("set_clipboard_text") { [weak self] message in
            guard let self, let text = message["text"] as? String else { return }
            // Remember it as ours: with sync on, the poller would otherwise see this write
            // as a fresh local copy and bounce it straight back to the sender.
            self.lastText = text
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            self.lastChangeCount = NSPasteboard.general.changeCount
            self.playReceivedCue?()
            self.announce?(String(localized: "Clipboard updated"))
        }
    }

    func shutdown() {
        stopPolling()
        enabled = false
        lastText = nil
        session = nil
    }

    /// Turn sync off locally without telling the peer — for a dropped link or a peer that
    /// left. The other side resets its own state the same way, so the two never disagree
    /// about the toggle after a reconnect.
    func reset() {
        stopPolling()
        enabled = false
        lastText = nil
    }

    func toggle() {
        guard let session, session.connectedToServer else {
            announce?(String(localized: "Not connected."))
            return
        }
        apply(!enabled, fromPeer: false)
    }

    /// One-shot push of the current clipboard to the other machines.
    func pushClipboard() {
        guard let session, session.connectedToServer else {
            announce?(String(localized: "Not connected."))
            return
        }
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            announce?(String(localized: "The clipboard contains no text."))
            return
        }
        session.send(type: "set_clipboard_text", ["text": text])
        announce?(String(localized: "Clipboard pushed"))
    }

    private func apply(_ state: Bool, fromPeer: Bool) {
        enabled = state
        if state {
            startPolling()
        } else {
            stopPolling()
            lastText = nil
        }
        if !fromPeer {
            session?.send(type: "clipboard_sync", ["state": state])
        }
        if state {
            announce?(fromPeer
                ? String(localized: "Clipboard sync turned on by the other computer")
                : String(localized: "Clipboard sync on"))
            if !fromPeer {
                // Seed the peer with what we have, so both sides match straight away.
                sendCurrentClipboard()
            }
        } else {
            announce?(fromPeer
                ? String(localized: "Clipboard sync turned off by the other computer")
                : String(localized: "Clipboard sync off"))
        }
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.pollClipboard()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollClipboard() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        sendCurrentClipboard()
    }

    private func sendCurrentClipboard() {
        guard enabled, let session, session.connectedToServer else { return }
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        guard text != lastText else { return } // our own write, or unchanged
        guard text.count <= Self.maxSyncLength else { return }
        lastText = text
        session.send(type: "clipboard_sync_text", ["text": text])
    }
}
