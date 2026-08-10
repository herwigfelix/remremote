import Foundation
import Copus

/// libopus encoder for the controlled (slave) role: encodes this Mac's captured system
/// audio into Opus packets the RemSound receiver on the other end already knows how to
/// decode (48 kHz stereo, matching the Windows sender's format declaration).
final class OpusStreamEncoder {
    private var encoder: OpaquePointer
    let sampleRate: Int32
    let channels: Int32
    /// 10 ms at 48 kHz — a low-latency frame that RemSound receivers handle.
    let frameSamples: Int32 = 480

    init?(sampleRate: Int32 = 48000, channels: Int32 = 2) {
        var error: Int32 = 0
        guard let enc = opus_encoder_create(sampleRate, channels, OPUS_APPLICATION_RESTRICTED_LOWDELAY, &error),
              error == OPUS_OK else {
            return nil
        }
        encoder = enc
        self.sampleRate = sampleRate
        self.channels = channels
    }

    deinit {
        opus_encoder_destroy(encoder)
    }

    /// Encodes exactly `frameSamples` samples per channel of interleaved float audio.
    func encode(_ interleaved: [Float]) -> Data? {
        var output = [UInt8](repeating: 0, count: 4000)
        let encoded = interleaved.withUnsafeBufferPointer { pcm -> Int32 in
            guard let base = pcm.baseAddress else { return -1 }
            return opus_encode_float(encoder, base, frameSamples, &output, opus_int32(output.count))
        }
        guard encoded > 0 else { return nil }
        return Data(output.prefix(Int(encoded)))
    }
}
