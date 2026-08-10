import Foundation
import Network
import CryptoKit

/// Receives the controlled computer's audio stream: connects out to the UDP port the
/// slave's helper bound (the same number as its control server), punches the NAT with
/// sealed hello packets every two seconds, and plays the Opus stream that comes back.
///
/// Hello/pong: RemPacket header (Heartbeat, streamId 65534), payload AES-256-GCM sealed
/// 13 bytes — ASCII tag "TNVH1"/"TNVP1" + int64 LE Unix milliseconds, fresh within
/// two minutes. Everything else from the peer is Format/Audio in the RemSound format.
final class RemSoundReceiver {
    enum ReceiverError: Error {
        case socketFailed
        case passwordMismatch
    }

    var onPeerConfirmed: (() -> Void)?
    var onError: ((ReceiverError) -> Void)?

    private let host: String
    private let port: UInt16
    private let key: SymmetricKey
    private let ourFingerprint: Data
    /// When set, the peer is reached through the relay: we register this 32-byte session
    /// id with it (so it pairs us with the sender) and it forwards our packets verbatim.
    /// nil for a direct connection to the slave.
    private let relaySessionId: Data?

    private let queue = DispatchQueue(label: "org.remremote.audio")
    private var connection: NWConnection?
    private var helloTimer: DispatchSourceTimer?
    private var helloSequence: UInt32 = 0

    /// Registration packet framing for the dumb UDP relay: magic + version + session id.
    private static let relayMagic = Data("RRLY".utf8)
    private static let relayVersion: UInt8 = 1
    private var peerConfirmed = false
    private var reportedMismatch = false

    private var format: RemAudioFormat?
    private var activeStreamId: UInt16?
    private var decoder: OpusStreamDecoder?
    private let playout = AudioPlayout()

    private static let helloTag = Data("TNVH1".utf8)
    private static let pongTag = Data("TNVP1".utf8)
    private static let freshnessMs: Int64 = 120_000

    init(host: String, port: UInt16, password: String, relaySessionId: Data? = nil) {
        self.host = host
        self.port = port
        self.relaySessionId = relaySessionId
        key = RemSoundCrypto.deriveKey(password: password)
        ourFingerprint = RemSoundCrypto.fingerprint(password: password)
    }

    func start() {
        queue.async {
            guard let nwPort = NWEndpoint.Port(rawValue: self.port) else {
                self.onError?(.socketFailed)
                return
            }
            let parameters = NWParameters.udp
            let connection = NWConnection(host: NWEndpoint.Host(self.host), port: nwPort, using: parameters)
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.startHellos()
                    self.receiveLoop()
                case .failed:
                    self.onError?(.socketFailed)
                default:
                    break
                }
            }
            connection.start(queue: self.queue)
        }
    }

    func stop() {
        queue.async {
            self.helloTimer?.cancel()
            self.helloTimer = nil
            self.connection?.cancel()
            self.connection = nil
        }
        playout.stop()
    }

    // MARK: - Hello punch

    private func startHellos() {
        // Over a relay, register before the first hello so the relay can pair us with the
        // sender and actually forward that hello onward.
        sendRelayRegistration()
        sendHello()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            self?.sendRelayRegistration()
            self?.sendHello()
        }
        timer.resume()
        helloTimer = timer
    }

    private func sendRelayRegistration() {
        guard let session = relaySessionId else { return }
        var packet = Self.relayMagic
        packet.append(Self.relayVersion)
        packet.append(session)
        connection?.send(content: packet, completion: .contentProcessed { _ in })
    }

    private func sendHello() {
        var plaintext = Data(capacity: 13)
        plaintext.append(Self.helloTag)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        withUnsafeBytes(of: now.littleEndian) { plaintext.append(contentsOf: $0) }
        guard let sealed = RemSoundCrypto.seal(plaintext, key: key) else { return }
        helloSequence &+= 1
        var packet = RemPacket.writeHeader(type: .heartbeat, streamId: RemPacket.helloStreamId, sequence: helloSequence)
        packet.append(sealed)
        connection?.send(content: packet, completion: .contentProcessed { _ in })
    }

    private func isSealed(_ payload: Data, tag: Data) -> Bool {
        guard let plaintext = RemSoundCrypto.open(payload, key: key), plaintext.count >= 13 else {
            return false
        }
        guard plaintext.prefix(5) == tag else { return false }
        let timestamp = plaintext.subdata(in: 5..<13).withUnsafeBytes {
            Int64(littleEndian: $0.loadUnaligned(as: Int64.self))
        }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return abs(now - timestamp) <= Self.freshnessMs
    }

    // MARK: - Receiving

    private func receiveLoop() {
        connection?.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.handle(packet: data)
            }
            if error == nil, self.connection != nil {
                self.receiveLoop()
            }
        }
    }

    private func handle(packet: Data) {
        guard let header = RemPacket.readHeader(packet) else { return }
        let payload = packet.dropFirst(RemPacket.headerSize)

        switch header.type {
        case .heartbeat where header.streamId == RemPacket.helloStreamId:
            if isSealed(Data(payload), tag: Self.pongTag), !peerConfirmed {
                peerConfirmed = true
                onPeerConfirmed?()
            }
        case .format:
            handleFormat(Data(payload), streamId: header.streamId)
        case .audio:
            handleAudio(Data(payload), streamId: header.streamId)
        default:
            break
        }
    }

    private func handleFormat(_ payload: Data, streamId: UInt16) {
        guard let incoming = RemAudioFormat.parse(payload) else { return }
        if let fingerprint = incoming.passwordFingerprint, fingerprint != ourFingerprint {
            if !reportedMismatch {
                reportedMismatch = true
                onError?(.passwordMismatch)
            }
            return
        }
        if let current = format, current == incoming, activeStreamId == streamId {
            return
        }
        format = incoming
        activeStreamId = streamId
        decoder = nil
        playout.stop()
        guard incoming.codec == 2 else { return } // the remremote helper always sends Opus
        decoder = OpusStreamDecoder(sampleRate: incoming.sampleRate, channels: incoming.channels)
        try? playout.start(sampleRate: Int(incoming.sampleRate), channels: Int(incoming.channels))
    }

    private func handleAudio(_ payload: Data, streamId: UInt16) {
        guard streamId == activeStreamId,
              let format,
              let decoder,
              let plaintext = RemSoundCrypto.open(payload, key: key),
              let samples = decoder.decode(plaintext, maxFrameSamples: max(120, format.frameSamplesPerChannel)) else {
            return
        }
        playout.write(samples)
    }
}
