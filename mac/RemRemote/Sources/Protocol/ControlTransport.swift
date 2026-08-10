import Foundation
import Network
import CryptoKit

/// One TLS connection to an NVDA Remote / TeleNVDA / remremote control server, speaking
/// newline-delimited JSON, with the optional AES-GCM message layer on top.
///
/// Mirrors the add-on's transport: ALPN "nvdaremote/2.0" with a retry without ALPN,
/// TLS 1.2 minimum, self-signed certificates accepted when their SHA-256 fingerprint is
/// trusted (stored or approved for this attempt by the user).
final class ControlTransport {
    typealias Message = [String: Any]

    enum Event {
        case connected
        case disconnected(Error?)
        /// TLS failed and the server's certificate is not trusted. The associated value
        /// is the certificate's lowercase SHA-256 fingerprint (when it could be read).
        case certificateUntrusted(String?)
        case message(Message)
    }

    let host: String
    let port: UInt16
    /// Called on the transport's queue.
    var onEvent: ((Event) -> Void)?

    /// Fingerprints the caller already trusts for this address (stored or one-shot).
    var acceptedFingerprints: Set<String> = []

    private let encryptionKey: [UInt8]?
    private let queue = DispatchQueue(label: "org.remremote.transport")
    private var connection: NWConnection?
    private var buffer = Data()
    private var sendALPN = true
    private var lastFailedFingerprint: String?
    private var certificateRejected = false
    private var closed = false
    private var timeoutTimer: DispatchSourceTimer?

    init(host: String, port: UInt16, encryptionPassword: String?) {
        self.host = host
        self.port = port
        if let password = encryptionPassword, !password.isEmpty {
            encryptionKey = MessageCrypto.key(fromPassword: password)
        } else {
            encryptionKey = nil
        }
    }

    // MARK: - Lifecycle

    func connect() {
        queue.async { self.openConnection() }
    }

    func close() {
        queue.async {
            self.closed = true
            self.teardown(error: nil, notify: false)
        }
    }

    private func openConnection() {
        guard !closed else { return }
        certificateRejected = false
        lastFailedFingerprint = nil
        buffer.removeAll()

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 60

        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        if sendALPN {
            sec_protocol_options_add_tls_application_protocol(sec, "nvdaremote/2.0")
        }
        sec_protocol_options_set_verify_block(sec, { [weak self] _, secTrust, complete in
            let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
            var error: CFError?
            let systemTrusted = SecTrustEvaluateWithError(trust, &error)
            let fingerprint = ControlTransport.fingerprint(of: trust)
            if systemTrusted {
                complete(true)
                return
            }
            guard let self else {
                complete(false)
                return
            }
            if let fingerprint, self.acceptedFingerprints.contains(fingerprint) {
                complete(true)
                return
            }
            self.queue.async {
                self.lastFailedFingerprint = fingerprint
                self.certificateRejected = true
            }
            complete(false)
        }, queue)

        let parameters = NWParameters(tls: tls, tcp: tcp)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        self.connection = connection

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15)
        timer.setEventHandler { [weak self] in
            guard let self, let connection = self.connection, connection.state != .ready else { return }
            self.teardown(error: NWError.posix(.ETIMEDOUT), notify: true)
        }
        timer.resume()
        timeoutTimer = timer

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.timeoutTimer?.cancel()
                self.timeoutTimer = nil
                self.onEvent?(.connected)
                self.receiveLoop()
            case .failed(let error):
                self.handleFailure(error)
            case .waiting(let error):
                // NWConnection retries forever in .waiting; treat it as a failure so our
                // own reconnect/fallback logic stays in charge.
                self.handleFailure(error)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func handleFailure(_ error: NWError) {
        guard connection != nil else { return }
        if certificateRejected {
            let fingerprint = lastFailedFingerprint
            teardown(error: error, notify: false)
            onEvent?(.certificateUntrusted(fingerprint))
            return
        }
        // TLS handshake trouble that is not a certificate problem: retry once without
        // ALPN, mirroring the add-on's fallback for servers that reject unknown ALPN.
        if case .tls = error, sendALPN {
            sendALPN = false
            teardown(error: nil, notify: false)
            openConnection()
            return
        }
        teardown(error: error, notify: true)
    }

    private func teardown(error: Error?, notify: Bool) {
        timeoutTimer?.cancel()
        timeoutTimer = nil
        if let connection {
            connection.stateUpdateHandler = nil
            connection.cancel()
            self.connection = nil
            if notify {
                onEvent?(.disconnected(error))
            }
        }
    }

    // MARK: - Receiving

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drainBuffer()
            }
            if isComplete || error != nil {
                self.teardown(error: error, notify: true)
                return
            }
            self.receiveLoop()
        }
    }

    private func drainBuffer() {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            parse(line: line, isDecrypted: false)
        }
    }

    private func parse(line: Data, isDecrypted: Bool) {
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: line),
              var message = object as? Message,
              let type = message["type"] as? String else { return }
        if let key = encryptionKey {
            if type == "encrypted", !isDecrypted {
                guard let nonce = message["nonce"] as? String,
                      let data = message["data"] as? String,
                      let tag = message["tag"] as? String,
                      let plaintext = MessageCrypto.decrypt(nonce: nonce, data: data, tag: tag, key: key) else { return }
                parse(line: plaintext, isDecrypted: true)
                return
            }
            // With encryption enabled, plaintext messages other than the excluded set
            // are dropped (they could be forged by the relay).
            if !isDecrypted && !MessageCrypto.excludedTypes.contains(type) {
                return
            }
        }
        message["type"] = type
        onEvent?(.message(message))
    }

    // MARK: - Sending

    func send(type: String, _ payload: Message = [:]) {
        queue.async {
            var message = payload
            message["type"] = type
            guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
            if let key = self.encryptionKey, !MessageCrypto.excludedTypes.contains(type) {
                guard let wrapped = try? MessageCrypto.encrypt(data, key: key),
                      let wrappedData = try? JSONSerialization.data(withJSONObject: wrapped) else { return }
                data = wrappedData
            }
            data.append(0x0A)
            self.connection?.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    // MARK: - Helpers

    private static func fingerprint(of trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }
}
