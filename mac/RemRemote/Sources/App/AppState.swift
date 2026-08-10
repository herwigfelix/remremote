import AppKit
import Combine

/// Central coordinator: owns the session and all subsystems, and exposes observable
/// state for SwiftUI.
@MainActor
final class AppState: ObservableObject {
    enum ConnectionStatus: Equatable {
        case disconnected
        case connecting
        case connectedWaitingForSlave
        case connected
    }

    struct CertificatePrompt: Identifiable {
        let id = UUID()
        let fingerprint: String
        let address: String
    }

    @Published private(set) var status: ConnectionStatus = .disconnected
    @Published private(set) var controlling = false
    @Published private(set) var audioState: AudioStreamController.State = .off
    @Published private(set) var clipboardSyncEnabled = false
    /// True while the controlled machine is a Mac — audio is then mandatory and the
    /// toggle is disabled in the UI.
    @Published private(set) var audioForced = false
    /// True once we know the controlled machine is a Mac (for UI hints).
    @Published private(set) var remoteIsMac = false
    /// True while this Mac is the controlled machine (the slave role).
    @Published private(set) var controlledMode = false
    @Published var certificatePrompt: CertificatePrompt?
    @Published var motdText: String?
    @Published var voiceOverHint: String?
    @Published var lastError: String?

    let settings = AppSettings.shared
    let computers = SavedComputersStore()
    let permissions = Permissions()

    private(set) var session: RemoteSession?
    private var slave: SlaveController?
    private let keyCapture = KeyCapture()
    private let cues = CuePlayer()
    private let tones = TonePlayer()
    private var speechOutput: SpeechOutput
    private let audio = AudioStreamController()
    private let clipboard = ClipboardSyncController()
    private var cancellables: Set<AnyCancellable> = []

    init() {
        speechOutput = Self.makeSpeechOutput(settings)
        audio.onStateChanged = { [weak self] state in
            DispatchQueue.main.async { self?.audioState = state }
        }
        audio.announce = { [weak self] text in
            DispatchQueue.main.async { self?.announce(text) }
        }
        audio.onForcedChanged = { [weak self] forced in
            DispatchQueue.main.async { self?.audioForced = forced }
        }
        clipboard.onStateChanged = { [weak self] enabled in
            DispatchQueue.main.async { self?.clipboardSyncEnabled = enabled }
        }
        clipboard.announce = { [weak self] text in
            DispatchQueue.main.async { self?.announce(text) }
        }
        clipboard.playReceivedCue = { [weak self] in
            self?.cues.play(.clipboardReceived)
        }
        keyCapture.onToggleKey = { [weak self] in
            guard let self else { return false }
            return self.handleToggleKey()
        }
        keyCapture.sendKey = { [weak self] vk, extended, pressed in
            self?.session?.sendKey(vkCode: vk, extended: extended, pressed: pressed)
        }
        // Swap the speech output when the mode changes. @Published emits on willSet, so
        // use the emitted value — the property itself still holds the old mode here.
        // Voice, rate and pitch need no rebuild: DirectTTSSpeech reads them per utterance.
        settings.$speechMode
            .dropFirst()
            .sink { [weak self] mode in self?.rebuildSpeechOutput(mode: mode) }
            .store(in: &cancellables)
    }

    private static func makeSpeechOutput(mode: SpeechOutputMode, settings: AppSettings) -> SpeechOutput {
        switch mode {
        case .voiceOver: return VoiceOverSpeech()
        case .directTTS: return DirectTTSSpeech(settings: settings)
        }
    }

    private static func makeSpeechOutput(_ settings: AppSettings) -> SpeechOutput {
        makeSpeechOutput(mode: settings.speechMode, settings: settings)
    }

    private func rebuildSpeechOutput(mode: SpeechOutputMode) {
        speechOutput.shutdown()
        speechOutput = Self.makeSpeechOutput(mode: mode, settings: settings)
    }

    /// App status messages (the equivalent of NVDA's ui.message) go through the same
    /// speech output as remote speech.
    func announce(_ text: String) {
        speechOutput.speak([.text(text)], priority: 0)
    }

    // MARK: - Connecting

    func connect(host: String, port: UInt16, key: String, encryptionPassword: String?) {
        disconnect()
        lastError = nil
        let configuration = SessionConfiguration(
            host: host,
            port: port,
            key: key,
            encryptionPassword: (encryptionPassword?.isEmpty ?? true) ? nil : encryptionPassword
        )
        let session = RemoteSession(configuration: configuration)
        self.session = session
        registerMessageHandlers(on: session)
        audio.attach(to: session)
        clipboard.attach(to: session)
        session.onEvent = { [weak self] event in
            self?.handleSessionEvent(event)
        }
        status = .connecting
        session.connect()
    }

    func connect(to computer: SavedComputer) {
        guard let secrets = computers.secrets(for: computer) else {
            lastError = String(localized: "The key for this computer could not be read from the keychain.")
            return
        }
        connect(host: computer.host, port: computer.port, key: secrets.key, encryptionPassword: secrets.encryptionPassword)
    }

    /// Let this Mac be controlled (the slave role), over the relay only.
    func connectAsControlled(host: String, port: UInt16, key: String, encryptionPassword: String?) {
        disconnect()
        lastError = nil
        controlledMode = true
        let configuration = SessionConfiguration(
            host: host, port: port, key: key,
            encryptionPassword: (encryptionPassword?.isEmpty ?? true) ? nil : encryptionPassword
        )
        let slave = SlaveController(configuration: configuration)
        self.slave = slave
        slave.onState = { [weak self] slaveState in
            DispatchQueue.main.async { self?.applySlaveState(slaveState) }
        }
        slave.onError = { [weak self] text in
            DispatchQueue.main.async { self?.lastError = text }
        }
        status = .connecting
        slave.connect()
    }

    private func applySlaveState(_ slaveState: SlaveController.State) {
        switch slaveState {
        case .connecting: status = .connecting
        case .waitingForController:
            if status == .connected { cues.play(.disconnected) }
            status = .connectedWaitingForSlave
        case .controlled:
            status = .connected
            cues.play(.controlled)
        }
    }

    func disconnect() {
        if let slave {
            slave.disconnect()
            self.slave = nil
            controlledMode = false
            if status != .disconnected {
                status = .disconnected
                cues.play(.disconnected)
                announce(String(localized: "Disconnected"))
            }
            return
        }
        guard let session else { return }
        // Detach first: close() fires a disconnect event, which would otherwise announce
        // "connection interrupted" on top of our own "disconnected".
        session.onEvent = nil
        setControlling(false)
        audio.shutdown()
        clipboard.shutdown()
        keyCapture.stop()
        session.close()
        self.session = nil
        remoteIsMac = false
        if status != .disconnected {
            status = .disconnected
            cues.play(.disconnected)
            announce(String(localized: "Disconnected"))
        }
    }

    // MARK: - Autoconnect (on launch)

    func startupAutoConnect() {
        guard settings.autoConnectEnabled, permissions.canConnect else { return }
        let (host, port) = ConnectView.parse(address: settings.autoConnectHost)
        guard !host.isEmpty else { return }
        let secrets = KeychainStore.load(for: AppSettings.autoConnectKeychainID)
        let key = secrets?.key ?? ""
        guard !key.isEmpty else { return }
        let enc = secrets?.encryptionPassword
        if settings.autoConnectControlled {
            connectAsControlled(host: host, port: port, key: key, encryptionPassword: enc)
        } else {
            connect(host: host, port: port, key: key, encryptionPassword: enc)
        }
    }

    private func registerMessageHandlers(on session: RemoteSession) {
        session.register("speak") { [weak self] message in
            guard let self else { return }
            let raw = message["sequence"] as? [Any] ?? []
            let priority = (message["priority"] as? Int) ?? 0
            self.speechOutput.speak(SpeechSequenceItem.parse(raw), priority: priority)
        }
        session.register("cancel") { [weak self] _ in
            self?.speechOutput.cancel()
        }
        session.register("pause_speech") { [weak self] message in
            self?.speechOutput.pause(message["switch"] as? Bool ?? false)
        }
        session.register("tone") { [weak self] message in
            guard let self else { return }
            func number(_ key: String) -> Double? {
                (message[key] as? Double) ?? (message[key] as? Int).map(Double.init)
            }
            self.tones.beep(
                hz: number("hz") ?? 0,
                lengthMs: number("length") ?? 0,
                left: number("left") ?? 50,
                right: number("right") ?? 50
            )
        }
        session.register("wave") { _ in
            // Wave files reference paths on the controlled machine; nothing to play here.
        }
        session.register("nvda_not_connected") { [weak self] _ in
            self?.announce(String(localized: "Remote NVDA not connected."))
        }
    }

    private func handleSessionEvent(_ event: SessionEvent) {
        switch event {
        case .connectionEstablished:
            status = session?.hasPeer == true ? .connected : .connectedWaitingForSlave
            cues.play(.connected)
            announce(String(localized: "Connected!"))
            if !KeyCapture.ensureAccessibilityPermission() {
                lastError = String(localized: "remremote needs accessibility permission to capture the keyboard. Grant it in System Settings > Privacy & Security > Accessibility, then reconnect.")
            }
            keyCapture.start()
        case .connectionFailed(let error):
            status = .connecting // the session keeps retrying every few seconds
            if let error {
                lastError = String(localized: "Connection failed: \(error.localizedDescription)")
            }
        case .disconnected:
            setControlling(false)
            audio.setForced(false)
            audio.shutdown()
            keyCapture.stop()
            remoteIsMac = false
            if status == .connected || status == .connectedWaitingForSlave {
                cues.play(.disconnected)
                announce(String(localized: "Connection interrupted"))
            }
            status = session == nil ? .disconnected : .connecting
        case .certificateUntrusted(let fingerprint):
            status = .disconnected
            certificatePrompt = CertificatePrompt(
                fingerprint: fingerprint ?? String(localized: "unknown"),
                address: session?.configuration.address ?? ""
            )
        case .peerJoined:
            status = .connected
            cues.play(.connected)
        case .peerLeft:
            setControlling(false)
            audio.setForced(false)
            remoteIsMac = false
            status = .connectedWaitingForSlave
            cues.play(.disconnected)
        case .peerOSKnown(let os):
            handlePeerOS(os)
        case .motd(let text):
            motdText = text
        case .serverError(let text):
            lastError = text
        }
    }

    /// The controlled machine told us its OS. Controlling a Mac means its output can only
    /// be heard as audio, so audio becomes mandatory; and since this app runs on a Mac,
    /// a Mac↔Mac session warns once about the VoiceOver-key conflict.
    private func handlePeerOS(_ os: String) {
        let isMac = os == "macos"
        remoteIsMac = isMac
        audio.setForced(isMac)
        if isMac, !settings.voiceOverConflictHintShown {
            settings.voiceOverConflictHintShown = true
            voiceOverHint = String(localized: "You are controlling another Mac. VoiceOver on this Mac and on the remote Mac use the same keys, which can clash while you send keystrokes. To avoid it, either turn VoiceOver off on this Mac, or set the two machines to different VoiceOver modifier keys (for example Control+Option on one and Caps Lock on the other).")
        }
    }

    // MARK: - Certificate trust

    func acceptCertificate(save: Bool) {
        guard let prompt = certificatePrompt, let session else { return }
        certificatePrompt = nil
        session.sessionTrustedFingerprints.insert(prompt.fingerprint)
        if save {
            settings.trustFingerprint(prompt.fingerprint, for: prompt.address)
        }
        status = .connecting
        session.connect(extraTrustedFingerprints: session.sessionTrustedFingerprints)
    }

    func rejectCertificate() {
        certificatePrompt = nil
        disconnect()
    }

    // MARK: - Control toggle (F10)

    private func handleToggleKey() -> Bool {
        guard let session, session.connectedToServer, session.hasPeer else { return false }
        setControlling(!controlling)
        return true
    }

    private func setControlling(_ enabled: Bool) {
        guard enabled != controlling else {
            keyCapture.setForwarding(enabled)
            return
        }
        controlling = enabled
        keyCapture.setForwarding(enabled)
        if enabled {
            cues.play(.controlling)
            announce(String(localized: "Controlling remote machine."))
        } else {
            cues.play(.controlled)
            announce(String(localized: "Controlling local machine."))
        }
    }

    // MARK: - Feature toggles for the UI

    func toggleAudio() { audio.toggleAudio() }
    func toggleRemoteTTS() { audio.toggleRemoteTTS() }
    func toggleClipboardSync() { clipboard.toggle() }
    func pushClipboard() {
        clipboard.pushClipboard()
        cues.play(.clipboardPushed)
    }
}
