import AVFoundation

/// Plays decoded audio through AVAudioEngine with a small jitter buffer.
///
/// Frames are written interleaved; the render callback deinterleaves into the engine's
/// standard (non-interleaved float) format. Playback arms once the target latency's
/// worth of audio is buffered, outputs silence on underrun, and re-arms afterwards, so
/// network hiccups produce silence instead of drift.
final class AudioPlayout {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let lock = NSLock()

    private var buffer: [Float] = []
    private var channels = 2
    private var armed = false
    private var targetLatencyMs = 80
    private let maxLatencyMs = 500
    private var sampleRate = 48000

    func start(sampleRate: Int, channels: Int, targetLatencyMs: Int = 80) throws {
        stop()
        self.sampleRate = sampleRate
        self.channels = channels
        self.targetLatencyMs = targetLatencyMs
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: Double(sampleRate),
            channels: AVAudioChannelCount(channels)
        ) else { return }

        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self else { return noErr }
            self.render(frameCount: Int(frameCount), audioBufferList: audioBufferList)
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        sourceNode = node
        try engine.start()
    }

    func stop() {
        if let node = sourceNode {
            engine.stop()
            engine.detach(node)
            sourceNode = nil
        }
        lock.lock()
        buffer.removeAll()
        armed = false
        lock.unlock()
    }

    /// Appends interleaved float samples.
    func write(_ samples: [Float]) {
        lock.lock()
        buffer.append(contentsOf: samples)
        let maxSamples = sampleRate * maxLatencyMs / 1000 * channels
        if buffer.count > maxSamples {
            buffer.removeFirst(buffer.count - maxSamples)
        }
        if !armed {
            let targetSamples = sampleRate * targetLatencyMs / 1000 * channels
            if buffer.count >= targetSamples { armed = true }
        }
        lock.unlock()
    }

    private func render(frameCount: Int, audioBufferList: UnsafeMutablePointer<AudioBufferList>) {
        let outputBuffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        var channelPointers: [UnsafeMutablePointer<Float>] = []
        for channelBuffer in outputBuffers {
            guard let data = channelBuffer.mData else { return }
            channelPointers.append(data.assumingMemoryBound(to: Float.self))
        }
        let channelCount = min(channelPointers.count, channels)

        lock.lock()
        let available = armed ? buffer.count / channels : 0
        let framesToCopy = min(frameCount, available)
        for frame in 0..<framesToCopy {
            for channel in 0..<channelCount {
                channelPointers[channel][frame] = buffer[frame * channels + channel]
            }
        }
        if framesToCopy > 0 {
            buffer.removeFirst(framesToCopy * channels)
        }
        if armed && buffer.isEmpty {
            armed = false // underrun: refill to the target before resuming
        }
        lock.unlock()

        if framesToCopy < frameCount {
            for channel in 0..<channelPointers.count {
                for frame in framesToCopy..<frameCount {
                    channelPointers[channel][frame] = 0
                }
            }
        }
    }
}
