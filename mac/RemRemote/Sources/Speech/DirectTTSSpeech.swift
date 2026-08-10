import AVFoundation

/// Speaks remote text through AVSpeechSynthesizer with a user-chosen voice, rate and
/// pitch. Unlike the VoiceOver output, this honours cancel messages (interrupts) and
/// pitch commands from the controlled computer.
final class DirectTTSSpeech: NSObject, SpeechOutput {
    private let synthesizer = AVSpeechSynthesizer()
    private let settings: AppSettings

    init(settings: AppSettings = .shared) {
        self.settings = settings
        super.init()
    }

    private var baseVoice: AVSpeechSynthesisVoice? {
        if !settings.ttsVoiceIdentifier.isEmpty,
           let voice = AVSpeechSynthesisVoice(identifier: settings.ttsVoiceIdentifier) {
            return voice
        }
        return AVSpeechSynthesisVoice(language: nil)
    }

    private var baseRate: Float {
        let range = AVSpeechUtteranceMaximumSpeechRate - AVSpeechUtteranceMinimumSpeechRate
        return AVSpeechUtteranceMinimumSpeechRate + Float(settings.ttsRate) * range
    }

    func speak(_ items: [SpeechSequenceItem], priority: Int) {
        // NVDA priority 2 == "speak now": interrupt whatever is queued.
        let interrupt = priority >= 2
        DispatchQueue.main.async {
            if interrupt, self.synthesizer.isSpeaking {
                self.synthesizer.stopSpeaking(at: .immediate)
            }
            for utterance in self.utterances(for: items) {
                self.synthesizer.speak(utterance)
            }
        }
    }

    /// Splits a sequence into utterances at language changes, applying pitch offsets.
    private func utterances(for items: [SpeechSequenceItem]) -> [AVSpeechUtterance] {
        var result: [AVSpeechUtterance] = []
        var pendingText = ""
        var pitchOffset = 0.0
        var language: String?
        var pendingBreak = 0

        func flush() {
            let text = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
            pendingText = ""
            guard !text.isEmpty else { return }
            let utterance = AVSpeechUtterance(string: text)
            if let language,
               let voice = AVSpeechSynthesisVoice(language: language.replacingOccurrences(of: "_", with: "-")) {
                utterance.voice = voice
            } else {
                utterance.voice = baseVoice
            }
            utterance.rate = baseRate
            let pitch = settings.ttsPitch * (1.0 + pitchOffset / 100.0)
            utterance.pitchMultiplier = Float(min(max(pitch, 0.5), 2.0))
            if pendingBreak > 0 {
                utterance.preUtteranceDelay = TimeInterval(pendingBreak) / 1000.0
                pendingBreak = 0
            }
            result.append(utterance)
        }

        for item in items {
            switch item {
            case .text(let text):
                pendingText += pendingText.isEmpty ? text : " " + text
            case .pitchOffset(let offset):
                flush()
                pitchOffset = offset
            case .languageChange(let lang):
                flush()
                language = lang
            case .pause(let milliseconds):
                flush()
                pendingBreak = milliseconds
            case .endUtterance:
                flush()
            }
        }
        flush()
        return result
    }

    func cancel() {
        DispatchQueue.main.async {
            self.synthesizer.stopSpeaking(at: .immediate)
        }
    }

    func pause(_ paused: Bool) {
        DispatchQueue.main.async {
            if paused {
                self.synthesizer.pauseSpeaking(at: .immediate)
            } else {
                self.synthesizer.continueSpeaking()
            }
        }
    }

    func shutdown() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
