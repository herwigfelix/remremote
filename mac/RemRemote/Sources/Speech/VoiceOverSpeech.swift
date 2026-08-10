import AppKit

/// Speaks remote text by handing it to VoiceOver as accessibility announcements.
///
/// Limitations (the settings UI warns about them): VoiceOver decides when and how to
/// speak announcements — cancel messages from the remote machine do not interrupt it,
/// and pitch changes (e.g. for capital letters) are not applied.
final class VoiceOverSpeech: SpeechOutput {
    func speak(_ items: [SpeechSequenceItem], priority: Int) {
        let text = SpeechSequenceItem.plainText(of: items)
        guard !text.isEmpty else { return }
        DispatchQueue.main.async {
            let element = NSApp.mainWindow ?? NSApp!
            NSAccessibility.post(
                element: element,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: text,
                    // NVDA priority 2 means "speak now"; map it to a high-priority
                    // announcement, everything else to medium.
                    .priority: priority >= 2
                        ? NSAccessibilityPriorityLevel.high.rawValue
                        : NSAccessibilityPriorityLevel.medium.rawValue,
                ]
            )
        }
    }

    func cancel() {
        // VoiceOver does not expose a way to cancel queued announcements.
    }

    func pause(_ paused: Bool) {
        // Not supported by announcements.
    }

    func shutdown() {}
}
