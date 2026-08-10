import Foundation

/// One item of an NVDA speech sequence as it arrives in a "speak" message: plain text,
/// or a serialized speech command `[className, attributes]`.
enum SpeechSequenceItem {
    case text(String)
    /// PitchCommand: percentage offset on the synthesizer's pitch (e.g. capitals).
    case pitchOffset(Double)
    /// LangChangeCommand: language code such as "de_DE", or nil to return to default.
    case languageChange(String?)
    /// BreakCommand: pause in milliseconds.
    case pause(milliseconds: Int)
    case endUtterance

    static func parse(_ raw: [Any]) -> [SpeechSequenceItem] {
        var items: [SpeechSequenceItem] = []
        for element in raw {
            if let text = element as? String {
                items.append(.text(text))
                continue
            }
            guard let command = element as? [Any], command.count == 2,
                  let name = command[0] as? String else { continue }
            let attributes = command[1] as? [String: Any] ?? [:]
            switch name {
            case "PitchCommand":
                if let offset = attributes["offset"] as? Double {
                    items.append(.pitchOffset(offset))
                } else if let offset = attributes["offset"] as? Int {
                    items.append(.pitchOffset(Double(offset)))
                } else {
                    items.append(.pitchOffset(0))
                }
            case "LangChangeCommand":
                items.append(.languageChange(attributes["lang"] as? String))
            case "BreakCommand":
                let ms = (attributes["time"] as? Int) ?? Int(attributes["time"] as? Double ?? 0)
                items.append(.pause(milliseconds: ms))
            case "EndUtteranceCommand":
                items.append(.endUtterance)
            default:
                // CharacterModeCommand, RateCommand, VolumeCommand, PhonemeCommand,
                // IndexCommand… — nothing sensible to map them to here.
                continue
            }
        }
        return items
    }

    /// The concatenated text of a sequence, for outputs that only speak strings.
    static func plainText(of items: [SpeechSequenceItem]) -> String {
        items.compactMap {
            if case .text(let text) = $0 { return text }
            return nil
        }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A speech backend for text arriving from the controlled computer.
protocol SpeechOutput: AnyObject {
    func speak(_ items: [SpeechSequenceItem], priority: Int)
    func cancel()
    func pause(_ paused: Bool)
    func shutdown()
}
