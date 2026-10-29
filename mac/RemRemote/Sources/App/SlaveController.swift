import Foundation

/// This Mac acting as the controlled (slave) machine, over a relay. It receives keystrokes
/// and injects them, and streams its system audio (the only way its VoiceOver output can
/// reach the controller). Relay-only: it connects to the relay like a master would, joins
/// as "slave", and meets the controller at the relay's UDP audio port.
///
/// Clipboard sync and file transfer are not here: they belong to this Mac in either role,
/// so AppState owns them and hangs them off `session`.
@MainActor
final class SlaveController {
    enum State: Equatable {
        case connecting
        case waitingForController
        case controlled
    }

    let session: RemoteSession
    var onState: ((State) -> Void)?
    var onError: ((String) -> Void)?

    private let keyInjector = KeyInjector()
    private var audioSender: (any AudioSending)?

    init(configuration: SessionConfiguration) {
        session = RemoteSession(configuration: configuration, connectionType: "slave")
        registerHandlers()
        session.onEvent = { [weak self] event in self?.handle(event) }
    }

    func connect() {
        session.connect()
    }

    func disconnect() {
        session.onEvent = nil
        stopAudio()
        keyInjector.releaseAll()
        session.close()
    }

    // MARK: - Handlers

    private func registerHandlers() {
        session.register("key") { [weak self] message in
            guard let self,
                  let vk = message["vk_code"] as? Int,
                  let pressed = message["pressed"] as? Bool else { return }
            let extended = message["extended"] as? Bool ?? false
            let scanCode = message["scan_code"] as? Int ?? 0
            self.keyInjector.handle(vkCode: vk, scanCode: scanCode, extended: extended, pressed: pressed)
        }
        session.register("audio_start") { [weak self] message in self?.onAudioStart(message) }
        session.register("audio_stop") { [weak self] _ in self?.stopAudio() }
    }

    private func handle(_ event: SessionEvent) {
        switch event {
        case .connectionEstablished:
            onState?(session.hasPeer ? .controlled : .waitingForController)
        case .peerJoined:
            onState?(.controlled)
        case .peerLeft:
            stopAudio()
            keyInjector.releaseAll()
            onState?(.waitingForController)
        case .disconnected:
            stopAudio()
            keyInjector.releaseAll()
            onState?(.connecting)
        case .serverError(let text):
            onError?(text)
        case .certificateUntrusted:
            onError?(String(localized: "The relay's certificate could not be verified."))
        default:
            break
        }
    }

    // MARK: - Audio (controlled Mac streams its system audio through the relay)

    private func onAudioStart(_ message: [String: Any]) {
        guard let sessionB64 = message["audio_session"] as? String,
              let sessionData = Data(base64Encoded: sessionB64) else {
            // Only relayed audio is supported when this Mac is controlled.
            session.send(type: "audio_error", ["reason": "relay_unsupported"])
            return
        }
        stopAudio()
        guard #available(macOS 14.2, *) else {
            session.send(type: "audio_error", ["reason": "host_start_failed"])
            onError?(String(localized: "System-audio capture needs macOS 14.2 or newer."))
            return
        }
        let password = session.configuration.encryptionPassword?.isEmpty == false
            ? session.configuration.encryptionPassword!
            : session.configuration.key
        let sender = SystemAudioSender(
            host: session.configuration.host,
            port: session.configuration.port,
            password: password,
            sessionId: sessionData
        )
        audioSender = sender
        sender.start()
        // The relay pairs us with the controller; report relay mode so it registers too.
        session.send(type: "audio_started", [
            "mode": "relay",
            "port": Int(session.configuration.port),
            "remote_tts": false,
        ])
    }

    private func stopAudio() {
        audioSender?.stop()
        audioSender = nil
    }
}
