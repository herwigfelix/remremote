import Foundation

/// The controlling side of remremote's audio extension: asks the controlled computer to
/// stream its audio, receives it, and owns the "use the remote computer's own speech
/// synthesizer" setting (see protocol.md — the slave only mirrors that setting).
final class AudioStreamController {
    /// Streaming state, for the UI.
    enum State {
        case off
        case pending
        case on(remoteTTS: Bool)
    }

    private(set) var state: State = .off {
        didSet { onStateChanged?(state) }
    }

    var onStateChanged: ((State) -> Void)?
    /// Status text for the user, spoken through the active speech output.
    var announce: ((String) -> Void)?

    private weak var session: RemoteSession?
    private let settings: AppSettings
    private var receiver: RemSoundReceiver?
    private var pendingTimer: DispatchSourceTimer?
    private var restartTimer: DispatchSourceTimer?
    /// A fresh random session id generated per stream request; sent in audio_start so both
    /// ends register the same id with the relay when the session turns out to be relayed.
    private var audioSession: Data?

    private static let replyTimeout: TimeInterval = 8
    private static let restartDelay: TimeInterval = 0.9

    init(settings: AppSettings = .shared) {
        self.settings = settings
    }

    func attach(to session: RemoteSession) {
        self.session = session
        session.register("audio_started") { [weak self] message in self?.onAudioStarted(message) }
        session.register("audio_error") { [weak self] message in self?.onAudioError(message) }
        session.register("audio_offer") { [weak self] _ in self?.onAudioOffer() }
        session.register("audio_stopped") { [weak self] _ in self?.onAudioStopped() }
        session.register("remote_tts_request") { [weak self] message in self?.onRemoteTTSRequest(message) }
        session.registerOnConnected { [weak self] in
            // We own the setting: tell the controlled computer where it stands, so its
            // own toggle starts from the right value.
            self?.sendRemoteTTSState()
        }
    }

    func shutdown() {
        cancelTimers()
        receiver?.stop()
        receiver = nil
        state = .off
    }

    // MARK: - Toggles

    func toggleAudio() {
        switch state {
        case .off:
            start(announceRequest: true)
        case .pending, .on:
            stop(announceStop: true)
        }
    }

    var remoteTTSEnabled: Bool { settings.useRemoteTTS }

    func toggleRemoteTTS() {
        setRemoteTTS(!settings.useRemoteTTS, fromPeer: false)
    }

    private func setRemoteTTS(_ enabled: Bool, fromPeer: Bool) {
        settings.useRemoteTTS = enabled
        if fromPeer {
            announce?(enabled
                ? String(localized: "Remote speech synthesizer turned on by the other computer")
                : String(localized: "Remote speech synthesizer turned off by the other computer"))
        } else {
            announce?(enabled
                ? String(localized: "Remote speech synthesizer on")
                : String(localized: "Remote speech synthesizer off"))
        }
        sendRemoteTTSState()
        rebuildIfStreaming()
    }

    private func sendRemoteTTSState() {
        guard let session, session.connectedToServer else { return }
        session.send(type: "remote_tts", ["state": settings.useRemoteTTS])
    }

    private func onRemoteTTSRequest(_ message: [String: Any]) {
        guard let state = message["state"] as? Bool else { return }
        setRemoteTTS(state, fromPeer: true)
    }

    /// Whether the remote machine keeps NVDA in the stream is fixed when its sender
    /// starts, so a changed setting means tearing the stream down and back up.
    private func rebuildIfStreaming() {
        switch state {
        case .off:
            return
        case .pending, .on:
            break
        }
        stop(announceStop: false)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.restartDelay)
        timer.setEventHandler { [weak self] in
            self?.restartTimer = nil
            guard let self, let session = self.session, session.connectedToServer else { return }
            self.start(announceRequest: false)
        }
        timer.resume()
        restartTimer = timer
    }

    // MARK: - Handshake, master side

    private func start(announceRequest: Bool) {
        guard let session, session.connectedToServer else {
            announce?(String(localized: "Not connected."))
            return
        }
        state = .pending
        // This app never hosts the control server. If the slave hosts, it binds its own
        // UDP port (mode "host") and we reach it directly; otherwise the session is
        // relayed and both ends meet at the relay, pairing on this session id.
        var session32 = Data(count: 32)
        _ = session32.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        audioSession = session32
        session.send(type: "audio_start", [
            "master_hosting": false,
            "port": NSNull(),
            "remote_tts": settings.useRemoteTTS,
            "audio_session": session32.base64EncodedString(),
        ])
        if announceRequest {
            announce?(String(localized: "Requesting remote audio..."))
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.replyTimeout)
        timer.setEventHandler { [weak self] in
            guard let self, case .pending = self.state else { return }
            self.pendingTimer = nil
            self.state = .off
            self.announce?(String(localized: "No response. The remote computer may not support audio streaming (remremote required on both ends)."))
        }
        timer.resume()
        pendingTimer = timer
    }

    private func stop(announceStop: Bool) {
        cancelTimers()
        session?.send(type: "audio_stop")
        receiver?.stop()
        receiver = nil
        state = .off
        if announceStop {
            announce?(String(localized: "Remote audio off"))
        }
    }

    private func onAudioStarted(_ message: [String: Any]) {
        guard case .pending = state else { return }
        cancelTimers()
        guard let session else { return }
        let mode = message["mode"] as? String ?? ""
        let remoteTTS = message["remote_tts"] as? Bool ?? false
        guard (mode == "host" || mode == "relay"), let port = message["port"] as? Int, port > 0, port <= 65535 else {
            // mode "connect" would mean we host the connection, which this app never does.
            state = .off
            session.send(type: "audio_stop")
            announce?(String(localized: "Could not start the audio receiver."))
            return
        }
        let password = session.configuration.encryptionPassword?.isEmpty == false
            ? session.configuration.encryptionPassword!
            : session.configuration.key
        // Direct "host" mode: reach the slave itself. "relay" mode: reach the relay (the
        // same host we use for control) and register our session id so it pairs us with
        // the slave. In both cases the host is the control-server host we connected to.
        let relaySession = mode == "relay" ? audioSession : nil
        let receiver = RemSoundReceiver(
            host: session.configuration.host, port: UInt16(port),
            password: password, relaySessionId: relaySession
        )
        receiver.onError = { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                switch error {
                case .passwordMismatch:
                    self.announce?(String(localized: "Audio error: the encryption passwords do not match."))
                case .socketFailed:
                    self.announce?(String(localized: "Could not start the audio receiver."))
                }
            }
        }
        self.receiver = receiver
        receiver.start()
        state = .on(remoteTTS: remoteTTS)
        if remoteTTS {
            announce?(String(localized: "Remote audio on, using the remote computer's speech synthesizer"))
        } else if settings.useRemoteTTS {
            announce?(String(localized: "Remote audio on. The remote computer cannot use its own speech synthesizer, so its speech still arrives as text."))
        } else {
            announce?(String(localized: "Remote audio on"))
        }
    }

    private func onAudioOffer() {
        // The controlled computer wants to share its audio: run the normal handshake.
        if case .off = state {
            start(announceRequest: false)
        }
    }

    private func onAudioStopped() {
        switch state {
        case .off:
            return
        case .pending, .on:
            cancelTimers()
            receiver?.stop()
            receiver = nil
            state = .off
            announce?(String(localized: "The remote computer stopped sharing its audio"))
        }
    }

    private func onAudioError(_ message: [String: Any]) {
        cancelTimers()
        receiver?.stop()
        receiver = nil
        state = .off
        let reason = message["reason"] as? String ?? "unknown"
        switch reason {
        case "relay_unsupported":
            announce?(String(localized: "Audio streaming is not available over relay connections yet. Use a direct connection (control server)."))
        case "dotnet_missing":
            announce?(String(localized: "The remote computer cannot stream audio: the .NET 10 Desktop Runtime is missing there."))
        default:
            announce?(String(localized: "The remote computer could not start audio streaming (\(reason))."))
        }
    }

    private func cancelTimers() {
        pendingTimer?.cancel()
        pendingTimer = nil
        restartTimer?.cancel()
        restartTimer = nil
    }
}
