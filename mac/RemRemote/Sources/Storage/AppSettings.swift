import Foundation
import Combine

/// How speech received from the controlled computer is voiced locally.
enum SpeechOutputMode: String, CaseIterable, Identifiable {
    /// Hand the text to VoiceOver as accessibility announcements. VoiceOver does not
    /// honour interrupts (cancel messages) or pitch changes sent by the remote machine.
    case voiceOver
    /// Speak directly through a TTS voice chosen in the settings, with rate and pitch.
    case directTTS

    var id: String { rawValue }
}

/// All user-facing preferences, persisted in UserDefaults. Secrets never live here —
/// saved computers keep their keys in the macOS keychain (see `KeychainStore`).
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults: UserDefaults

    private enum Keys {
        static let nvdaKeyCommandOption = "nvdaKeyCommandOption"
        static let nvdaChordLatencyMs = "nvdaChordLatencyMs"
        static let speechMode = "speechMode"
        static let ttsVoiceIdentifier = "ttsVoiceIdentifier"
        static let ttsRate = "ttsRate"
        static let ttsPitch = "ttsPitch"
        static let useRemoteTTS = "useRemoteTTS"
        static let trustedFingerprints = "trustedFingerprints"
        static let seenMOTDs = "seenMOTDs"
        static let autoConnectEnabled = "autoConnectEnabled"
        static let autoConnectControlled = "autoConnectControlled"
        static let autoConnectHost = "autoConnectHost"
        static let autoConnectPort = "autoConnectPort"
    }

    // MARK: - Autoconnect (start a session automatically on launch)

    /// Connect automatically when the app starts (like NVDA Remote's autoconnect).
    @Published var autoConnectEnabled: Bool {
        didSet { defaults.set(autoConnectEnabled, forKey: Keys.autoConnectEnabled) }
    }

    /// true: this Mac is the controlled machine (slave); false: it controls another (master).
    @Published var autoConnectControlled: Bool {
        didSet { defaults.set(autoConnectControlled, forKey: Keys.autoConnectControlled) }
    }

    @Published var autoConnectHost: String {
        didSet { defaults.set(autoConnectHost, forKey: Keys.autoConnectHost) }
    }

    @Published var autoConnectPort: Int {
        didSet { defaults.set(autoConnectPort, forKey: Keys.autoConnectPort) }
    }

    /// The autoconnect key/encryption live in the keychain, like saved computers.
    static let autoConnectKeychainID = UUID(uuidString: "00000000-0000-0000-0000-0000A0C0A0C0")!

    /// The NVDA key (Insert) is produced by holding Command+Option together. On by
    /// default because most Mac keyboards have no Insert key.
    @Published var nvdaKeyCommandOption: Bool {
        didSet { defaults.set(nvdaKeyCommandOption, forKey: Keys.nvdaKeyCommandOption) }
    }

    /// How long a lone Command or Option is held back before it commits to being just the
    /// Windows key / Alt. Within this window, adding the other half forms the NVDA key
    /// instead. Only meaningful while `nvdaKeyCommandOption` is on.
    @Published var nvdaChordLatencyMs: Double {
        didSet { defaults.set(nvdaChordLatencyMs, forKey: Keys.nvdaChordLatencyMs) }
    }

    @Published var speechMode: SpeechOutputMode {
        didSet { defaults.set(speechMode.rawValue, forKey: Keys.speechMode) }
    }

    /// Empty string = the system default voice.
    @Published var ttsVoiceIdentifier: String {
        didSet { defaults.set(ttsVoiceIdentifier, forKey: Keys.ttsVoiceIdentifier) }
    }

    /// 0...1, mapped onto AVSpeechUtterance's rate range.
    @Published var ttsRate: Double {
        didSet { defaults.set(ttsRate, forKey: Keys.ttsRate) }
    }

    /// 0.5...2.0 pitch multiplier.
    @Published var ttsPitch: Double {
        didSet { defaults.set(ttsPitch, forKey: Keys.ttsPitch) }
    }

    /// "Use the remote computer's own speech synthesizer while its audio is streamed."
    /// The controlling side owns this setting (see protocol.md).
    @Published var useRemoteTTS: Bool {
        didSet { defaults.set(useRemoteTTS, forKey: Keys.useRemoteTTS) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        nvdaKeyCommandOption = defaults.object(forKey: Keys.nvdaKeyCommandOption) as? Bool ?? true
        nvdaChordLatencyMs = defaults.object(forKey: Keys.nvdaChordLatencyMs) as? Double ?? 200
        speechMode = SpeechOutputMode(rawValue: defaults.string(forKey: Keys.speechMode) ?? "") ?? .voiceOver
        ttsVoiceIdentifier = defaults.string(forKey: Keys.ttsVoiceIdentifier) ?? ""
        ttsRate = defaults.object(forKey: Keys.ttsRate) as? Double ?? 0.5
        ttsPitch = defaults.object(forKey: Keys.ttsPitch) as? Double ?? 1.0
        useRemoteTTS = defaults.object(forKey: Keys.useRemoteTTS) as? Bool ?? false
        autoConnectEnabled = defaults.bool(forKey: Keys.autoConnectEnabled)
        autoConnectControlled = defaults.bool(forKey: Keys.autoConnectControlled)
        autoConnectHost = defaults.string(forKey: Keys.autoConnectHost) ?? ""
        autoConnectPort = defaults.object(forKey: Keys.autoConnectPort) as? Int ?? 6837
    }

    /// Whether the user has passed the permissions onboarding gate at least once.
    var onboardingDone: Bool {
        get { defaults.bool(forKey: "onboardingDone") }
        set { defaults.set(newValue, forKey: "onboardingDone") }
    }

    /// Whether the one-time "controlling another Mac / VoiceOver keys clash" hint was shown.
    var voiceOverConflictHintShown: Bool {
        get { defaults.bool(forKey: "voiceOverConflictHintShown") }
        set { defaults.set(newValue, forKey: "voiceOverConflictHintShown") }
    }

    // MARK: - Trusted certificate fingerprints (address -> lowercase sha256 hex)

    var trustedFingerprints: [String: String] {
        get { defaults.dictionary(forKey: Keys.trustedFingerprints) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: Keys.trustedFingerprints) }
    }

    func trustFingerprint(_ fingerprint: String, for address: String) {
        var all = trustedFingerprints
        all[address] = fingerprint
        trustedFingerprints = all
    }

    func clearTrustedFingerprints() {
        trustedFingerprints = [:]
    }

    // MARK: - Seen MOTD hashes (address -> sha1 hex), mirrors the add-on's behaviour

    func shouldDisplayMOTD(hash: String, for address: String) -> Bool {
        var seen = defaults.dictionary(forKey: Keys.seenMOTDs) as? [String: String] ?? [:]
        if seen[address] == hash { return false }
        seen[address] = hash
        defaults.set(seen, forKey: Keys.seenMOTDs)
        return true
    }
}
