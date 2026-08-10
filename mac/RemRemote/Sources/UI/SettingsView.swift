import SwiftUI
import AVFoundation

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var settings = AppSettings.shared

    private var voices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        Form {
            Section(String(localized: "Keyboard")) {
                Toggle(
                    String(localized: "Use Command+Option as the NVDA key (Insert)"),
                    isOn: $settings.nvdaKeyCommandOption
                )
                Text("Most Mac keyboards have no Insert key. With this enabled, pressing Command and Option together acts as the NVDA key while controlling the remote computer.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if settings.nvdaKeyCommandOption {
                    HStack {
                        Text(String(localized: "Grace window before a single key becomes Alt or Windows"))
                        Spacer()
                        Text("\(Int(settings.nvdaChordLatencyMs)) ms")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.nvdaChordLatencyMs, in: 50...500, step: 10) {
                        Text(String(localized: "Grace window"))
                    }
                    Text("Command and Option become the NVDA key only when pressed together within this window. Held or tapped on its own, a key becomes just Alt or Windows once the window passes.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Warning: with this turned off, single presses of the Alt or Windows key may not work as expected while controlling the remote computer.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            Section(String(localized: "Speech output")) {
                Picker(String(localized: "Speak remote text with"), selection: $settings.speechMode) {
                    Text(String(localized: "VoiceOver")).tag(SpeechOutputMode.voiceOver)
                    Text(String(localized: "A speech synthesizer voice")).tag(SpeechOutputMode.directTTS)
                }
                .pickerStyle(.radioGroup)

                if settings.speechMode == .voiceOver {
                    Text("Warning: VoiceOver does not honour interrupts, nor pitch changes sent by the remote computer.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                if settings.speechMode == .directTTS {
                    Picker(String(localized: "Voice"), selection: $settings.ttsVoiceIdentifier) {
                        Text(String(localized: "System default")).tag("")
                        ForEach(voices, id: \.identifier) { voice in
                            Text("\(voice.name) (\(voice.language))").tag(voice.identifier)
                        }
                    }
                    Slider(value: $settings.ttsRate, in: 0...1) {
                        Text(String(localized: "Rate"))
                    }
                    Slider(value: $settings.ttsPitch, in: 0.5...2.0) {
                        Text(String(localized: "Pitch"))
                    }
                }
            }

            Section(String(localized: "Remote audio")) {
                Toggle(
                    String(localized: "Use the speech synthesizer of the remote computer while its audio is streamed"),
                    isOn: Binding(
                        get: { settings.useRemoteTTS },
                        set: { _ in state.toggleRemoteTTS() }
                    )
                )
                Text("While audio is streaming, the remote computer keeps its own voice in the stream instead of sending its speech as text.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section(String(localized: "Security")) {
                Button(String(localized: "Delete all trusted fingerprints")) {
                    settings.clearTrustedFingerprints()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding()
    }
}
