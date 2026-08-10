import XCTest
@testable import remremote

/// End-to-end tests against a real relay (Tests/mini_relay.py with the add-on's
/// self-signed server.pem). Skipped unless REMREMOTE_LIVE_TEST=1 and the relay is
/// running on 127.0.0.1:16837 — see mac/README.md.
///
/// Exercises the paths unit tests cannot: the TLS verify block with an untrusted
/// certificate, fingerprint-pinned reconnection, channel join, and an encrypted
/// message round trip between two transports.
final class LiveRelayTests: XCTestCase {
    private let port: UInt16 = 16837

    private func skipUnlessLive() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["REMREMOTE_LIVE_TEST"] == "1",
            "live relay test disabled (set REMREMOTE_LIVE_TEST=1 and start Tests/mini_relay.py)"
        )
    }

    func testCertificatePromptThenPinnedConnectAndEncryptedRoundTrip() throws {
        try skipUnlessLive()

        // 1. First contact: the self-signed certificate must be rejected and reported
        //    with a fingerprint.
        let untrusted = ControlTransport(host: "127.0.0.1", port: port, encryptionPassword: nil)
        let rejected = expectation(description: "certificate untrusted")
        var fingerprint: String?
        untrusted.onEvent = { event in
            if case .certificateUntrusted(let fp) = event {
                fingerprint = fp
                rejected.fulfill()
            }
        }
        untrusted.connect()
        wait(for: [rejected], timeout: 10)
        untrusted.close()
        let pinned = try XCTUnwrap(fingerprint)
        XCTAssertEqual(pinned.count, 64)

        // 2. Reconnect with the fingerprint accepted; join as master and slave with an
        //    encryption password; the key message must arrive decrypted on the slave.
        let password = "integration-secret"
        let master = ControlTransport(host: "127.0.0.1", port: port, encryptionPassword: password)
        let slave = ControlTransport(host: "127.0.0.1", port: port, encryptionPassword: password)
        master.acceptedFingerprints = [pinned]
        slave.acceptedFingerprints = [pinned]
        defer {
            master.close()
            slave.close()
        }

        let masterReady = expectation(description: "master connected")
        let slaveJoined = expectation(description: "master sees the slave")
        let keyArrived = expectation(description: "slave got the key message")

        master.onEvent = { event in
            switch event {
            case .connected:
                master.send(type: "protocol_version", ["version": 2])
                master.send(type: "join", ["channel": "testchannel", "connection_type": "master"])
                masterReady.fulfill()
            case .message(let message):
                if message["type"] as? String == "client_joined" {
                    slaveJoined.fulfill()
                }
            default:
                break
            }
        }
        slave.onEvent = { event in
            switch event {
            case .connected:
                slave.send(type: "protocol_version", ["version": 2])
                slave.send(type: "join", ["channel": "testchannel", "connection_type": "slave"])
            case .message(let message):
                if message["type"] as? String == "key" {
                    XCTAssertEqual(message["vk_code"] as? Int, 0x41)
                    XCTAssertEqual(message["pressed"] as? Bool, true)
                    keyArrived.fulfill()
                }
            default:
                break
            }
        }

        master.connect()
        wait(for: [masterReady], timeout: 10)
        slave.connect()
        wait(for: [slaveJoined], timeout: 10)

        master.send(type: "key", ["vk_code": 0x41, "scan_code": 0, "extended": false, "pressed": true])
        wait(for: [keyArrived], timeout: 10)
    }
}
