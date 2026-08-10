import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Group {
            if state.status == .disconnected {
                ConnectView()
            } else {
                SessionView()
            }
        }
        .frame(minWidth: 460, minHeight: 420)
        .alert(
            String(localized: "Connection security warning"),
            isPresented: Binding(
                get: { state.certificatePrompt != nil },
                set: { if !$0 { state.certificatePrompt = nil } }
            ),
            presenting: state.certificatePrompt
        ) { _ in
            Button(String(localized: "Connect")) { state.acceptCertificate(save: false) }
            Button(String(localized: "Connect and do not ask again for this server")) {
                state.acceptCertificate(save: true)
            }
            Button(String(localized: "Cancel"), role: .cancel) { state.rejectCertificate() }
        } message: { prompt in
            Text("The server's certificate could not be verified. Its SHA-256 fingerprint is:\n\(prompt.fingerprint)")
        }
        .alert(
            String(localized: "Message of the Day"),
            isPresented: Binding(
                get: { state.motdText != nil },
                set: { if !$0 { state.motdText = nil } }
            ),
            presenting: state.motdText
        ) { _ in
            Button(String(localized: "OK"), role: .cancel) { state.motdText = nil }
        } message: { motd in
            Text(motd)
        }
    }
}

// MARK: - Connect form

struct ConnectView: View {
    @EnvironmentObject private var state: AppState

    @State private var host = ""
    @State private var key = ""
    @State private var encryptionPassword = ""
    @State private var saveComputer = false
    @State private var computerName = ""
    @State private var selectedComputer: SavedComputer?

    var body: some View {
        Form {
            if !state.computers.computers.isEmpty {
                Section(String(localized: "Known computers")) {
                    List(state.computers.computers, selection: Binding(
                        get: { selectedComputer?.id },
                        set: { id in
                            selectedComputer = state.computers.computers.first { $0.id == id }
                            if let computer = selectedComputer {
                                host = computer.address
                                computerName = computer.name
                            }
                        }
                    )) { computer in
                        Text("\(computer.name) (\(computer.address))")
                            .tag(computer.id)
                    }
                    .frame(minHeight: 80, maxHeight: 140)
                    HStack {
                        Button(String(localized: "Connect to selected computer")) {
                            if let computer = selectedComputer {
                                state.connect(to: computer)
                            }
                        }
                        .disabled(selectedComputer == nil)
                        Button(String(localized: "Remove"), role: .destructive) {
                            if let computer = selectedComputer {
                                state.computers.remove(computer)
                                selectedComputer = nil
                            }
                        }
                        .disabled(selectedComputer == nil)
                    }
                }
            }

            Section(String(localized: "New connection")) {
                TextField(String(localized: "Host (host or host:port)"), text: $host)
                    .autocorrectionDisabled()
                TextField(String(localized: "Key"), text: $key)
                    .autocorrectionDisabled()
                SecureField(String(localized: "Encryption password (optional)"), text: $encryptionPassword)
                Toggle(String(localized: "Save this computer in the keychain"), isOn: $saveComputer)
                if saveComputer {
                    TextField(String(localized: "Name"), text: $computerName)
                }
                Button(String(localized: "Connect")) { connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty
                        || key.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let error = state.lastError {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("remremote")
    }

    private func connect() {
        let (parsedHost, parsedPort) = Self.parse(address: host)
        guard !parsedHost.isEmpty else { return }
        if saveComputer {
            let name = computerName.isEmpty ? parsedHost : computerName
            let computer = SavedComputer(name: name, host: parsedHost, port: parsedPort)
            try? state.computers.save(
                computer,
                key: key,
                encryptionPassword: encryptionPassword.isEmpty ? nil : encryptionPassword
            )
        }
        state.connect(
            host: parsedHost,
            port: parsedPort,
            key: key,
            encryptionPassword: encryptionPassword.isEmpty ? nil : encryptionPassword
        )
    }

    /// Accepts "host", "host:port", "[v6addr]" and "[v6addr]:port".
    static func parse(address: String) -> (host: String, port: UInt16) {
        var text = address.trimmingCharacters(in: .whitespaces)
        var port: UInt16 = 6837
        if text.hasPrefix("[") {
            if let closing = text.firstIndex(of: "]") {
                let hostPart = String(text[text.index(after: text.startIndex)..<closing])
                let rest = text[text.index(after: closing)...]
                if rest.hasPrefix(":"), let parsed = UInt16(rest.dropFirst()) {
                    port = parsed
                }
                return (hostPart, port)
            }
        }
        if let colon = text.lastIndex(of: ":"), text.firstIndex(of: ":") == colon {
            if let parsed = UInt16(text[text.index(after: colon)...]) {
                port = parsed
                text = String(text[..<colon])
            }
        }
        return (text, port)
    }
}

// MARK: - Connected session

struct SessionView: View {
    @EnvironmentObject private var state: AppState

    private var statusText: String {
        switch state.status {
        case .disconnected:
            return String(localized: "Not connected")
        case .connecting:
            return String(localized: "Connecting…")
        case .connectedWaitingForSlave:
            return String(localized: "Connected to the server — waiting for the remote computer")
        case .connected:
            return state.controlling
                ? String(localized: "Controlling the remote computer — press F10 to stop")
                : String(localized: "Connected — press F10 to take control")
        }
    }

    private var audioText: String {
        switch state.audioState {
        case .off: return String(localized: "Remote audio: off")
        case .pending: return String(localized: "Remote audio: requested…")
        case .on(let remoteTTS):
            return remoteTTS
                ? String(localized: "Remote audio: on (remote speech synthesizer)")
                : String(localized: "Remote audio: on")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(statusText)
                .font(.title3)
                .accessibilityAddTraits(.updatesFrequently)

            GroupBox(String(localized: "Session")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(audioText)
                    Text(state.clipboardSyncEnabled
                        ? String(localized: "Clipboard sync: on")
                        : String(localized: "Clipboard sync: off"))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            HStack {
                Button(String(localized: "Toggle remote audio")) { state.toggleAudio() }
                Button(String(localized: "Toggle clipboard sync")) { state.toggleClipboardSync() }
                Button(String(localized: "Push clipboard")) { state.pushClipboard() }
            }

            if let error = state.lastError {
                Text(error)
                    .foregroundStyle(.red)
            }

            Spacer()

            Button(String(localized: "Disconnect"), role: .destructive) {
                state.disconnect()
            }
        }
        .padding()
    }
}
