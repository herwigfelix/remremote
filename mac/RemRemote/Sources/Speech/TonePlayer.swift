import AVFoundation

/// Plays the remote machine's beeps ("tone" messages): a sine wave with per-channel
/// volume, like NVDA's tones.beep.
final class TonePlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let sampleRate: Double = 44100
    private let format: AVAudioFormat
    private var started = false
    private let queue = DispatchQueue(label: "org.remremote.tones")

    init() {
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    private func ensureStarted() -> Bool {
        if started, engine.isRunning { return true }
        do {
            try engine.start()
            started = true
            return true
        } catch {
            return false
        }
    }

    /// - Parameters:
    ///   - hz: frequency
    ///   - length: duration in milliseconds
    ///   - left/right: channel volumes 0...100
    func beep(hz: Double, lengthMs: Double, left: Double, right: Double) {
        queue.async {
            guard hz > 0, lengthMs > 0, self.ensureStarted() else { return }
            let frames = AVAudioFrameCount(max(1, self.sampleRate * lengthMs / 1000.0))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: self.format, frameCapacity: frames) else { return }
            buffer.frameLength = frames
            let leftGain = Float(min(max(left, 0), 100)) / 100.0 * 0.6
            let rightGain = Float(min(max(right, 0), 100)) / 100.0 * 0.6
            let omega = 2.0 * Double.pi * hz / self.sampleRate
            let fadeFrames = min(Int(frames) / 4, Int(self.sampleRate * 0.005))
            if let leftData = buffer.floatChannelData?[0], let rightData = buffer.floatChannelData?[1] {
                for frame in 0..<Int(frames) {
                    var sample = Float(sin(omega * Double(frame)))
                    // Short fade in/out against clicks.
                    if fadeFrames > 0 {
                        if frame < fadeFrames {
                            sample *= Float(frame) / Float(fadeFrames)
                        } else if frame >= Int(frames) - fadeFrames {
                            sample *= Float(Int(frames) - frame) / Float(fadeFrames)
                        }
                    }
                    leftData[frame] = sample * leftGain
                    rightData[frame] = sample * rightGain
                }
            }
            self.player.scheduleBuffer(buffer)
            if !self.player.isPlaying {
                self.player.play()
            }
        }
    }
}
