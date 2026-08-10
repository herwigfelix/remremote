import AVFoundation

/// Plays the add-on's own connection cues (the WAV files bundled from addon/sounds).
final class CuePlayer {
    enum Cue: String {
        case connected
        case disconnected
        case controlling
        case controlled
        case clipboardPushed = "Push_Clipboard"
        case clipboardReceived = "receive_clipboard"
    }

    private var players: [Cue: AVAudioPlayer] = [:]

    func play(_ cue: Cue) {
        DispatchQueue.main.async {
            if let player = self.players[cue] {
                player.currentTime = 0
                player.play()
                return
            }
            guard let url = Bundle.main.url(forResource: cue.rawValue, withExtension: "wav"),
                  let player = try? AVAudioPlayer(contentsOf: url) else { return }
            self.players[cue] = player
            player.play()
        }
    }
}
