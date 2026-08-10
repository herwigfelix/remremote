import Foundation
import Network
import CoreAudio
import AVFoundation
import CryptoKit

/// Something that streams this Mac's audio and can be told to stop. Lets SlaveController
/// hold a reference without itself requiring the macOS 14.2 availability of the concrete
/// Core Audio tap implementation.
protocol AudioSending: AnyObject {
    func stop()
}

/// Streams this Mac's system audio (including VoiceOver) to a controlling machine when
/// this Mac is the controlled one. Uses the Core Audio process-tap API (macOS 14.2+),
/// which captures system audio with only an audio permission — no Screen Recording — then
/// Opus-encodes it, seals it with the RemSound AES-256-GCM crypto and sends it to the
/// relay, which forwards it to the master. Relay-only for now.
///
/// The controlled Mac's screen-reader output can only reach the controller as audio (there
/// is no way to intercept VoiceOver's speech as text), which is why controlling a Mac
/// always turns audio on.
@available(macOS 14.2, *)
final class SystemAudioSender: AudioSending {
    private let host: String
    private let port: UInt16
    private let sessionId: Data
    private let key: SymmetricKey
    private let fingerprint: Data

    private let queue = DispatchQueue(label: "org.remremote.audiosender")
    /// The audio IO proc runs on its own high-priority queue, kept clear of the network
    /// send completions and timers so capture is never periodically stalled by them.
    private let captureQueue = DispatchQueue(label: "org.remremote.audiocapture", qos: .userInteractive)
    private var directCopy = false
    private var connection: NWConnection?
    private var registrationTimer: DispatchSourceTimer?
    private var formatTimer: DispatchSourceTimer?
    /// Held while streaming to stop App Nap / timer coalescing from periodically throttling
    /// this (usually background) app — which starved the capture/send and produced a
    /// regular ~90 ms audio gap every ~½ second.
    private var activityToken: NSObjectProtocol?

    // Core Audio process tap + aggregate device.
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var converter: AVAudioConverter?
    private var srcFormat: AVAudioFormat?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true)!

    private let encoder = OpusStreamEncoder()
    private let streamId: UInt16 = 1
    // Audio packets MUST carry a contiguous sequence — the receiver treats any gap as a
    // lost packet and runs Opus FEC recovery, which injects a phantom frame (an audible
    // hiccup + pitch blip). So Format packets, which the receiver does not sequence-track,
    // get their own counter and never interrupt the audio sequence.
    private var audioSequence: UInt32 = 0
    private var formatSequence: UInt32 = 0
    private var pcmBuffer: [Float] = []
    private let channels = 2
    private var frameLength: Int { Int(encoder?.frameSamples ?? 480) * channels }

    private static let relayMagic = Data("RRLY".utf8)
    private static let relayVersion: UInt8 = 1

    init(host: String, port: UInt16, password: String, sessionId: Data) {
        self.host = host
        self.port = port
        self.sessionId = sessionId
        key = RemSoundCrypto.deriveKey(password: password)
        fingerprint = RemSoundCrypto.fingerprint(password: password)
    }

    func start() {
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Streaming this Mac's system audio to the controlling computer"
        )
        queue.async {
            self.openConnection()
            self.startCapture()
        }
    }

    func stop() {
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
        queue.async {
            self.registrationTimer?.cancel(); self.registrationTimer = nil
            self.formatTimer?.cancel(); self.formatTimer = nil
            self.connection?.cancel(); self.connection = nil
            self.stopCapture()
        }
    }

    // MARK: - Networking to the relay

    private func openConnection() {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let parameters = NWParameters.udp
        parameters.serviceClass = .responsiveData // interactive: don't let the OS batch our packets
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, case .ready = state else { return }
            self.startRelayTimers()
        }
        connection.start(queue: queue)
    }

    private func startRelayTimers() {
        sendRegistration()
        let reg = DispatchSource.makeTimerSource(queue: queue)
        reg.schedule(deadline: .now() + 2, repeating: 2)
        reg.setEventHandler { [weak self] in self?.sendRegistration() }
        reg.resume()
        registrationTimer = reg

        sendFormat()
        let fmt = DispatchSource.makeTimerSource(queue: queue)
        fmt.schedule(deadline: .now() + 1, repeating: 1)
        fmt.setEventHandler { [weak self] in self?.sendFormat() }
        fmt.resume()
        formatTimer = fmt
    }

    private func sendRegistration() {
        var packet = Self.relayMagic
        packet.append(Self.relayVersion)
        packet.append(sessionId)
        connection?.send(content: packet, completion: .contentProcessed { _ in })
    }

    private func sendFormat() {
        let payload = RemAudioFormat.opusStereoPayload(frameSamplesPerChannel: encoder?.frameSamples ?? 480,
                                                       fingerprint: fingerprint)
        formatSequence &+= 1
        var packet = RemPacket.writeHeader(type: .format, streamId: streamId, sequence: formatSequence)
        packet.append(payload)
        connection?.send(content: packet, completion: .contentProcessed { _ in })
    }

    private func sendAudioFrame(_ interleaved: [Float]) {
        guard let opus = encoder?.encode(interleaved),
              let sealed = RemSoundCrypto.seal(opus, key: key) else { return }
        audioSequence &+= 1
        var packet = RemPacket.writeHeader(type: .audio, streamId: streamId, sequence: audioSequence)
        packet.append(sealed)
        connection?.send(content: packet, completion: .contentProcessed { _ in })
    }

    // MARK: - Capture via a Core Audio process tap

    private func startCapture() {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "remremote system audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted // keep the Mac's own speakers working while we capture

        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr, tap != kAudioObjectUnknown else {
            NSLog("remremote: could not create the system-audio tap")
            return
        }
        tapID = tap

        let aggUID = "org.remremote.audiotap.\(UUID().uuidString)"
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "remremote tap",
            kAudioAggregateDeviceUIDKey as String: aggUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [[
                kAudioSubTapUIDKey as String: description.uuid.uuidString,
                // No drift compensation: a capture-only aggregate has no anchor device, so
                // compensation would resample the tap against a nominal clock and produce a
                // periodic pitch wobble. Deliver the tap's native samples instead.
                kAudioSubTapDriftCompensationKey as String: false,
            ]],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate) == noErr,
              aggregate != kAudioObjectUnknown else {
            NSLog("remremote: could not create the tap aggregate device")
            return
        }
        aggregateID = aggregate

        // The tap's stream format (usually 48 kHz float); build a converter to our target.
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: 0
        )
        if AudioObjectGetPropertyData(aggregate, &formatAddress, 0, nil, &size, &asbd) == noErr,
           let source = AVAudioFormat(streamDescription: &asbd) {
            srcFormat = source
            // Common case: the tap is already 48 kHz float — just interleave/downmix in the
            // callback with no allocations. Only build a converter for an odd rate.
            if source.sampleRate == targetFormat.sampleRate {
                directCopy = true
                converter = nil
            } else {
                directCopy = false
                converter = AVAudioConverter(from: source, to: targetFormat)
            }
        }

        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, captureQueue) {
            [weak self] _, inInputData, _, _, _ in
            self?.handleInput(inInputData)
        }
        guard status == noErr, let procID else {
            NSLog("remremote: could not install the tap IO proc")
            return
        }
        ioProcID = procID
        AudioDeviceStart(aggregate, procID)
    }

    private func stopCapture() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        ioProcID = nil
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    /// Called on the audio IO thread with tapped system audio; produce 48 kHz stereo
    /// interleaved float, chop into Opus frames and send. The 48 kHz path allocates
    /// nothing (a steady, allocation-free callback avoids periodic hitches).
    private func handleInput(_ inInputData: UnsafePointer<AudioBufferList>) {
        guard let srcFormat else { return }
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
        guard abl.count > 0 else { return }

        if directCopy {
            appendDirect(abl, channels: Int(srcFormat.channelCount), interleaved: srcFormat.isInterleaved)
        } else {
            appendResampled(abl)
        }

        while pcmBuffer.count >= frameLength {
            let frame = Array(pcmBuffer.prefix(frameLength))
            pcmBuffer.removeFirst(frameLength)
            sendAudioFrame(frame)
        }
    }

    /// 48 kHz path: read the raw float buffers into interleaved stereo, no allocations.
    private func appendDirect(_ abl: UnsafeMutableAudioBufferListPointer, channels: Int, interleaved: Bool) {
        if interleaved {
            guard let data = abl[0].mData else { return }
            let total = Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size
            let p = data.assumingMemoryBound(to: Float.self)
            if channels == 2 {
                pcmBuffer.append(contentsOf: UnsafeBufferPointer(start: p, count: total))
            } else {
                let frames = channels > 0 ? total / channels : total
                for f in 0..<frames { pcmBuffer.append(p[f * channels]); pcmBuffer.append(p[f * channels + (channels > 1 ? 1 : 0)]) }
            }
        } else {
            guard let l = abl[0].mData else { return }
            let frames = Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size
            let lp = l.assumingMemoryBound(to: Float.self)
            let rp = (channels > 1 && abl.count > 1 ? abl[1].mData : abl[0].mData)?.assumingMemoryBound(to: Float.self) ?? lp
            for f in 0..<frames { pcmBuffer.append(lp[f]); pcmBuffer.append(rp[f]) }
        }
    }

    /// Odd-rate fallback: resample to 48 kHz stereo via AVAudioConverter.
    private func appendResampled(_ abl: UnsafeMutableAudioBufferListPointer) {
        guard let srcFormat, let converter else { return }
        let frameCount = AVAudioFrameCount(Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size / (srcFormat.isInterleaved ? max(1, Int(srcFormat.channelCount)) : 1))
        guard frameCount > 0, let inBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else { return }
        inBuffer.frameLength = frameCount
        let inList = UnsafeMutableAudioBufferListPointer(inBuffer.mutableAudioBufferList)
        for i in 0..<min(inList.count, abl.count) {
            if let src = abl[i].mData, let dst = inList[i].mData {
                let bytes = min(abl[i].mDataByteSize, inList[i].mDataByteSize)
                memcpy(dst, src, Int(bytes)); inList[i].mDataByteSize = bytes
            }
        }
        let ratio = targetFormat.sampleRate / srcFormat.sampleRate
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(Double(frameCount) * ratio) + 16) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: outBuffer, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return inBuffer
        }
        let frames = Int(outBuffer.frameLength)
        guard frames > 0, let ch = outBuffer.floatChannelData else { return }
        let p = ch[0] // target is interleaved stereo
        pcmBuffer.append(contentsOf: UnsafeBufferPointer(start: p, count: frames * 2))
    }
}
