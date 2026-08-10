import Foundation

/// The RemSound UDP wire format (header version 1), as produced by the RemSound.Host
/// helper bundled with the Windows add-on. 12-byte little-endian header:
/// magic "RMND", version 1, type, uint16 streamId, uint32 sequence.
enum RemPacketType: UInt8 {
    case format = 1
    case audio = 2
    case keepAlive = 3
    case heartbeat = 4
    case control = 5
    case addrCheck = 10
}

enum RemPacket {
    static let headerSize = 12
    static let magic: UInt32 = 1145982290 // "RMND" little-endian
    static let version: UInt8 = 1
    /// StreamId used by remremote's sealed hello/pong punch packets.
    static let helloStreamId: UInt16 = 65534

    static func writeHeader(type: RemPacketType, streamId: UInt16, sequence: UInt32) -> Data {
        var data = Data(capacity: headerSize)
        withUnsafeBytes(of: magic.littleEndian) { data.append(contentsOf: $0) }
        data.append(version)
        data.append(type.rawValue)
        withUnsafeBytes(of: (streamId == 0 ? 1 : streamId).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: sequence.littleEndian) { data.append(contentsOf: $0) }
        return data
    }

    static func readHeader(_ packet: Data) -> (type: RemPacketType, streamId: UInt16, sequence: UInt32)? {
        guard packet.count >= headerSize else { return nil }
        let bytes = [UInt8](packet.prefix(headerSize))
        let magicValue = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        guard magicValue == magic, bytes[4] == version,
              let type = RemPacketType(rawValue: bytes[5]) else { return nil }
        var streamId = UInt16(bytes[6]) | UInt16(bytes[7]) << 8
        if streamId == 0 { streamId = 1 }
        let sequence = UInt32(bytes[8]) | UInt32(bytes[9]) << 8 | UInt32(bytes[10]) << 16 | UInt32(bytes[11]) << 24
        return (type, streamId, sequence)
    }
}

/// The payload of a Format packet: 32, 36 (+lane) or 44 (+8-byte password fingerprint)
/// bytes of little-endian int32 fields.
struct RemAudioFormat: Equatable {
    var sampleRate: Int32
    var channels: Int32
    var bitsPerSample: Int32
    var encoding: Int32
    var codec: Int32 // 1 = PCM, 2 = Opus
    var frameSamplesPerChannel: Int32
    var passwordFingerprint: Data?

    static func == (lhs: RemAudioFormat, rhs: RemAudioFormat) -> Bool {
        lhs.sampleRate == rhs.sampleRate && lhs.channels == rhs.channels
            && lhs.codec == rhs.codec && lhs.frameSamplesPerChannel == rhs.frameSamplesPerChannel
    }

    /// Encodes the 44-byte Format payload (with the 8-byte password fingerprint) that the
    /// controlled Mac sends to declare its Opus 48 kHz stereo stream.
    static func opusStereoPayload(frameSamplesPerChannel: Int32, fingerprint: Data) -> Data {
        var data = Data()
        func put(_ v: Int32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        put(48000)   // sampleRate
        put(2)       // channels
        put(32)      // bitsPerSample (float)
        put(3)       // encoding = IEEE float
        put(8)       // blockAlign
        put(384000)  // averageBytesPerSecond
        put(2)       // codec = Opus
        put(frameSamplesPerChannel)
        data.append(contentsOf: [0, 0, 0, 0]) // lane = mixed + padding
        data.append(fingerprint.prefix(8))
        return data
    }

    static func parse(_ payload: Data) -> RemAudioFormat? {
        guard payload.count >= 32 else { return nil }
        let bytes = [UInt8](payload)
        func int32(_ offset: Int) -> Int32 {
            Int32(bitPattern: UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24)
        }
        var fingerprint: Data?
        if payload.count >= 44 {
            fingerprint = Data(bytes[36..<44])
        }
        return RemAudioFormat(
            sampleRate: int32(0),
            channels: int32(4),
            bitsPerSample: int32(8),
            encoding: int32(12),
            codec: int32(24),
            frameSamplesPerChannel: int32(28),
            passwordFingerprint: fingerprint
        )
    }
}
