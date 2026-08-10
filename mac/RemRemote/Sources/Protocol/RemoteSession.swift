import Foundation

/// Connection parameters for one session as the controlling (master) side.
struct SessionConfiguration {
    var host: String
    var port: UInt16
    var key: String
    var encryptionPassword: String?

    var address: String {
        let h = host.lowercased()
        let bracketed = h.contains(":") ? "[\(h)]" : h
        return port == 6837 ? bracketed : "\(bracketed):\(port)"
    }
}

/// High-level session events, delivered on the main queue.
enum SessionEvent {
    case connectionEstablished
    case connectionFailed(Error?)
    case disconnected
    case certificateUntrusted(fingerprint: String?)
    case slaveJoined
    case slaveLeft
    case motd(String)
    case serverError(String)
}

/// The controlling-side session: owns the transport, performs the protocol handshake,
/// fans incoming messages out to registered handlers, and reconnects every few seconds
/// when the link drops — until `close()` is called.
final class RemoteSession {
    typealias Message = [String: Any]

    let configuration: SessionConfiguration

    var onEvent: ((SessionEvent) -> Void)?

    private(set) var transport: ControlTransport?
    private var handlers: [String: [(Message) -> Void]] = [:]
    private var connectedHandlers: [() -> Void] = []
    private var slaveCount = 0
    private var closed = false
    private var reconnectTimer: DispatchSourceTimer?
    private let queue = DispatchQueue.main

    /// True while the TCP/TLS link to the server is up.
    private(set) var connectedToServer = false
    /// True while at least one controlled (slave) computer is in the channel.
    var hasSlave: Bool { slaveCount > 0 }

    init(configuration: SessionConfiguration) {
        self.configuration = configuration
        registerCoreHandlers()
    }

    // MARK: - Handler registry (mirrors the add-on's callback manager)

    func register(_ type: String, _ handler: @escaping (Message) -> Void) {
        handlers[type, default: []].append(handler)
    }

    /// Registers a callback fired each time the server link comes up (initial connect
    /// and every reconnect).
    func registerOnConnected(_ handler: @escaping () -> Void) {
        connectedHandlers.append(handler)
    }

    // MARK: - Lifecycle

    func connect(extraTrustedFingerprints: Set<String> = []) {
        closed = false
        let transport = ControlTransport(
            host: configuration.host,
            port: configuration.port,
            encryptionPassword: configuration.encryptionPassword
        )
        var trusted = Set(AppSettings.shared.trustedFingerprints
            .filter { $0.key == configuration.address }
            .values)
        trusted.formUnion(extraTrustedFingerprints)
        transport.acceptedFingerprints = trusted
        transport.onEvent = { [weak self] event in
            DispatchQueue.main.async { self?.handleTransportEvent(event) }
        }
        self.transport = transport
        transport.connect()
    }

    func close() {
        closed = true
        cancelReconnect()
        transport?.close()
        transport = nil
        if connectedToServer || slaveCount > 0 {
            connectedToServer = false
            slaveCount = 0
            onEvent?(.disconnected)
        }
    }

    private func scheduleReconnect() {
        guard !closed, reconnectTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.cancelReconnect()
            guard !self.closed else { return }
            self.transport?.close()
            self.transport = nil
            self.connect(extraTrustedFingerprints: self.sessionTrustedFingerprints)
        }
        timer.resume()
        reconnectTimer = timer
    }

    private func cancelReconnect() {
        reconnectTimer?.cancel()
        reconnectTimer = nil
    }

    /// Fingerprints the user approved for this session only ("connect once").
    var sessionTrustedFingerprints: Set<String> = []

    // MARK: - Transport events

    private func handleTransportEvent(_ event: ControlTransport.Event) {
        switch event {
        case .connected:
            connectedToServer = true
            transport?.send(type: "protocol_version", ["version": 2])
            transport?.send(type: "join", [
                "channel": configuration.key,
                "connection_type": "master",
            ])
            onEvent?(.connectionEstablished)
            for handler in connectedHandlers { handler() }
        case .disconnected(let error):
            let wasConnected = connectedToServer
            connectedToServer = false
            if slaveCount > 0 {
                slaveCount = 0
                onEvent?(.slaveLeft)
            }
            if wasConnected {
                onEvent?(.disconnected)
            } else {
                onEvent?(.connectionFailed(error))
            }
            scheduleReconnect()
        case .certificateUntrusted(let fingerprint):
            connectedToServer = false
            onEvent?(.certificateUntrusted(fingerprint: fingerprint))
        case .message(let message):
            dispatch(message)
        }
    }

    private func dispatch(_ message: Message) {
        guard let type = message["type"] as? String else { return }
        for handler in handlers[type] ?? [] {
            handler(message)
        }
    }

    // MARK: - Core protocol handlers

    private func registerCoreHandlers() {
        register("channel_joined") { [weak self] message in
            guard let self else { return }
            let clients = message["clients"] as? [[String: Any]] ?? []
            for client in clients where (client["connection_type"] as? String) == "slave" {
                self.slaveCount += 1
            }
            if self.slaveCount > 0 { self.onEvent?(.slaveJoined) }
        }
        register("client_joined") { [weak self] message in
            guard let self else { return }
            guard let client = message["client"] as? [String: Any],
                  (client["connection_type"] as? String) == "slave" else { return }
            self.slaveCount += 1
            self.sendBrailleInfo()
            self.onEvent?(.slaveJoined)
        }
        register("client_left") { [weak self] _ in
            guard let self else { return }
            // The protocol does not say which type left; the add-on tracks ids, but a
            // one-to-one session only ever has the one slave.
            if self.slaveCount > 0 {
                self.slaveCount -= 1
                self.onEvent?(.slaveLeft)
            }
        }
        register("motd") { [weak self] message in
            guard let self, let motd = message["motd"] as? String, !motd.isEmpty else { return }
            let forceDisplay = message["force_display"] as? Bool ?? false
            let hash = Insecure.SHA1Hash.hex(of: motd)
            if forceDisplay || AppSettings.shared.shouldDisplayMOTD(hash: hash, for: self.configuration.address) {
                self.onEvent?(.motd(motd))
            }
        }
        register("version_mismatch") { [weak self] _ in
            self?.onEvent?(.serverError(String(localized: "The server is not compatible with this version of remremote.")))
            self?.close()
        }
        register("error") { [weak self] message in
            let text = message["message"] as? String ?? "unknown error"
            self?.onEvent?(.serverError(text))
        }
        registerOnConnected { [weak self] in
            self?.sendBrailleInfoIfSlavePresent()
        }
    }

    private func sendBrailleInfoIfSlavePresent() {
        if slaveCount > 0 { sendBrailleInfo() }
    }

    /// We have no braille display; announcing zero cells stops the controlled side from
    /// sending display data.
    private func sendBrailleInfo() {
        transport?.send(type: "set_braille_info", ["name": "noBraille", "numCells": 0])
    }

    // MARK: - Outgoing convenience

    func send(type: String, _ payload: Message = [:]) {
        transport?.send(type: type, payload)
    }

    func sendKey(vkCode: Int, extended: Bool, pressed: Bool) {
        transport?.send(type: "key", [
            "vk_code": vkCode,
            "scan_code": 0,
            "extended": extended,
            "pressed": pressed,
        ])
    }
}

import CryptoKit

private extension Insecure {
    enum SHA1Hash {
        static func hex(of text: String) -> String {
            Insecure.SHA1.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }
}
