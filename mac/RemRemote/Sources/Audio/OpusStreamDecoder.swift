import Foundation
import Copus

/// Thin wrapper around libopus' raw C decoder (the Copus module of swift-opus).
final class OpusStreamDecoder {
    private var decoder: OpaquePointer
    let sampleRate: Int32
    let channels: Int32

    init?(sampleRate: Int32, channels: Int32) {
        var error: Int32 = 0
        guard let decoder = opus_decoder_create(sampleRate, channels, &error), error == OPUS_OK else {
            return nil
        }
        self.decoder = decoder
        self.sampleRate = sampleRate
        self.channels = channels
    }

    deinit {
        opus_decoder_destroy(decoder)
    }

    /// Decodes one Opus packet into interleaved float samples.
    /// - Parameter maxFrameSamples: upper bound of samples per channel in the packet.
    func decode(_ packet: Data, maxFrameSamples: Int32) -> [Float]? {
        let frameCap = max(120, maxFrameSamples)
        var pcm = [Float](repeating: 0, count: Int(frameCap * channels))
        let decoded = packet.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Int32 in
            guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return opus_decode_float(decoder, base, opus_int32(packet.count), &pcm, frameCap, 0)
        }
        guard decoded > 0 else { return nil }
        pcm.removeSubrange(Int(decoded * channels)...)
        return pcm
    }
}
