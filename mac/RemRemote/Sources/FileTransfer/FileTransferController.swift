import AppKit

/// One-shot file transfer, the NVDA Remote way: the whole file travels base64-encoded in a
/// single `file_transfer` control message, and the receiving side is asked where to save it.
///
///     file_transfer  {name: str, content: base64 str}
///
/// Works in both roles — a controlled Mac can send and receive just as a controlling one
/// can. The 10 MB cap is the add-on's; the control channel also carries speech, so a bigger
/// file would stall the session behind it.
@MainActor
final class FileTransferController {
    var announce: ((String) -> Void)?
    var playSentCue: (() -> Void)?
    var playReceivedCue: (() -> Void)?
    /// Called just before a modal panel opens. The controlling side uses it to hand the
    /// keyboard back to this Mac — with every keystroke going to the remote machine, the
    /// open/save panel could not be operated at all.
    var prepareForPanel: (() -> Void)?

    private weak var session: RemoteSession?
    /// A panel is up. wx's send-file dialog guards the same way; a second panel behind the
    /// first would be invisible and unreachable for a screen-reader user.
    private var panelOpen = false

    /// The add-on's limit (10 MB), enforced on both ends.
    static let maxFileSize = 10 * 1024 * 1024

    func attach(to session: RemoteSession) {
        self.session = session
        session.register("file_transfer") { [weak self] message in
            guard let name = message["name"] as? String,
                  let content = message["content"] as? String else { return }
            Task { @MainActor in self?.receive(name: name, content: content) }
        }
    }

    func shutdown() {
        session = nil
    }

    // MARK: - Sending

    func sendFile() {
        guard let session, session.connectedToServer, session.hasPeer else {
            announce?(String(localized: "Not connected."))
            return
        }
        guard !panelOpen else { return }
        panelOpen = true
        defer { panelOpen = false }
        prepareForPanel?()

        let panel = NSOpenPanel()
        panel.message = String(localized: "Choose the file you want to send to the remote computer")
        panel.prompt = String(localized: "Send")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            announce?(String(localized: "The file could not be read."))
            return
        }
        guard data.count <= Self.maxFileSize else {
            announce?(String(localized: "This file is too large. Only files smaller than 10 MB are supported."))
            return
        }
        session.send(type: "file_transfer", [
            "name": url.lastPathComponent,
            "content": data.base64EncodedString(),
        ])
        playSentCue?()
        announce?(String(localized: "File sent"))
    }

    // MARK: - Receiving

    private func receive(name: String, content: String) {
        guard let data = Data(base64Encoded: content) else { return }
        guard !panelOpen else { return }
        panelOpen = true
        defer { panelOpen = false }
        prepareForPanel?()

        // Only the bare file name is honoured: the sender has no say in where this lands.
        let suggested = (name as NSString).lastPathComponent
        let panel = NSSavePanel()
        panel.message = String(localized: "Choose where to save the received file")
        panel.nameFieldStringValue = suggested.isEmpty ? String(localized: "received file") : suggested
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.isExtensionHidden = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            announce?(String(localized: "The received file could not be saved."))
            return
        }
        playReceivedCue?()
        announce?(String(localized: "File received"))
    }
}
